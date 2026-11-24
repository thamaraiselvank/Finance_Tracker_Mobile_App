import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/services.dart';
import 'backup_file.dart';
import 'drive_store.dart';

/// How often automatic backups to Google Drive run.
enum AutoBackup {
  off(null, 'Off'),
  daily(Duration(hours: 20), 'Daily'),
  weekly(Duration(days: 7), 'Weekly');

  const AutoBackup(this.every, this.label);

  /// Minimum time between automatic backups (daily allows some slack so a
  /// backup made at 9 pm doesn't wait until 9 pm the next day).
  final Duration? every;
  final String label;
}

/// Backup settings and actions for the phone-only version.
///
/// Settings live in the Android Keystore-backed secure storage of this phone
/// (not in the database, so a restore never changes them): the backup
/// password, whether Google Drive is connected and the automatic schedule.
///
/// Automatic backups run when the app is opened or brought back and one is
/// due; they never show Google's permission screen (if Drive needs the user,
/// the Backup screen says so).
class BackupManager extends ChangeNotifier with WidgetsBindingObserver {
  BackupManager(this._backup, {DriveBackupStore? drive, this.storage = const FlutterSecureStorage()}) : drive = drive ?? DriveBackupStore();

  final BackupService _backup;
  final DriveBackupStore drive;
  final FlutterSecureStorage storage;

  static const _kPassword = 'finverse_backup_password';
  static const _kAuto = 'finverse_backup_auto';
  static const _kDrive = 'finverse_backup_drive';
  static const _kDriveEmail = 'finverse_backup_drive_email';
  static const _kLastAt = 'finverse_backup_last_at';
  static const _kLastPlace = 'finverse_backup_last_place';
  static const _kLastDriveAt = 'finverse_backup_last_drive_at';

  bool hasPassword = false;
  AutoBackup auto = AutoBackup.off;
  bool driveConnected = false;
  String? driveEmail;
  DateTime? lastBackupAt;
  String? lastBackupPlace;
  DateTime? lastDriveBackupAt;

  /// Why the last automatic backup didn't run (shown on the Backup screen).
  String? autoProblem;

  /// A backup or restore is running.
  bool busy = false;

