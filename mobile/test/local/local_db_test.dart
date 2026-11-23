import 'dart:convert';
import 'dart:io';

import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('schema', () {
    test('a new database is migrated and seeded with the default categories', () {
      final db = LocalDb.inMemory();
      expect(db.queryOne('PRAGMA user_version')!.values.first, migrations.length);
      expect(db.queryOne('SELECT count(*) AS n FROM categories WHERE is_system = 1')!['n'], 17);
      expect(db.queryOne('SELECT count(*) AS n FROM subcategories')!['n'], 45);
      expect(db.queryOne("SELECT name FROM categories WHERE id = '00000000-0000-0000-0000-000000000011'")!['name'], 'Food & Groceries');
      expect(db.queryOne('PRAGMA foreign_keys')!.values.first, 1);
      db.close();
    });

    test('a failed transaction leaves nothing behind', () {
      final db = LocalDb.inMemory();
      expect(
        () => db.transaction(() {
          db.execute("INSERT INTO app_settings (key, value) VALUES ('a', '1')");
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(db.queryOne("SELECT * FROM app_settings WHERE key = 'a'"), isNull);
      db.close();
    });
  });

  group('encryption', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('finverse_db_test');
      path = '${dir.path}${Platform.pathSeparator}finverse.db';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('the file on disk is unreadable without the key', () {
      final db = LocalDb.openFile(path, key: 'correct horse battery staple');
      db.execute("INSERT INTO app_settings (key, value) VALUES ('secret', 'HDFC salary 85000')");
      db.close();

      // The plain text never appears in the file.
      final bytes = File(path).readAsBytesSync();
      expect(latin1.decode(bytes).contains('HDFC salary'), isFalse);
      expect(latin1.decode(bytes.sublist(0, 16)).startsWith('SQLite format 3'), isFalse);

      // The right key opens it again.
      final reopened = LocalDb.openFile(path, key: 'correct horse battery staple');
      expect(reopened.queryOne("SELECT value FROM app_settings WHERE key = 'secret'")!['value'], 'HDFC salary 85000');
      reopened.close();

      // A wrong key does not.
      expect(() => LocalDb.openFile(path, key: 'wrong key'), throwsA(anything));
    });
  });

  test('newId produces distinct UUID v4 values', () {
    final ids = {for (var i = 0; i < 1000; i++) newId()};
    expect(ids.length, 1000);
    expect(ids.first, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });
}
