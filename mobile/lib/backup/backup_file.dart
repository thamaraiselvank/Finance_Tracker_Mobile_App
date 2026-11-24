/// Encrypted backup files: everything on the phone, locked with the user's
/// backup password.
///
/// A backup is itself a small SQLite database (same tables as the phone's),
/// encrypted by SQLite3MultipleCiphers with ChaCha20-Poly1305. The key is made
/// from the password with PBKDF2-SHA256 ([backupKdfIterations] rounds) and a
/// random salt stored in the file, so every backup has a different key and a
/// wrong password, a damaged file or a changed byte is detected before
/// anything on the phone is touched.
///
/// The phone's own database key (in the Android Keystore) is never used or
/// stored here: it can't move to a new phone, the password can.
///
/// The functions that touch the password ([writeBackupFile], [readBackupFile])
/// are pure and synchronous so they can run in a background isolate; the
/// password stretching takes a moment on a phone.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../local/local_db.dart';
import '../local/schema.dart';
import '../services/errors.dart';

/// File name extension for Finverse backups.
const backupExtension = 'fvbackup';

/// PBKDF2 rounds for the backup key (OWASP 2023 figure for PBKDF2-SHA256).
/// Changing it makes older backups unreadable, so only ever add a fallback.
const backupKdfIterations = 600000;

/// Shortest backup password accepted.
const minBackupPasswordLength = 8;

/// Version of the backup layout (the info table below). Bumped only if the
/// file layout changes; table changes are covered by the schema version.
const _formatVersion = 1;
const _infoTable = 'finverse_backup';

/// A problem with a backup file, worded for the user.
class BackupException extends ServiceException {
  const BackupException(super.message);
}

/// Everything to put in a backup, read from the phone database.
class BackupSnapshot {
  const BackupSnapshot({required this.schemaVersion, required this.schemaSql, required this.tables});

  /// `PRAGMA user_version` of the phone database (number of migrations run).
  final int schemaVersion;

  /// CREATE statements: tables first, then indexes.
  final List<String> schemaSql;

  /// Every row of every table, by table name.
  final Map<String, List<Map<String, Object?>>> tables;
}

/// What a backup holds, as shown before restoring.
class BackupSummary {
  const BackupSummary({required this.createdAt, required this.schemaVersion, required this.counts, this.profileName});

  final DateTime createdAt;
  final int schemaVersion;

  /// Name of the person the backup belongs to (from the profile), if set.
  final String? profileName;

  /// Record counts: accounts, transactions, inbox, budgets, goals, debts,
  /// insurance, holdings, recurring, rules.
  final Map<String, int> counts;

  Map<String, dynamic> toJson() => {'created_at': createdAt.toIso8601String(), 'schema_version': schemaVersion, 'profile_name': profileName, 'counts': counts};
}

/// A decrypted backup, already upgraded to this app's table layout.
class BackupContents {
  const BackupContents(this.summary, this.tables);
  final BackupSummary summary;
  final Map<String, List<Map<String, Object?>>> tables;
}

// ---------------------------------------------------------------------------
// Phone database -> snapshot -> file
// ---------------------------------------------------------------------------

/// Reads every table of the phone database (`LocalDb.raw`). Fast: no
/// encryption work.
BackupSnapshot takeSnapshot(Database db) {
  final version = db.select('PRAGMA user_version').first.values.first as int;
  final objects = db.select(
    "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
    "AND type IN ('table', 'index') ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, rowid",
  );
  final tables = <String, List<Map<String, Object?>>>{};
  for (final o in objects.where((o) => o['type'] == 'table')) {
    final name = o['name'] as String;
    tables[name] = [for (final r in db.select('SELECT * FROM "$name"')) Map<String, Object?>.from(r)];
  }
  return BackupSnapshot(schemaVersion: version, schemaSql: [for (final o in objects) o['sql'] as String], tables: tables);
}

/// Writes [snapshot] to a new encrypted file at [path], locked with [password].
/// Returns what was saved. Replaces any file already at [path].
BackupSummary writeBackupFile(String path, String password, BackupSnapshot snapshot, {DateTime? now, int kdfIterations = backupKdfIterations}) {
  checkBackupPassword(password);
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final createdAt = (now ?? DateTime.now()).toUtc();
  final db = _openLocked(path, password, kdfIterations);
  try {
    db.execute('BEGIN');
    for (final sql in snapshot.schemaSql) {
      db.execute(sql);
    }
    db.execute('CREATE TABLE $_infoTable (key TEXT PRIMARY KEY, value TEXT)');
    final info = db.prepare('INSERT INTO $_infoTable (key, value) VALUES (?, ?)');
    for (final (k, v) in [
      ('app', 'Finverse'),
      ('format', '$_formatVersion'),
      ('created_at', createdAt.toIso8601String()),
      ('schema_version', '${snapshot.schemaVersion}'),
    ]) {
      info.execute([k, v]);
    }
    info.close();
    snapshot.tables.forEach((table, rows) => _insertRows(db, table, rows));
    db.execute('PRAGMA user_version = ${snapshot.schemaVersion}');
    db.execute('COMMIT');
  } catch (_) {
    db.close();
    if (file.existsSync()) file.deleteSync();
    rethrow;
  }
  db.close();
  return _summarise(snapshot.tables, createdAt, snapshot.schemaVersion);
}

// ---------------------------------------------------------------------------
// File -> contents -> phone database
// ---------------------------------------------------------------------------

