import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

typedef Row = Map<String, dynamic>;

/// The on-phone database: one encrypted SQLite file inside the app's private
/// storage. Replaces PostgreSQL for local mode.
///
/// SQL here is synchronous (package:sqlite3 talks to SQLite directly), which
/// is fast for the small queries a personal finance app runs.
class LocalDb {
  LocalDb._(this.raw) {
    raw.execute('PRAGMA foreign_keys = ON');
    migrate(raw);
  }

  final Database raw;

  static const _fileName = 'finverse.db';
  static const _keyName = 'finverse_db_key';

  /// Opens (or creates) the encrypted database file. The encryption key is a
  /// random 256-bit value created on first launch and kept in the Android
  /// Keystore via flutter_secure_storage; it never leaves the phone.
  static Future<LocalDb> openEncrypted({FlutterSecureStorage storage = const FlutterSecureStorage()}) async {
    final dir = await getApplicationSupportDirectory();
    var key = await storage.read(key: _keyName);
    if (key == null) {
      key = _randomKey();
      await storage.write(key: _keyName, value: key);
    }
    return openFile('${dir.path}${Platform.pathSeparator}$_fileName', key: key);
  }

  /// Opens a database file with the given key (also used by tests).
  static LocalDb openFile(String path, {required String key}) {
    final db = sqlite3.open(path);
    try {
      // Must be the first statement on the connection.
      db.execute("PRAGMA key = '${key.replaceAll("'", "''")}'");
      // Fails here (not later) if the key is wrong or the file isn't ours.
      db.select('SELECT count(*) FROM sqlite_master');
    } catch (_) {
      db.close();
      rethrow;
    }
    return LocalDb._(db);
  }

  /// A throwaway in-memory database for tests.
  factory LocalDb.inMemory() => LocalDb._(sqlite3.openInMemory());

  List<Row> query(String sql, [List<Object?> params = const []]) =>
      [for (final r in raw.select(sql, params)) Map<String, dynamic>.from(r)];

  Row? queryOne(String sql, [List<Object?> params = const []]) {
    final rows = query(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  void execute(String sql, [List<Object?> params = const []]) => raw.execute(sql, params);

  /// Number of rows changed by the last INSERT/UPDATE/DELETE.
  int get changes => raw.updatedRows;

  /// Runs [body] atomically: everything is saved, or nothing is.
  T transaction<T>(T Function() body) {
    raw.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      raw.execute('COMMIT');
      return result;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => raw.close();

  static String _randomKey() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
  }
}

/// Random UUID v4, used for record ids (same format as the backend's ids).
String newId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Current time as an ISO-8601 UTC timestamp, like the backend's `created_at`.
String nowTimestamp() => DateTime.now().toUtc().toIso8601String();
