import 'dart:io';

import 'package:finance_tracker_mobile/capture/categorizer.dart';
import 'package:finance_tracker_mobile/local/local_capture.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/schema.dart';
import 'package:finance_tracker_mobile/services/errors.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Step 3.5: rules that learn type + category + account, "own money"
/// transfers, built-in rules, and where a payment was seen.
void main() {
  late LocalDb db;
  late LocalCaptureService capture;
  late LocalAccountsService accounts;
  late LocalTransactionsService transactions;
  final t0 = DateTime(2026, 11, 16, 10, 30);

  setUp(() {
    db = LocalDb.inMemory();
    capture = LocalCaptureService(db);
    accounts = LocalAccountsService(db);
    transactions = LocalTransactionsService(db, today: () => DateTime(2026, 11, 23));
  });
  tearDown(() => db.close());

  CapturedMessage sms(String body, {String sender = 'AX-HDFCBK', DateTime? at, String source = 'SMS'}) =>
      CapturedMessage(source: source, sender: sender, body: body, receivedAt: at ?? t0);
  DateTime later(int hours) => t0.add(Duration(hours: hours));

  Future<String> addAccount(String name, {double balance = 100000}) async {
    await accounts.create({'name': name, 'account_type': 'SAVINGS', 'balance': balance});
    return (await accounts.list()).firstWhere((a) => a['name'] == name)['id'] as String;
  }

  Future<double> balanceOf(String id) async => (await accounts.list()).firstWhere((a) => a['id'] == id)['balance'] as double;

  // Zerodha's quarterly settlement of unused Kite funds, and adding funds.
  String settlement({String amount = '12,345.00'}) =>
      'Update! INR $amount deposited in HDFC Bank A/c XX1234 on 15-NOV-26 for NEFT Cr-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN12345678901. '
      'Avl bal INR 50,000.00. Cheque deposits in A/C are subject to clearing';
  String addFunds({String ref = '431299998888'}) =>
      'Sent Rs.10000.00 From HDFC Bank A/C *1234 To ZERODHA BROKING LIMITED On 16/11/26 Ref $ref Not You? Call 18002586161';
  String fromFriend({String amount = '500.00', String ref = '431255556666'}) =>
      'Received Rs.$amount in your Kotak Bank AC X5678 from rahul.k@okaxis on 16-11-26.UPI Ref:$ref.';
  String swiggy({String ref = '431234567890', String amount = '250.00'}) =>
      'Sent Rs.$amount From HDFC Bank A/C *1234 To SWIGGY On 16/11/26 Ref $ref Not You? Call 18002586161';

  group('own money (transfers)', () {
    test('a Zerodha settlement is own money coming back, not income', () async {
      final bank = await addAccount('HDFC');
      await capture.ingest([sms(settlement())]);
      final p = (await capture.pending()).single;
      expect(p['description'], 'Zerodha Broking Ltd');
      expect(p['type'], 'TRANSFER');
      expect(p['direction'], 'IN');
      expect(p['category_id'], CategoryIds.brokerFunds);
      expect(p['suggest_source'], 'BUILTIN');
      expect(p['suggest_label'], 'Built-in: broker funds');

      await capture.confirm(p['id'] as String);
      expect(await balanceOf(bank), 112345); // the balance moves…
      final summary = await transactions.summary(start: DateTime(2026, 11, 1), end: DateTime(2026, 11, 30));
      expect(summary['total_income'], 0.0); // …but it is not income
      expect(summary['total_expense'], 0.0);
    });

    test('adding funds to the broker lowers the balance without being spending', () async {
      final bank = await addAccount('HDFC');
      await capture.ingest([sms(addFunds())]);
      final p = (await capture.pending()).single;
      expect(p['type'], 'TRANSFER');
      expect(p['direction'], 'OUT');
      await capture.confirm(p['id'] as String);
      expect(await balanceOf(bank), 90000);
      expect((await transactions.summary(start: DateTime(2026, 11, 1)))['total_expense'], 0.0);

      // Undo and delete reverse it the same way.
      await capture.reopen(p['id'] as String);
      expect(await balanceOf(bank), 100000);
      await capture.confirm(p['id'] as String);
      await transactions.delete(p['id'] as String);
      expect(await balanceOf(bank), 100000);
    });

    test('built-in rules: card bill, ATM cash, salary', () async {
      await capture.ingest([
        sms('Rs 15,000.00 debited from A/c XX1234 on 16-11-26 towards your ICICI Credit Card XX9876 bill. UPI Ref 431200001111', at: later(1)),
        sms('Rs.2000.00 withdrawn at ATM S1AW0012 from A/c XX1234 on 16-11-26. Avl Bal Rs 5000', at: later(2)),
        sms('INR 85,000.00 credited to A/c XX1234 on 01-11-26 by NEFT from ACME TECH PVT LTD SALARY NOV. Avl bal INR 1,00,000', at: later(3)),
      ]);
      final items = await capture.pending();
      Json find(double amount) => items.firstWhere((p) => p['amount'] == amount);
      expect(find(15000)['category_id'], CategoryIds.cardBill);
      expect(find(15000)['type'], 'TRANSFER');
      expect(find(2000)['category_id'], CategoryIds.cashWithdrawal);
      expect(find(85000)['type'], 'INCOME');
      expect(find(85000)['category_id'], CategoryIds.salary);
    });
  });

  group('teach once', () {
    test('tag the Zerodha settlement once; the next one arrives already tagged', () async {
      await addAccount('HDFC');
      // Pretend the user disagreed with the built-in rule and calls it income.
      await capture.ingest([sms(settlement())]);
      final first = (await capture.pending()).single;
      final similar = await capture.similar(first['id'] as String);
      expect(similar['match_kind'], 'PARTY');
      expect(similar['match_label'], 'name “Zerodha Broking Ltd”');

      final result = await capture.classify(first['id'] as String, {
        'type': 'TRANSFER',
        'category_id': CategoryIds.ownTransfer,
        'remember': true,
      });
      expect(result, {'pending_updated': 0, 'past_updated': 0});
      final now = (await capture.pending()).single;
      expect(now['category_id'], CategoryIds.ownTransfer);
      expect(now['suggest_source'], 'USER');

      // Next quarter: same sender, new amount and date.
      await capture.ingest([sms(settlement(amount: '7,000.00'), at: t0.add(const Duration(days: 90)))]);
      final next = (await capture.pending()).firstWhere((p) => p['amount'] == 7000.0);
      expect(next['type'], 'TRANSFER');
      expect(next['category_id'], CategoryIds.ownTransfer);
      expect(next['suggest_source'], 'RULE');
    });

    test('a rule by UPI ID changes the type, and other waiting payments follow', () async {
      await addAccount('Kotak');
      await capture.ingest([sms(fromFriend(), sender: 'VM-KOTAKB'), sms(fromFriend(amount: '700.00', ref: '431255557777'), sender: 'VM-KOTAKB', at: later(1))]);
      final first = await (capture.pending()).then((l) => l.firstWhere((p) => p['amount'] == 500.0));
      expect(first['type'], 'INCOME');
      expect((await capture.similar(first['id'] as String))['match_label'], 'UPI ID rahul.k@okaxis');
      expect((await capture.similar(first['id'] as String))['other_pending'], 1);

      final result = await capture.classify(first['id'] as String, {'type': 'TRANSFER', 'category_id': CategoryIds.ownTransfer});
      expect(result['pending_updated'], 1);
      final other = (await capture.pending()).firstWhere((p) => p['amount'] == 700.0);
      expect(other['type'], 'TRANSFER');
      expect(other['suggest_source'], 'RULE');

      // Rules keep money in and money out apart.
      final rule = (await capture.rules()).single;
      expect(rule, containsPair('match_kind', 'UPI'));
      expect(rule, containsPair('direction', 'IN'));
      expect(rule, containsPair('category_name', 'Own account transfer'));
    });

    test('"add automatically" skips the inbox and updates the balance', () async {
      final bank = await addAccount('HDFC');
      await capture.ingest([sms(swiggy())]);
      final first = (await capture.pending()).single;
      await capture.classify(first['id'] as String, {'type': 'EXPENSE', 'category_id': CategoryIds.food, 'auto_add': true});
      await capture.confirm(first['id'] as String);

      final next = await capture.ingest([sms(swiggy(ref: '431234500077', amount: '180.00'), at: later(5))]);
      expect(next['added'], 0);
      expect(next['auto_added'], 1);
      expect(await capture.pendingCount(), 0);
      expect(await balanceOf(bank), 100000 - 250 - 180);
      final added = (await transactions.list()).firstWhere((t) => t['amount'] == 180.0);
      expect(added['category_id'], CategoryIds.food);
      expect(added['source'], 'SMS');
    });

    test('"ignore" rules hide such messages from then on', () async {
      await addAccount('HDFC');
      await capture.ingest([sms(swiggy())]);
      final first = (await capture.pending()).single;
      await capture.classify(first['id'] as String, {'type': 'IGNORE'});
      expect(await capture.pendingCount(), 0);
      final next = await capture.ingest([sms(swiggy(ref: '431234500088'), at: later(6))]);
      expect(next['auto_ignored'], 1);
      expect(await capture.pendingCount(), 0);
      expect(await transactions.list(), isEmpty);
    });

    test('fixing past payments corrects totals and balances', () async {
      final kotak = await addAccount('Kotak', balance: 0);
      // Two payments from Rahul were added as income earlier.
      await capture.ingest([sms(fromFriend(), sender: 'VM-KOTAKB'), sms(fromFriend(amount: '700.00', ref: '431255557777'), sender: 'VM-KOTAKB', at: later(1))]);
      for (final p in await capture.pending()) {
        await capture.confirm(p['id'] as String, {'category_id': CategoryIds.otherIncome});
      }
      expect((await transactions.summary(start: DateTime(2026, 11, 1)))['total_income'], 1200.0);
      expect(await balanceOf(kotak), 1200);

      // A third arrives; the user says these are own-money transfers, past ones too.
      await capture.ingest([sms(fromFriend(amount: '300.00', ref: '431255558888'), sender: 'VM-KOTAKB', at: later(2))]);
      final third = (await capture.pending()).single;
      final similar = await capture.similar(third['id'] as String);
      expect(similar['past'], 2);
      expect((similar['rule'] as Json)['type'], 'INCOME'); // learned quietly when confirmed

      final result = await capture.classify(third['id'] as String, {
        'type': 'TRANSFER',
        'category_id': CategoryIds.ownTransfer,
        'apply_to_past': true,
      });
      expect(result['past_updated'], 2);
      expect((await transactions.summary(start: DateTime(2026, 11, 1)))['total_income'], 0.0);
      expect(await balanceOf(kotak), 1200); // still money that arrived

      // Ignoring them (and the past) takes the money back out.
      await capture.reopen((await transactions.list()).first['id'] as String);
      final again = (await capture.pending()).first;
      await capture.classify(again['id'] as String, {'type': 'IGNORE', 'apply_to_past': true});
      expect(await transactions.list(), isEmpty);
      expect(await balanceOf(kotak), 0);
    });

    test('messages without a name are recognised by their wording', () async {
      await addAccount('HDFC');
      String netflix(String amount, String date) => 'Rs.$amount debited from A/c XX1234 for Netflix subscription mandate on $date';
      await capture.ingest([sms(netflix('199.00', '16-11-26'))]);
      final first = (await capture.pending()).single;
      final similar = await capture.similar(first['id'] as String);
      expect(similar['match_kind'], 'TEMPLATE');
      await capture.classify(first['id'] as String, {'type': 'EXPENSE', 'category_id': CategoryIds.entertainment});

      await capture.ingest([sms(netflix('649.00', '16-12-26'), at: t0.add(const Duration(days: 30)))]);
      final next = (await capture.pending()).firstWhere((p) => p['amount'] == 649.0);
      expect(next['category_id'], CategoryIds.entertainment);
      expect(next['suggest_source'], 'RULE');
    });

    test('a bare debit with no name or wording to learn from changes only itself', () async {
      await addAccount('HDFC');
      await capture.ingest([sms('Rs 250.00 debited from A/c XX1234 on 16-11-26. UPI Ref 431234567000.')]);
      final p = (await capture.pending()).single;
      expect((await capture.similar(p['id'] as String))['match_kind'], isNull);
      final result = await capture.classify(p['id'] as String, {'type': 'EXPENSE', 'category_id': CategoryIds.food});
      expect(result, {'pending_updated': 0, 'past_updated': 0});
      expect(await capture.rules(), isEmpty);
    });

    test('the category must fit the kind', () async {
      await capture.ingest([sms(swiggy())]);
      final p = (await capture.pending()).single;
      Object? error;
      try {
        await capture.classify(p['id'] as String, {'type': 'TRANSFER', 'category_id': CategoryIds.food});
      } catch (e) {
        error = e;
      }
      expect(error, isA<ValidationException>());
    });
  });

  group('rules screen', () {
    test('edit, switch auto-add, delete', () async {
      await addAccount('HDFC');
      await capture.ingest([sms(swiggy())]);
      await capture.confirm((await capture.pending()).single['id'] as String);
      final rule = (await capture.rules()).single;
      expect(rule['match_kind'], 'PARTY');
      expect(rule['label'], 'Swiggy');
      expect(rule['auto_add'], false);

      await capture.updateRule(rule['id'] as String, {'category_id': CategoryIds.shopping, 'auto_add': true});
      expect((await capture.rules()).single, containsPair('category_name', 'Shopping & Lifestyle'));
      expect((await capture.rules()).single, containsPair('auto_add', true));

      await capture.updateRule(rule['id'] as String, {'type': 'IGNORE'});
      expect((await capture.rules()).single, containsPair('auto_add', false));
      expect((await capture.rules()).single['category_id'], isNull);

      await capture.deleteRule(rule['id'] as String);
      expect(await capture.rules(), isEmpty);
    });
  });

  test('a payment seen as SMS and as a Google Pay notification shows both', () async {
    await capture.ingest([sms(swiggy())]);
    await capture.ingest([
      sms('You paid ₹250.00 to Swiggy', sender: 'GPAY', source: 'UPI_NOTIFICATION', at: t0.add(const Duration(minutes: 2))),
    ]);
    final p = (await capture.pending()).single;
    expect(p['seen_via'], [
      {'source': 'SMS', 'label': 'HDFC Bank'},
      {'source': 'UPI_NOTIFICATION', 'label': 'Google Pay'},
    ]);
  });

  test('a version 4 database upgrades: merchant rules become name rules', () {
    final dir = Directory.systemTemp.createTempSync('finverse_v5');
    final path = '${dir.path}${Platform.pathSeparator}finverse.db';
    try {
      final old = sqlite3.open(path);
      old.execute("PRAGMA key = 'k'");
      for (final m in migrations.take(4)) {
        old.execute(m);
      }
      old.execute('PRAGMA user_version = 4');
      old.execute(
        "INSERT INTO categories (id, name, type, is_system, created_at) VALUES ('${CategoryIds.food}', 'Food & Groceries', 'EXPENSE', 1, 'x')",
      );
      old.execute("INSERT INTO merchant_rules (merchant_key, category_id, hits, updated_at) VALUES ('swiggy', '${CategoryIds.food}', 3, 'x')");
      old.execute('''INSERT INTO transactions (id, type, amount_minor, date, description, source, status, merchant, bank, raw_text, created_at)
                     VALUES ('t1', 'EXPENSE', 25000, '2026-11-16', 'Swiggy', 'SMS', 'PENDING', 'Swiggy', 'HDFC Bank',
                             'Rs 250 debited from A/c XX1234 to VPA swiggy@icici on 16-11-26', 'x')''');
      old.close();

      final upgraded = LocalDb.openFile(path, key: 'k');
      expect(upgraded.queryOne('PRAGMA user_version')!.values.first, migrations.length);
      expect(
        upgraded.queryOne('SELECT match_kind, match_value, direction, type, category_id, hits FROM capture_rules'),
        {'match_kind': 'PARTY', 'match_value': 'swiggy', 'direction': 'OUT', 'type': 'EXPENSE', 'category_id': CategoryIds.food, 'hits': 3},
      );
      expect(
        upgraded.queryOne("SELECT direction, vpa, seen_via FROM transactions WHERE id = 't1'"),
        {'direction': 'OUT', 'vpa': 'swiggy@icici', 'seen_via': 'SMS:HDFC Bank'},
      );
      upgraded.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
