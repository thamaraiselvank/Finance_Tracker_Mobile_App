/// Backups in the user's own Google Drive.
///
/// Files go to Drive's hidden *app data* folder: only Finverse can see them
/// (they don't show up in the Drive app and Finverse can't see anything
/// else in the Drive). Only already-encrypted backup files are uploaded.
///
/// Access uses Google's on-phone authorization (no Finverse server and no
/// Google sign-in screen inside the app). It needs the app to be registered
/// once in Google Cloud: an Android OAuth client for the package name and
/// signing certificate, with the Drive API turned on.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'backup_file.dart';

/// One backup file in Drive.
class DriveBackup {
  const DriveBackup({required this.id, required this.name, required this.size, required this.createdAt});
  final String id;
  final String name;
  final int size;
  final DateTime createdAt;
}

class DriveBackupStore {
  DriveBackupStore({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  static const scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';

  /// How many backups to keep in Drive; older ones are deleted.
  static const keep = 5;

  Future<void>? _init;
  Future<void> _ready() => _init ??= GoogleSignIn.instance.initialize();

  /// Asks the user to allow Finverse to keep backups in their Drive (shows
  /// Google's account picker and consent). Returns the account's email when
  /// Drive reports it.
  Future<String?> connect() async {
    await _token(interactive: true);
    try {
      final about = await _json('GET', '$_api/about?fields=user(emailAddress)');
      return (about['user'] as Map?)?['emailAddress'] as String?;
    } on BackupException {
      return null;
    }
  }

  /// Forgets the permission on this phone.
  Future<void> disconnect() async {
    try {
      await _ready();
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      // Nothing to undo.
    }
  }

  /// True when Drive can be used without asking the user (for automatic backups).
  Future<bool> canUseSilently() async {
    try {
      await _token(interactive: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<DriveBackup> upload(String name, Uint8List bytes, {bool interactive = false}) async {
    const boundary = 'finverse-backup-boundary';
    final metadata = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
    });
    final body = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'))
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final file = await _json(
      'POST',
      '$_upload/files?uploadType=multipart&fields=id,name,size,createdTime',
      body: body.takeBytes(),
      contentType: 'multipart/related; boundary=$boundary',
      interactive: interactive,
    );
    return _file(file);
  }

  /// Finverse backups in Drive, newest first.
  Future<List<DriveBackup>> list({bool interactive = false}) async {
    final query = Uri.encodeQueryComponent("name contains '.$backupExtension' and trashed = false");
    final result = await _json(
      'GET',
      '$_api/files?spaces=appDataFolder&q=$query&orderBy=createdTime%20desc&pageSize=100&fields=files(id,name,size,createdTime)',
      interactive: interactive,
    );
    return [for (final f in (result['files'] as List? ?? const [])) _file(f as Map<String, dynamic>)];
  }

  Future<Uint8List> download(String id, {bool interactive = false}) async {
    final response = await _send('GET', '$_api/files/$id?alt=media', interactive: interactive);
    return response.bodyBytes;
  }

  Future<void> delete(String id) async => _send('DELETE', '$_api/files/$id');

  /// Deletes all but the newest [keep] backups. Returns how many were deleted.
  Future<int> prune() async {
    final all = await list();
    var deleted = 0;
    for (final old in all.skip(keep)) {
      await delete(old.id);
      deleted++;
    }
    return deleted;
  }

  // -------------------------------------------------------------------------

  Future<String> _token({required bool interactive}) async {
    await _ready();
    final client = GoogleSignIn.instance.authorizationClient;
    try {
      final auth = await client.authorizationForScopes(const [scope]) ?? (interactive ? await client.authorizeScopes(const [scope]) : null);
      if (auth == null) throw const DriveNotConnected();
      return auth.accessToken;
    } on GoogleSignInException catch (e) {
      throw _signInError(e);
    }
  }

  Future<Map<String, dynamic>> _json(String method, String url, {List<int>? body, String? contentType, bool interactive = false}) async {
    final response = await _send(method, url, body: body, contentType: contentType, interactive: interactive);
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<http.Response> _send(String method, String url, {List<int>? body, String? contentType, bool interactive = false}) async {
    for (var attempt = 0; ; attempt++) {
      final token = await _token(interactive: interactive);
      final request = http.Request(method, Uri.parse(url))..headers['Authorization'] = 'Bearer $token';
      if (contentType != null) request.headers['Content-Type'] = contentType;
      if (body != null) request.bodyBytes = body;
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request).timeout(const Duration(minutes: 2)));
      } on SocketException {
        throw const BackupException('No internet connection. Connect and try again.');
      } on http.ClientException {
        throw const BackupException('No internet connection. Connect and try again.');
      }
      if (response.statusCode == 401 && attempt == 0) {
        // Expired or revoked token: drop it and ask Google for a fresh one.
        await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(accessToken: token);
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return response;
      if (response.statusCode == 401) throw const DriveNotConnected();
      if (response.statusCode == 403 && response.body.contains('storageQuotaExceeded')) {
        throw const BackupException('Your Google Drive is full. Free up space and try again.');
      }
      if (response.statusCode == 404) throw const BackupException('That backup is no longer in Google Drive.');
      throw BackupException('Google Drive did not accept the request (error ${response.statusCode}). Try again later.');
    }
  }

  static DriveBackup _file(Map<String, dynamic> f) => DriveBackup(
    id: f['id'] as String,
    name: f['name'] as String? ?? 'backup',
    size: int.tryParse('${f['size']}') ?? 0,
    createdAt: DateTime.tryParse('${f['createdTime']}')?.toLocal() ?? DateTime.now(),
  );

  static BackupException _signInError(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
      case GoogleSignInExceptionCode.interrupted:
        return const DriveCancelled();
      case GoogleSignInExceptionCode.uiUnavailable:
        return const BackupException('Open Finverse and try again.');
      default:
        final text = '${e.description} ${e.details}';
        if (text.contains('DEVELOPER_ERROR') ||
            text.contains(' 10:') ||
            text.contains('10: ') ||
            e.code == GoogleSignInExceptionCode.clientConfigurationError ||
            e.code == GoogleSignInExceptionCode.providerConfigurationError) {
          return const BackupException(
            'Google Drive is not set up for this copy of Finverse yet. '
            'Use "Save backup file" instead; you can pick Google Drive in the save screen.',
          );
        }
        if (text.contains('NETWORK') || text.contains(' 7:')) return const BackupException('No internet connection. Connect and try again.');
        return BackupException('Google Drive could not be connected (${e.description ?? e.code.name}).');
    }
  }
}

/// Drive permission is missing or was removed; the user must connect again.
class DriveNotConnected extends BackupException {
  const DriveNotConnected() : super('Google Drive needs to be connected again.');
}

/// The user closed Google's permission screen.
class DriveCancelled extends BackupException {
  const DriveCancelled() : super('Google Drive was not connected.');
}
