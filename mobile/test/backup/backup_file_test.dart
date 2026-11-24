import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_tracker_mobile/backup/backup_file.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/local/schema.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Fewer password-stretching rounds keep the tests quick; the app uses
/// [backupKdfIterations].
const _iter = 2000;
const _password = 'mango-tree-42';

void main() {
  late Directory dir;
  String file(String name) => '${dir.path}${Platform.pathSeparator}$name';

  setUp(() => dir = Directory.systemTemp.createTempSync('finverse_backup_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A phone database with something in every area.
  Future<LocalDb> filledDb() async {
    final db = LocalDb.inMemory();
    final s = localServices(db);
    await s.auth.updateProfile({'full_name': 'Asha', 'monthly_income': 90000});
    await s.accounts.create({'name': 'HDFC Savings', 'account_type': 'SAVINGS', 'balance': 50000});
    final accountId = (await s.accounts.list()).first['id'] as String;
    await s.transactions.create({
      'account_id': accountId,
      'type': 'EXPENSE',
      'amount': 1250.5,
      'date': '2026-11-02',
      'description': 'Swiggy',
      'category_id': '00000000-0000-0000-0000-000000000011',
    });
    await s.goals.create({'goal_name': 'House', 'goal_type': 'DOWN_PAYMENT', 'target_amount': 1000000, 'target_date': '2030-01-01'});
    await s.debts.create({
      'debt_name': 'Car loan',
      'debt_type': 'CAR_LOAN',
      'principal_amount': 500000,
      'current_outstanding': 300000,
      'interest_rate_pct': 9.5,
    });
    await s.assets.create({'name': 'Nifty 50 index fund', 'asset_class': 'MUTUAL_FUND', 'invested_amount': 20000, 'current_value': 23000});
    await s.insurance.create({'policy_name': 'Family health', 'policy_type': 'HEALTH', 'sum_insured': 1000000, 'annual_premium': 18000});
    await s.capture!.ingest([
      CapturedMessage(
        source: 'SMS',
        sender: 'AX-HDFCBK',
        body: 'Rs.499.00 debited from A/c XX1234 on 03-11-26 to VPA netflix@icici UPI Ref 412345678901. -HDFC Bank',
        receivedAt: DateTime(2026, 11, 3, 10),
      ),
    ]);
    return db;
  }

  Map<String, List<Map<String, Object?>>> everything(LocalDb db) => takeSnapshot(db.raw).tables;

  test('a backup restores every table exactly, on a fresh phone', () async {
    final phone = await filledDb();
    final before = everything(phone);
    final summary = writeBackupFile(file('b.fvbackup'), _password, takeSnapshot(phone.raw), kdfIterations: _iter);
    expect(summary.counts, containsPair('transactions', 1));
    expect(summary.counts, containsPair('inbox', 1));
    expect(summary.counts, containsPair('goals', 1));
    expect(summary.counts, containsPair('holdings', 1));
    expect(summary.profileName, 'Asha');

    final newPhone = LocalDb.inMemory();
    final contents = readBackupFile(file('b.fvbackup'), _password, kdfIterations: _iter);
    expect(contents.summary.counts, summary.counts);
    restoreInto(newPhone, contents);
    expect(everything(newPhone), before);
    expect(newPhone.queryOne('PRAGMA foreign_keys')!.values.first, 1);
  });

  test('restoring replaces what was on the phone (nothing old is left)', () async {
    final phone = LocalDb.inMemory();
    await localServices(phone).accounts.create({'name': 'Old wallet', 'account_type': 'WALLET', 'balance': 10});
    final source = await filledDb();
    writeBackupFile(file('b.fvbackup'), _password, takeSnapshot(source.raw), kdfIterations: _iter);
    restoreInto(phone, readBackupFile(file('b.fvbackup'), _password, kdfIterations: _iter));
    final names = [for (final a in await localServices(phone).accounts.list()) a['name']];
    expect(names, ['HDFC Savings']);
  });

  test('the file is unreadable without the password', () async {
    final phone = await filledDb();
    writeBackupFile(file('b.fvbackup'), _password, takeSnapshot(phone.raw), kdfIterations: _iter);
    final bytes = File(file('b.fvbackup')).readAsBytesSync();
    final text = latin1.decode(bytes);
    expect(text.contains('Swiggy'), isFalse);
    expect(text.contains('HDFC'), isFalse);
    expect(text.startsWith('SQLite format 3'), isFalse);

    expect(
      () => readBackupFile(file('b.fvbackup'), 'wrong-password', kdfIterations: _iter),
      throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('Wrong password'))),
    );
  });

  test('a changed byte is detected', () async {
    final phone = await filledDb();
    writeBackupFile(file('b.fvbackup'), _password, takeSnapshot(phone.raw), kdfIterations: _iter);
    final bytes = File(file('b.fvbackup')).readAsBytesSync();
    final tampered = Uint8List.fromList(bytes);
    tampered[tampered.length - 100] ^= 0xff; // inside the last page
    File(file('t.fvbackup')).writeAsBytesSync(tampered);
    expect(() => readBackupFile(file('t.fvbackup'), _password, kdfIterations: _iter), throwsA(isA<BackupException>()));
  });

  test('a random file is not mistaken for a backup', () {
    File(file('photo.jpg')).writeAsBytesSync(List.generate(8192, (i) => i % 251));
    expect(() => readBackupFile(file('photo.jpg'), _password, kdfIterations: _iter), throwsA(isA<BackupException>()));
  });

  test('a backup made by an older app version is upgraded while restoring', () {
    // A phone still on schema version 4 (before capture rules existed).
    final old = sqlite3.openInMemory();
    for (var v = 0; v < 4; v++) {
      old.execute(migrations[v]);
    }
    old.execute('PRAGMA user_version = 4');
    final now = nowTimestamp();
    old.execute("INSERT INTO accounts (id, name, account_type, created_at, updated_at) VALUES ('a1', 'SBI', 'SAVINGS', ?, ?)", [now, now]);
    old.execute(
      '''INSERT INTO transactions (id, account_id, type, amount_minor, date, description, source, status, created_at)
                   VALUES ('t1', 'a1', 'INCOME', 500000, '2026-10-01', 'Salary', 'SMS', 'CONFIRMED', ?)''',
      [now],
    );
    writeBackupFile(file('old.fvbackup'), _password, takeSnapshot(old), kdfIterations: _iter);

    final contents = readBackupFile(file('old.fvbackup'), _password, kdfIterations: _iter);
    expect(contents.summary.schemaVersion, 4);
    expect(contents.tables.containsKey('capture_rules'), isTrue);
    final phone = LocalDb.inMemory();
    restoreInto(phone, contents);
    // The newer migration's backfill ran: SMS income moved money IN.
    expect(phone.queryOne("SELECT direction FROM transactions WHERE id = 't1'")!['direction'], 'IN');
  });

  test('a backup from a newer app version is refused, not half-restored', () {
    final newer = sqlite3.openInMemory()..execute('CREATE TABLE future_things (id TEXT)');
    newer.execute('PRAGMA user_version = ${migrations.length + 1}');
    writeBackupFile(file('new.fvbackup'), _password, takeSnapshot(newer), kdfIterations: _iter);
    expect(
      () => readBackupFile(file('new.fvbackup'), _password, kdfIterations: _iter),
      throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('newer version'))),
    );
  });

  test('if restoring fails part-way, the phone keeps its data', () async {
    final phone = await filledDb();
    final before = everything(phone);
    // A transaction pointing at an account that is not in the backup.
    final broken = BackupContents(BackupSummary(createdAt: DateTime.utc(2026), schemaVersion: migrations.length, counts: const {}), {
      'transactions': [
        {'id': 'x', 'account_id': 'missing', 'type': 'EXPENSE', 'amount_minor': 1, 'date': '2026-01-01', 'description': 'x', 'created_at': 'x'},
      ],
    });
    expect(() => restoreInto(phone, broken), throwsA(isA<BackupException>()));
    expect(everything(phone), before);
    expect(phone.queryOne('PRAGMA foreign_keys')!.values.first, 1);
  });

  test('weak passwords are refused', () async {
    final phone = await filledDb();
    expect(() => writeBackupFile(file('b.fvbackup'), 'short', takeSnapshot(phone.raw), kdfIterations: _iter), throwsA(isA<BackupException>()));
    expect(File(file('b.fvbackup')).existsSync(), isFalse);
  });

  test('file names sort by date', () {
    expect(backupFileName(DateTime(2026, 3, 9, 7, 5)), 'finverse-2026-03-09-0705.fvbackup');
  });
}