/// Opens and checks a backup. The file at [path] must be a private copy: if
/// the backup was made by an older app version it is upgraded in place.
/// Throws [BackupException] (wrong password, not a backup, damaged, or made
/// by a newer app version).
BackupContents readBackupFile(String path, String password, {int kdfIterations = backupKdfIterations}) {
  if (!File(path).existsSync()) throw const BackupException('The backup file could not be found.');
  final db = _openLocked(path, password, kdfIterations);
  try {
    db.select('SELECT count(*) FROM sqlite_master');
  } on SqliteException {
    db.close();
    throw const BackupException('Wrong password, or this file is not a Finverse backup.');
  }
  try {
    final hasInfo = db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '$_infoTable'").isNotEmpty;
    if (!hasInfo) throw const BackupException('This file is not a Finverse backup.');
    final info = {for (final r in db.select('SELECT key, value FROM $_infoTable')) r['key'] as String: r['value'] as String?};
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if ((int.tryParse(info['format'] ?? '') ?? 99) > _formatVersion || version > migrations.length) {
      throw const BackupException('This backup was made by a newer version of Finverse. Update the app, then restore it.');
    }
    final check = db.select('PRAGMA quick_check').first.values.first;
    if (check != 'ok') throw const BackupException('This backup file is damaged and cannot be restored.');

    // Bring an older backup up to today's tables (same steps as an app update).
    migrate(db);

    final names = [
      for (final r in db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != '$_infoTable'"))
        r['name'] as String,
    ];
    final tables = {
      for (final name in names) name: [for (final r in db.select('SELECT * FROM "$name"')) Map<String, Object?>.from(r)],
    };
    final createdAt = DateTime.tryParse(info['created_at'] ?? '') ?? File(path).lastModifiedSync();
    return BackupContents(_summarise(tables, createdAt, version), tables);
  } on SqliteException {
    throw const BackupException('This backup file is damaged and cannot be restored.');
  } finally {
    db.close();
  }
}

/// Replaces everything in the phone database with [contents], in one step:
/// if anything fails, the phone keeps its current data.
void restoreInto(LocalDb db, BackupContents contents) {
  final tables = [for (final r in db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) r['name'] as String];
  // Rows are copied table by table, so references are checked once at the end.
  db.execute('PRAGMA foreign_keys = OFF');
  try {
    db.transaction(() {
      for (final t in tables) {
        db.execute('DELETE FROM "$t"');
      }
      for (final t in tables) {
        final rows = contents.tables[t];
        if (rows == null || rows.isEmpty) continue;
        final columns = {for (final c in db.query('PRAGMA table_info("$t")')) c['name'] as String};
        _insertRows(db.raw, t, rows, onlyColumns: columns);
      }
      if (db.query('PRAGMA foreign_key_check').isNotEmpty) {
        throw const BackupException('This backup file is damaged and cannot be restored.');
      }
    });
  } finally {
    db.execute('PRAGMA foreign_keys = ON');
  }
}

/// Throws if [password] is too weak to protect a backup.
void checkBackupPassword(String password) {
  if (password.length < minBackupPasswordLength) {
    throw const BackupException('Use a backup password of at least $minBackupPasswordLength characters.');
  }
}

/// File name for a backup made at [time], e.g. `finverse-2026-11-24-0930.fvbackup`.
String backupFileName(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'finverse-${time.year}-${two(time.month)}-${two(time.day)}-${two(time.hour)}${two(time.minute)}.$backupExtension';
}

// ---------------------------------------------------------------------------

Database _openLocked(String path, String password, int kdfIterations) {
  final db = sqlite3.open(path);
  try {
    // Cipher settings must come before the key.
    db.execute("PRAGMA cipher = 'chacha20'");
    db.execute('PRAGMA kdf_iter = $kdfIterations');
    db.execute("PRAGMA key = '${password.replaceAll("'", "''")}'");
  } catch (_) {
    db.close();
    rethrow;
  }
  return db;
}

void _insertRows(Database db, String table, List<Map<String, Object?>> rows, {Set<String>? onlyColumns}) {
  if (rows.isEmpty) return;
  final columns = [
    for (final c in rows.first.keys)
      if (onlyColumns == null || onlyColumns.contains(c)) c,
  ];
  if (columns.isEmpty) return;
  final statement = db.prepare('INSERT INTO "$table" (${columns.map((c) => '"$c"').join(', ')}) VALUES (${List.filled(columns.length, '?').join(', ')})');
  try {
    for (final row in rows) {
      statement.execute([for (final c in columns) row[c]]);
    }
  } finally {
    statement.close();
  }
}

BackupSummary _summarise(Map<String, List<Map<String, Object?>>> tables, DateTime createdAt, int schemaVersion) {
  int count(String table) => tables[table]?.length ?? 0;
  int txs(String status) => tables['transactions']?.where((t) => t['status'] == status).length ?? 0;
  final profile = tables['profile'];
  final name = profile == null || profile.isEmpty ? null : profile.first['full_name'] as String?;
  return BackupSummary(
    createdAt: createdAt,
    schemaVersion: schemaVersion,
    profileName: name == null || name.trim().isEmpty ? null : name.trim(),
    counts: {
      'accounts': count('accounts'),
      'transactions': txs('CONFIRMED'),
      'inbox': txs('PENDING'),
      'budgets': count('budgets'),
      'goals': count('goals'),
      'debts': count('debts'),
      'insurance': count('insurance_policies'),
      'holdings': count('assets'),
      'recurring': count('scheduled_cashflows'),
      'rules': count('capture_rules'),
    },
  );
}
