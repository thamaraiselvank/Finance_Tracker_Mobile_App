import 'dart:convert';

import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/local_plans.dart';
import 'package:finance_tracker_mobile/local/local_wealth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late LocalDb db;
  final today = DateTime(2026, 11, 23);
  setUp(() => db = LocalDb.inMemory());
  tearDown(() => db.close());

  Future<Object?> errorOf(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      return e;
    }
    return null;
  }

  Future<String> account({String name = 'HDFC', double balance = 100000}) async {
    final accounts = LocalAccountsService(db);
    await accounts.create({'name': name, 'account_type': 'SAVINGS', 'balance': balance});
    return (await accounts.list()).firstWhere((a) => a['name'] == name)['id'] as String;
  }

  group('holdings', () {
    test('value and invested amount come from quantity × price', () async {
      final assets = LocalAssetsService(db);
      await assets.create({
        'name': 'INFY', 'asset_class': 'equity', 'quantity': 10, 'buy_price': 1500, 'current_price': 1820.55, 'current_value': 0,
        'meta_data': {'symbol': 'INFY'},
      });
      final s = await assets.summary();
      final item = (s['asset_classes'] as List).single['items'].single as Map;
      expect(item['asset_class'], 'EQUITY');
      expect(item['current_value'], 18205.5);
      expect(item['invested_amount'], 15000.0);
      expect(item['pnl'], 3205.5);
      expect(item['pnl_percentage'], 21.37);
      expect((await errorOf(() => assets.create({'name': 'X', 'asset_class': 'EQUITY'}))).toString(), 'Current value: Field required');
    });

    test('price refresh uses public Yahoo quotes and reports failures', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.path);
        if (request.url.path.endsWith('/TCS.NS')) {
          return http.Response(jsonEncode({'chart': {'result': [{'meta': {'regularMarketPrice': 3400.456}}]}}), 200);
        }
        return http.Response('{"chart": {"result": []}}', 200);
      });
      final assets = LocalAssetsService(db, client: client);
      await assets.create({'name': 'TCS', 'asset_class': 'EQUITY', 'quantity': 5, 'current_value': 15000, 'meta_data': {'symbol': 'TCS'}});
      await assets.create({'name': 'UNKNOWNCO', 'asset_class': 'EQUITY', 'current_value': 100});
      await assets.create({'name': 'Gold', 'asset_class': 'COMMODITY_GOLD', 'current_value': 50000});

      final result = await assets.refreshPrices();
      expect(result['updated_count'], 1);
      expect(result['failed_count'], 1);
      expect(result['message'], 'Updated prices for 1 of 2 equity holdings.');
      expect((result['failures'] as List).single['reason'], 'No price found for UNKNOWNCO.');
      expect(requested.where((p) => p.contains('UNKNOWNCO')).length, 3); // .NS, .BO, plain
      final tcs = ((await assets.summary())['asset_classes'] as List).expand((c) => c['items'] as List).firstWhere((i) => i['name'] == 'TCS');
      expect(tcs['current_price'], 3400.46);
      expect(tcs['current_value'], 17002.3);
    });
  });

  group('income from holdings', () {
    Map<String, dynamic> fd(String accountId, {bool auto = true, String start = '2026-12-05'}) => {
          'name': 'SBI FD', 'asset_class': 'FIXED_INCOME', 'invested_amount': 200000, 'current_value': 200000,
          'income': {
            'source_type': 'INTEREST', 'amount': 1500, 'frequency': 'MONTHLY', 'interval_count': 1,
            'start_date': start, 'account_id': accountId, 'auto_add': auto,
          },
        };

    test('an asset that pays interest gets a schedule and counts as passive income', () async {
      final acc = await account();
      final assets = LocalAssetsService(db, today: () => today);
      await assets.create(fd(acc));
      final schedule = (await LocalSchedulesService(db).list()).single;
      expect(schedule['description'], 'Interest: SBI FD');
      expect(schedule['flow_type'], 'INCOME');
      expect(schedule['source_type'], 'INTEREST');
      expect(schedule['category_name'], 'Investments & Returns');

      final s = await assets.summary();
      final item = (s['asset_classes'] as List).single['items'].single as Map;
      expect((item['income'] as Map)['yearly'], 18000.0);
      expect((item['income'] as Map)['next_date'], '2026-12-05');
      final p = s['passive_income'] as Map;
      expect(p['yearly'], 18000.0);
      expect(p['monthly'], 1500.0);
      expect(p['count'], 1);
      expect((p['payouts'] as List).first['occurrence_date'], '2026-12-05');
    });

    test('rent every 6 months, and switching income off removes the schedule', () async {
      final acc = await account();
      final assets = LocalAssetsService(db, today: () => today);
      await assets.create({
        'name': 'Flat', 'asset_class': 'REAL_ESTATE', 'current_value': 5000000,
        'income': {'source_type': 'RENTAL_INCOME', 'amount': 60000, 'frequency': 'MONTHLY', 'interval_count': 6, 'start_date': '2027-01-01', 'account_id': acc},
      });
      expect((await LocalSchedulesService(db).list()).single['category_name'], 'Rental Income');
      expect(((await assets.summary())['passive_income'] as Map)['yearly'], 120000.0);
      final id = db.queryOne('SELECT id FROM assets')!['id'] as String;
      await assets.update(id, {
        'income': {'source_type': 'RENTAL_INCOME', 'amount': 65000, 'frequency': 'MONTHLY', 'interval_count': 6, 'start_date': '2027-01-01', 'account_id': acc},
      });
      expect((await LocalSchedulesService(db).list()).single['amount'], 65000.0);
      await assets.update(id, {'income': null});
      expect(await LocalSchedulesService(db).list(), isEmpty);
      expect(((await assets.summary())['passive_income'] as Map)['count'], 0);
    });

    test('due payouts are added to Money automatically, once, from the day it was set up', () async {
      final acc = await account(balance: 1000);
      var now = DateTime(2026, 11, 23);
      final assets = LocalAssetsService(db, today: () => now);
      // First payout was in October (before it was set up): not added.
      await assets.create(fd(acc, start: '2026-10-05'));
      db.execute('UPDATE scheduled_cashflows SET created_at = ?', [DateTime(2026, 11, 20).toUtc().toIso8601String()]);
      await assets.summary();
      expect((await LocalAccountsService(db).list()).single['balance'], 1000.0);

      now = DateTime(2026, 12, 6);
      final s = await assets.summary();
      await assets.summary(); // again: nothing added twice
      expect((await LocalAccountsService(db).list()).single['balance'], 2500.0);
      final tx = db.query("SELECT type, amount_minor, date FROM transactions WHERE source = 'SCHEDULE'");
      expect(tx.map((r) => r.values), [['INCOME', 150000, '2026-12-05']]);
      expect((s['passive_income'] as Map)['received_this_year'], 1500.0);
    });

    test('no automatic payouts when switched off; deleting the asset stops its income', () async {
      final acc = await account(balance: 1000);
      final assets = LocalAssetsService(db, today: () => DateTime(2026, 12, 6));
      await assets.create(fd(acc, auto: false));
      db.execute('UPDATE scheduled_cashflows SET created_at = ?', [DateTime(2026, 11, 20).toUtc().toIso8601String()]);
      final s = await assets.summary();
      expect((await LocalAccountsService(db).list()).single['balance'], 1000.0);
      expect(((s['passive_income'] as Map)['payouts'] as List).first['status'], 'overdue');
      await assets.delete(db.queryOne('SELECT id FROM assets')!['id'] as String);
      expect(await LocalSchedulesService(db).list(), isEmpty);
    });

    test('a bad income setting does not leave a half-saved asset', () async {
      final assets = LocalAssetsService(db, today: () => today);
      expect(await errorOf(() => assets.create(fd('no-such-account'))), isNotNull);
      expect(db.query('SELECT id FROM assets'), isEmpty);
    });
  });

  group('Bills & recurring', () {
    late LocalSchedulesService schedules;
    setUp(() => schedules = LocalSchedulesService(db, today: () => today));

    Map<String, dynamic> rent(String accountId, {Map<String, dynamic> extra = const {}}) => {
          'account_id': accountId,
          'description': '  Rent ',
          'flow_type': 'EXPENSE',
          'source_type': 'BILL',
          'amount': 25000,
          'frequency': 'MONTHLY',
          'interval_count': 1,
          'start_date': '2026-01-31',
          ...extra,
        };

    test('rules and messages match the backend', () async {
      final acc = await account();
      expect((await errorOf(() => schedules.create(rent(acc, extra: {'source_type': 'SALARY'})))).toString(),
          'Choose a source type that matches income or expense.');
      expect((await errorOf(() => schedules.create(rent(acc, extra: {'end_date': '2025-12-31'})))).toString(),
          'End date must be on or after the start date.');
      expect((await errorOf(() => schedules.create(rent(acc, extra: {'interval_count': 13})))).toString(),
          'Interval count: Input should be less than or equal to 12');
      expect((await errorOf(() => schedules.create(rent('nope')))).toString(), 'Choose an active account that belongs to your profile.');
      expect((await errorOf(() => schedules.create(rent(acc, extra: {'description': '   '})))).toString(),
          'Enter a name for this scheduled cash flow.');
      await schedules.create(rent(acc));
      expect((await schedules.list()).single['description'], 'Rent');
    });

    test('marking a due date paid records the transaction once and updates the balance', () async {
      final acc = await account(balance: 100000);
      await schedules.create(rent(acc));
      final id = (await schedules.list()).single['id'] as String;

      await schedules.completeOccurrence(id, DateTime(2026, 10, 31), actualAmount: 24500, actualDate: DateTime(2026, 11, 1));
      expect((await LocalAccountsService(db).list()).single['balance'], 75500.0);
      final occ = await schedules.occurrences(start: DateTime(2026, 10, 1), end: DateTime(2026, 11, 30));
      expect(occ.map((o) => (o['occurrence_date'], o['status'], o['actual_amount'])),
          [('2026-10-31', 'paid', 24500.0), ('2026-11-30', 'upcoming', null)]);

      expect((await errorOf(() => schedules.completeOccurrence(id, DateTime(2026, 10, 31), actualAmount: 1, actualDate: today))).toString(),
          'This occurrence has already been recorded.');
      expect((await errorOf(() => schedules.completeOccurrence(id, DateTime(2026, 10, 30), actualAmount: 1, actualDate: today))).toString(),
          'That date is not part of this recurrence schedule.');
      expect((await errorOf(() => schedules.completeOccurrence(id, DateTime(2026, 11, 30), actualAmount: 1, actualDate: DateTime(2026, 11, 30))))
          .toString(), 'A future date cannot be recorded as already paid or received.');

      // Deleting the recorded payment makes the due date open again.
      final tx = (await LocalTransactionsService(db).list()).single['id'] as String;
      await LocalTransactionsService(db).delete(tx);
      await schedules.completeOccurrence(id, DateTime(2026, 10, 31), actualAmount: 25000, actualDate: DateTime(2026, 11, 1));
    });

    test('a premium schedule updates the policy\'s payment dates', () async {
      final acc = await account();
      final insurance = LocalInsuranceService(db, today: () => today);
      await insurance.create({'policy_name': 'Health', 'policy_type': 'HEALTH', 'sum_insured': 500000, 'annual_premium': 18000});
      final policyId = (await insurance.list()).single['id'] as String;
      await schedules.create({
        'account_id': acc, 'description': 'Health premium', 'flow_type': 'EXPENSE', 'source_type': 'INSURANCE_PREMIUM',
        'amount': 18000, 'frequency': 'YEARLY', 'start_date': '2025-11-20', 'insurance_policy_id': policyId,
      });
      final s = (await schedules.list()).single;
      expect(s['category_name'], 'Insurance Premiums'); // default category for premiums
      expect(s['linked_record_name'], 'Health');
      await schedules.completeOccurrence(s['id'] as String, DateTime(2026, 11, 20), actualAmount: 18000, actualDate: DateTime(2026, 11, 20));
      final p = (await insurance.list()).single;
      expect(p['payment_status'], 'PAID');
      expect(p['last_payment_date'], '2026-11-20');
      expect(p['next_payment_date'], '2027-11-20');
    });

    test('an account used by a schedule cannot be deleted', () async {
      final acc = await account();
      await schedules.create(rent(acc));
      expect((await errorOf(() => LocalAccountsService(db).delete(acc))).toString(),
          'Recurring items in Bills & recurring use this account. Move or delete them first.');
    });

    test('pause via update keeps it out of the calendar', () async {
      final acc = await account();
      await schedules.create(rent(acc));
      final id = (await schedules.list()).single['id'] as String;
      await schedules.update(id, {'is_active': false, 'amount': 26000});
      final s = (await schedules.list()).single;
      expect(s['is_active'], false);
      expect(s['amount'], 26000.0);
      expect(await schedules.occurrences(start: DateTime(2026, 11, 1), end: DateTime(2026, 12, 31)), isEmpty);
    });
  });
}
