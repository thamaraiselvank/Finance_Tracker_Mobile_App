import 'dart:io';
import 'dart:isolate';

import '../backup/backup_file.dart';
import '../services/services.dart';
import 'local_db.dart';

/// Backup and restore of the on-phone database (see backup/backup_file.dart).
///
/// Reading the tables and writing them back is quick and happens here; the
/// password stretching and encryption run in a background isolate so the
/// screen stays smooth.
class LocalBackupService implements BackupService {
  LocalBackupService(this._db, {this.kdfIterations = backupKdfIterations, this.inBackground = true, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final LocalDb _db;
  final int kdfIterations;
  final DateTime Function() _now;

  /// False in tests that don't need a second isolate.
  final bool inBackground;

  Future<T> _run<T>(T Function() work) => inBackground ? Isolate.run(work) : Future.sync(work);

  @override
  Future<Json> create(String password, {required String directory}) async {
    checkBackupPassword(password);
    final now = _now();
    final name = backupFileName(now);
    final path = '$directory${Platform.pathSeparator}$name';
    final snapshot = takeSnapshot(_db.raw);
    final iterations = kdfIterations;
    final summary = await _run(() => writeBackupFile(path, password, snapshot, now: now, kdfIterations: iterations));
    return {'path': path, 'file_name': name, 'summary': summary.toJson()};
  }

  @override
  Future<Json> inspect(String path, String password) async {
    final iterations = kdfIterations;
    // Only the summary crosses back; the rows stay in the background isolate.
    return _run(() => readBackupFile(path, password, kdfIterations: iterations).summary.toJson());
  }

  @override
  Future<Json> restore(String path, String password) async {
    final iterations = kdfIterations;
    final contents = await _run(() => readBackupFile(path, password, kdfIterations: iterations));
    restoreInto(_db, contents);
    return contents.summary.toJson();
  }
}
