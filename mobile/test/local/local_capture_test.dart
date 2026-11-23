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

void main() {
  late LocalDb db;
  late LocalCaptureService capture;
  late LocalAccountsService accounts;
  late LocalTransactionsService transactions;
  final t0 = DateTime(2026, 11, 12, 10, 30);

  setUp(() {
    db = LocalDb.inMemory();
    capture = LocalCaptureService(db);
    accounts = LocalAccountsService(db);
    transactions = LocalTransactionsService(db, today: () => DateTime(2026, 11, 23));
  });
  tearDown(() => db.close());

  CapturedMessage sms(String body, {String sender = 'AX-HDFCBK', DateTime? at}) =>
      CapturedMessage(source: 'SMS', sender: sender, body: body, receivedAt: at ?? t0);

  String swiggy({String ref = '431234567890', String amount = '250.00', String last4 = '1234'}) =>
      'Sent Rs.$amount From HDFC Bank A/C *$last4 To SWIGGY On 12/11/26 Ref $ref Not You? Call 18002586161';

  Future<String> addAccount(String name, {double balance = 1000}) async {
    await accounts.create({'name': name, 'account_type': 'SAVINGS', 'balance': balance});
    return (await accounts.list()).firstWhere((a) => a['name'] == name)['id'] as String;
  }

  Future<double> balanceOf(String id) async => (await accounts.list()).firstWhere((a) => a['id'] == id)['balance'] as double;

  Future<Object?> errorOf(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      return e;
    }
    return null;
  }

  group('ingest', () {
    test('payments go to the inbox, not to Money', () async {
      final id = await addAccount('HDFC');
      final result = await capture.ingest([
        sms(swiggy()),
        sms('123456 is your OTP for txn of Rs 99 at X on card ending 9012', at: t0.add(const Duration(minutes: 1))),
      ]);
      expect(result, {'read': 2, 'added': 1, 'duplicates': 0, 'skipped': 1});
      expect(await capture.pendingCount(), 1);
      expect(await transactions.list(), isEmpty);
      expect(await balanceOf(id), 1000);

      final p = (await capture.pending()).single;
      expect(p['description'], 'Swiggy');
      expect(p['amount'], 250.0);
      expect(p['type'], 'EXPENSE');
      expect(p['bank'], 'HDFC Bank');
      expect(p['account_last4'], '1234');
      expect(p['upi_ref'], '431234567890');
      expect(p['date'], '2026-11-12');
      expect(p['category_id'], CategoryIds.food); // keyword suggestion
      expect(p['source'], 'SMS');
    });

    test('reading the same SMS again adds nothing', () async {
      await capture.ingest([sms(swiggy()), sms('Rs 120 debited from A/c XX1234 at CAFE COFFEE DAY on 12-11-26.', at: t0.add(const Duration(hours: 1)))]);
      final again = await capture.ingest([sms(swiggy()), sms('Rs 120 debited from A/c XX1234 at CAFE COFFEE DAY on 12-11-26.', at: t0.add(const Duration(hours: 1)))]);
      expect(again['added'], 0);
      expect(again['duplicates'], 2);
      expect(await capture.pendingCount(), 2);
    });

    test('the same payment from two sources is merged; different UPI refs are not', () async {
      // Bank SMS with a ref, then a payment-app message without one, 3 minutes later.
      await capture.ingest([sms(swiggy())]);
      final app = await capture.ingest([
        sms('You paid Rs 250 to Swiggy via UPI from a/c XX1234', sender: 'VM-PAYTMB', at: t0.add(const Duration(minutes: 3))),
      ]);
      expect(app['duplicates'], 1);
      // Two genuine Rs 250 payments a minute apart with different refs.
      final second = await capture.ingest([sms(swiggy(ref: '431234567891'), at: t0.add(const Duration(minutes: 1)))]);
      expect(second['added'], 1);
      expect(await capture.pendingCount(), 2);
    });

    test('accounts are matched by last digits; a single unlinked account is used', () async {
      final only = await addAccount('My bank');
      await capture.ingest([sms(swiggy())]);
      expect((await capture.pending()).single['account_id'], only);

      final other = await addAccount('Axis');
      await accounts.update(other, {});
      db.execute("UPDATE accounts SET last4 = '5678' WHERE id = ?", [other]);
      await capture.ingest([sms(swiggy(ref: '431234500002', last4: '5678'), at: t0.add(const Duration(hours: 2)))]);
      final p = (await capture.pending()).firstWhere((x) => x['account_last4'] == '5678');
      expect(p['account_id'], other);
    });
  });

  group('review', () {
    test('confirm needs an account, then updates the balance and learns the digits', () async {
      final a = await addAccount('A');
      await addAccount('B'); // two accounts: no automatic choice
      await capture.ingest([sms(swiggy()), sms(swiggy(ref: '431234500009', amount: '100.00'), at: t0.add(const Duration(hours: 1)))]);
      final first = (await capture.pending()).firstWhere((p) => p['amount'] == 250.0);
      expect(first['account_id'], isNull);

      expect((await errorOf(() => capture.confirm(first['id'] as String))).toString(), 'Choose the account for this payment first.');

      await capture.confirm(first['id'] as String, {'account_id': a});
      expect(await balanceOf(a), 750);
      expect((await transactions.list()).single['description'], 'Swiggy');
      // "••1234 is account A" was learned and applied to the other waiting payment.
      expect((await accounts.list()).firstWhere((x) => x['id'] == a)['last4'], '1234');
      expect((await capture.pending()).single['account_id'], a);
    });

    test('a category chosen once is remembered for that merchant', () async {
      final a = await addAccount('A');
      const shopping = CategoryIds.shopping;
      await capture.ingest([
        sms(swiggy()),
        sms(swiggy(ref: '431234500003', amount: '90.00'), at: t0.add(const Duration(hours: 1))),
      ]);
      final items = await capture.pending();
      await capture.confirm(items.first['id'] as String, {'category_id': shopping});
      // The other waiting Swiggy payment follows immediately…
      expect((await capture.pending()).single['category_id'], shopping);
      // …and so does a new one next week.
      await capture.ingest([sms(swiggy(ref: '431234500004', amount: '310.00'), at: t0.add(const Duration(days: 7)))]);
      expect((await capture.pending()).every((p) => p['category_id'] == shopping), isTrue);
      expect(db.queryOne('SELECT hits FROM merchant_rules WHERE merchant_key = ?', ['swiggy'])!['hits'], 1);
      expect(a, isNotNull);
    });

    test('ignore hides it; undo puts it back and reverses the balance', () async {
      final a = await addAccount('A');
      await capture.ingest([sms(swiggy())]);
      final id = (await capture.pending()).single['id'] as String;

      await capture.ignore(id);
      expect(await capture.pendingCount(), 0);
      await capture.reopen(id);
      expect(await capture.pendingCount(), 1);

      await capture.confirm(id);
      expect(await balanceOf(a), 750);
      await capture.reopen(id);
      expect(await balanceOf(a), 1000);
      expect(await capture.pendingCount(), 1);
      expect(await errorOf(() => capture.ignore('nope')), isA<NotFoundException>());
    });

    test('edits before confirming', () async {
      final a = await addAccount('A');
      await capture.ingest([sms(swiggy())]);
      final id = (await capture.pending()).single['id'] as String;
      await capture.updatePending(id, {'amount': 260, 'description': 'Swiggy dinner', 'type': 'expense'});
      await capture.confirm(id);
      final t = (await transactions.list()).single;
      expect(t['amount'], 260.0);
      expect(t['description'], 'Swiggy dinner');
      expect(await balanceOf(a), 740);
      expect((await errorOf(() => capture.updatePending(id, {'amount': 1}))).toString(), 'This payment has already been reviewed.');
    });

    test('a new account can be made from the SMS (bank + last digits)', () async {
      await addAccount('A');
      await addAccount('B');
      await capture.ingest([sms(swiggy()), sms(swiggy(ref: '431234500005'), at: t0.add(const Duration(hours: 3)))]);
      final id = (await capture.pending()).first['id'] as String;
      final accountId = await capture.createAccountFor(id);
      final created = (await accounts.list()).firstWhere((x) => x['id'] == accountId);
      expect(created['name'], 'HDFC Bank ••1234');
      expect(created['last4'], '1234');
      expect(created['balance'], 0.0);
      expect((await capture.pending()).every((p) => p['account_id'] == accountId), isTrue);
    });

    test('deleting a captured transaction never brings it back on the next scan', () async {
      await addAccount('A');
      await capture.ingest([sms(swiggy())]);
      final id = (await capture.pending()).single['id'] as String;
      await capture.confirm(id);
      await transactions.delete(id);
      expect(await transactions.list(), isEmpty);
      expect((await capture.ingest([sms(swiggy())]))['duplicates'], 1);
      expect(await capture.pendingCount(), 0);
    });

    test('remembers when SMS were last read', () async {
      expect(await capture.lastSmsScan(), isNull);
      await capture.setLastSmsScan(t0);
      expect((await capture.lastSmsScan())!.isAtSameMomentAs(t0), isTrue);
    });
  });

  test('a version 1 database (from step 1) upgrades and keeps its data', () {
    final dir = Directory.systemTemp.createTempSync('finverse_upgrade');
    final path = '${dir.path}${Platform.pathSeparator}finverse.db';
    try {
      final old = sqlite3.open(path);
      old.execute("PRAGMA key = 'k'");
      old.execute(migrations[0]);
      old.execute('PRAGMA user_version = 1');
      old.execute(
        "INSERT INTO accounts (id, name, account_type, balance_minor, created_at, updated_at) VALUES ('a1', 'Old account', 'SAVINGS', 12345, 'x', 'x')",
      );
      old.close();

      final upgraded = LocalDb.openFile(path, key: 'k');
      expect(upgraded.queryOne('PRAGMA user_version')!.values.first, migrations.length);
      expect(upgraded.queryOne("SELECT name, balance_minor, last4 FROM accounts WHERE id = 'a1'"),
          {'name': 'Old account', 'balance_minor': 12345, 'last4': null});
      expect(upgraded.queryOne('SELECT count(*) AS n FROM merchant_rules')!['n'], 0);
      upgraded.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