  Future<void> init() async {
    hasPassword = (await storage.read(key: _kPassword)) != null;
    auto = AutoBackup.values.asNameMap()[await storage.read(key: _kAuto)] ?? AutoBackup.off;
    driveConnected = await storage.read(key: _kDrive) == 'on';
    driveEmail = await storage.read(key: _kDriveEmail);
    lastBackupAt = DateTime.tryParse(await storage.read(key: _kLastAt) ?? '');
    lastBackupPlace = await storage.read(key: _kLastPlace);
    lastDriveBackupAt = DateTime.tryParse(await storage.read(key: _kLastDriveAt) ?? '');
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
    // Let the app finish starting before doing any backup work.
    Future.delayed(const Duration(seconds: 8), runAutoIfDue);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) runAutoIfDue();
  }

  // ---- password -----------------------------------------------------------

  /// Saves the backup password on this phone (Android Keystore). Used for
  /// every backup made here, including automatic ones.
  Future<void> setPassword(String password) async {
    checkBackupPassword(password);
    await storage.write(key: _kPassword, value: password);
    hasPassword = true;
    notifyListeners();
  }

  Future<bool> isCurrentPassword(String password) async => await storage.read(key: _kPassword) == password;

  Future<String> _password() async {
    final password = await storage.read(key: _kPassword);
    if (password == null) throw const BackupException('Set a backup password first.');
    return password;
  }

  // ---- making backups -----------------------------------------------------

  Future<Json> _makeFile() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}backups');
    if (dir.existsSync()) dir.deleteSync(recursive: true); // never leave old copies around
    dir.createSync(recursive: true);
    return _backup.create(await _password(), directory: dir.path);
  }

  Future<T> _busy<T>(Future<T> Function() work) async {
    if (busy) throw const BackupException('A backup is already running. Wait a moment.');
    busy = true;
    notifyListeners();
    try {
      return await work();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _recordBackup(String place, {bool drive = false}) async {
    final now = DateTime.now();
    lastBackupAt = now;
    lastBackupPlace = place;
    await storage.write(key: _kLastAt, value: now.toIso8601String());
    await storage.write(key: _kLastPlace, value: place);
    if (drive) {
      lastDriveBackupAt = now;
      autoProblem = null;
      await storage.write(key: _kLastDriveAt, value: now.toIso8601String());
    }
  }

  /// Makes a backup and lets the user choose where to save it (Downloads,
  /// Google Drive, a pen drive...). Returns false if they cancelled.
  Future<bool> saveToDevice() => _busy(() async {
    final made = await _makeFile();
    final path = made['path'] as String;
    try {
      final saved = await FilePicker.saveFile(
        fileName: made['file_name'] as String,
        bytes: await File(path).readAsBytes(),
        dialogTitle: 'Save Finverse backup',
      );
      if (saved == null) return false;
      await _recordBackup('file');
      return true;
    } finally {
      _delete(path);
    }
  });

  /// Makes a backup and opens Android's share sheet (WhatsApp to yourself,
  /// email, Drive...).
  Future<void> share() => _busy(() async {
    final made = await _makeFile();
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(made['path'] as String, mimeType: 'application/octet-stream')],
        subject: 'Finverse backup',
        text: 'Finverse backup (locked with my backup password).',
      ),
    );
    if (result.status != ShareResultStatus.dismissed) await _recordBackup('shared');
  });

  // ---- Google Drive -------------------------------------------------------

  Future<void> connectDrive() => _busy(() async {
    driveEmail = await drive.connect();
    driveConnected = true;
    autoProblem = null;
    await storage.write(key: _kDrive, value: 'on');
    if (driveEmail != null) await storage.write(key: _kDriveEmail, value: driveEmail);
  });

  Future<void> disconnectDrive() async {
    await drive.disconnect();
    driveConnected = false;
    driveEmail = null;
    auto = AutoBackup.off;
    await storage.delete(key: _kDrive);
    await storage.delete(key: _kDriveEmail);
    await storage.write(key: _kAuto, value: auto.name);
    notifyListeners();
  }

  /// Uploads a new backup to Drive and removes the oldest beyond the last
  /// [DriveBackupStore.keep].
  Future<void> backupToDrive() => _busy(() => _uploadToDrive(interactive: true));

  Future<void> _uploadToDrive({required bool interactive}) async {
    final made = await _makeFile();
    final path = made['path'] as String;
    try {
      await drive.upload(made['file_name'] as String, await File(path).readAsBytes(), interactive: interactive);
    } finally {
      _delete(path);
    }
    await _recordBackup('Google Drive', drive: true);
    try {
      await drive.prune();
    } catch (_) {
      // Old copies are tidied next time.
    }
  }

  Future<List<DriveBackup>> driveBackups() => drive.list(interactive: true);

  /// Downloads a Drive backup to a private temporary file for [inspect] / [restore].
  Future<String> downloadFromDrive(DriveBackup backup) => _busy(() async {
    final bytes = await drive.download(backup.id, interactive: true);
    return _privateCopy(bytes);
  });

  Future<void> setAuto(AutoBackup value) async {
    auto = value;
    await storage.write(key: _kAuto, value: value.name);
    notifyListeners();
    if (value != AutoBackup.off) runAutoIfDue();
  }

  /// Runs an automatic Drive backup if one is due. Never asks the user anything.
  Future<void> runAutoIfDue() async {
    final every = auto.every;
    if (every == null || !driveConnected || !hasPassword || busy) return;
    final last = lastDriveBackupAt;
    if (last != null && DateTime.now().difference(last) < every) return;
    try {
      await _busy(() => _uploadToDrive(interactive: false));
    } on DriveNotConnected {
      autoProblem = 'Automatic backup is paused: Google Drive needs to be connected again.';
    } on BackupException catch (e) {
      autoProblem = 'The last automatic backup did not finish: ${e.message}';
    } catch (e) {
      autoProblem = 'The last automatic backup did not finish.';
    }
    notifyListeners();
  }

  // ---- restoring ----------------------------------------------------------

  /// Copies a picked backup file to private storage (it may be upgraded there).
  Future<String> _privateCopy(Uint8List bytes) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}restore');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final path = '${dir.path}${Platform.pathSeparator}backup.$backupExtension';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Lets the user pick a backup file. Returns a private copy's path, or
  /// null if they cancelled.
  Future<String?> pickFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return null;
    final size = await file.length();
    if (size != null && size > 200 * 1024 * 1024) throw const BackupException('That file is too large to be a Finverse backup.');
    return _privateCopy(await file.readAsBytes());
  }

  /// What the backup holds (checks the password), without changing anything.
  Future<Json> inspect(String path, String password) => _busy(() => _backup.inspect(path, password));

  /// Replaces all data on this phone with the backup. Remembers [password]
  /// as this phone's backup password if none is set yet.
  Future<Json> restore(String path, String password) => _busy(() async {
    final summary = await _backup.restore(path, password);
    _delete(path);
    if (!hasPassword && password.length >= minBackupPasswordLength) {
      await storage.write(key: _kPassword, value: password);
      hasPassword = true;
    }
    return summary;
  });

  void discard(String path) => _delete(path);

  void _delete(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {
      // Already gone.
    }
  }
}
