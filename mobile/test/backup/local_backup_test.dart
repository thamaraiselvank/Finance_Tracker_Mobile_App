import 'dart:io';

import 'package:finance_tracker_mobile/local/local_backup.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('finverse_backup_service'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('create, inspect and restore through the service (background isolate)', () async {
    final phone = LocalDb.inMemory();
    final services = localServices(phone);
    await services.accounts.create({'name': 'Kotak', 'account_type': 'SAVINGS', 'balance': 1234.56});
    final backup = LocalBackupService(phone, kdfIterations: 2000, now: () => DateTime(2026, 11, 24, 9, 30));

    final made = await backup.create('blue-river-77', directory: dir.path);
    expect(made['file_name'], 'finverse-2026-11-24-0930.fvbackup');
    expect(File(made['path'] as String).existsSync(), isTrue);
    expect(made['summary']['counts']['accounts'], 1);

    final summary = await backup.inspect(made['path'] as String, 'blue-river-77');
    expect(summary['counts']['accounts'], 1);
    await expectLater(backup.inspect(made['path'] as String, 'not-the-password'), throwsA(isA<Exception>()));

    final newPhone = LocalDb.inMemory();
    await LocalBackupService(newPhone, kdfIterations: 2000).restore(made['path'] as String, 'blue-river-77');
    final accounts = await localServices(newPhone).accounts.list();
    expect(accounts.single['name'], 'Kotak');
    expect(accounts.single['balance'], 1234.56);
  });
}
