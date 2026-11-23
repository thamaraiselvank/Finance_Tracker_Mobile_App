import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Error thrown for any failed API call, with a user-readable message.
class ApiException implements Exception {
  final int? statusCode;
  final String message;
  final dynamic detail;

  ApiException(this.message, {this.statusCode, this.detail});

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// Thin wrapper around `http` that:
///  * attaches the bearer access token,
///  * refreshes the access token once on a 401 using the refresh token,
///  * converts backend error payloads into [ApiException]s.
class ApiClient {
  ApiClient({http.Client? client, FlutterSecureStorage? storage})
      : _client = client ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  final http.Client _client;
  final FlutterSecureStorage _storage;

  static const _accessKey = 'finverse_access_token';
  static const _refreshKey = 'finverse_refresh_token';

  String? _accessToken;
  String? _refreshToken;
  Future<bool>? _refreshing;

  /// Called when the session can no longer be refreshed (user must log in again).
  void Function()? onSessionExpired;

  bool get hasSession => _accessToken != null;

  Future<void> loadTokens() async {
    _accessToken = await _storage.read(key: _accessKey);
    _refreshToken = await _storage.read(key: _refreshKey);
  }

  Future<void> saveTokens({required String access, String? refresh}) async {
    _accessToken = access;
    await _storage.write(key: _accessKey, value: access);
    if (refresh != null) {
      _refreshToken = refresh;
      await _storage.write(key: _refreshKey, value: refresh);
    }
  }

  Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = AppConfig.apiBaseUrl.endsWith('/')
        ? AppConfig.apiBaseUrl.substring(0, AppConfig.apiBaseUrl.length - 1)
        : AppConfig.apiBaseUrl;
    final cleanQuery = <String, String>{};
    query?.forEach((key, value) {
      if (value != null && value.toString().isNotEmpty) {
        cleanQuery[key] = value.toString();
      }
    });
    final uri = Uri.parse('$base$path');
    return cleanQuery.isEmpty ? uri : uri.replace(queryParameters: cleanQuery);
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body, Map<String, dynamic>? query}) =>
      _send('POST', path, body: body, query: query);

  Future<dynamic> put(String path, {Object? body}) => _send('PUT', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Uploads a file as multipart/form-data (used by statement import).
  Future<dynamic> postFile(
    String path, {
    required List<int> bytes,
    required String filename,
    Map<String, String> fields = const {},
    bool retried = false,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path));
    request.headers['Accept'] = 'application/json';
    if (_accessToken != null) request.headers['Authorization'] = 'Bearer $_accessToken';
    request.fields.addAll(fields);
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    http.Response response;
    try {
      // Parsing large PDFs (OCR) can take a while on the server.
      final streamed = await _client.send(request).timeout(const Duration(minutes: 3));
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiException('Reading the file took too long. Try a smaller file or a CSV/Excel export.');
    } on SocketException {
      throw ApiException('No internet connection. Check your network and try again.');
    } on http.ClientException {
      throw ApiException('Could not reach the server. Please try again.');
    }

    if (response.statusCode == 401 && !retried && _refreshToken != null && await _refreshAccessToken()) {
      return postFile(path, bytes: bytes, filename: filename, fields: fields, retried: true);
    }
    final decoded = _decode(response);
    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
    throw ApiException(_errorMessage(decoded, response.statusCode), statusCode: response.statusCode, detail: decoded is Map ? decoded['detail'] : null);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool retried = false,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'application/json';
    if (_accessToken != null) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(AppConfig.requestTimeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiException('The server took too long to respond. Please try again.');
    } on SocketException {
      throw ApiException('No internet connection. Check your network and try again.');
    } on http.ClientException {
      throw ApiException('Could not reach the server. Please try again.');
    }

    final isAuthCall = path.startsWith('/auth/login') ||
        path.startsWith('/auth/register') ||
        path.startsWith('/auth/refresh');

    if (response.statusCode == 401 && !retried && !isAuthCall && _refreshToken != null) {
      final refreshed = await _refreshAccessToken();
      if (refreshed) {
        return _send(method, path, body: body, query: query, retried: true);
      }
      await clearTokens();
      onSessionExpired?.call();
      throw ApiException('Your session has expired. Please sign in again.', statusCode: 401);
    }

    final decoded = _decode(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    throw ApiException(
      _errorMessage(decoded, response.statusCode),
      statusCode: response.statusCode,
      detail: decoded is Map ? decoded['detail'] : null,
    );
  }

  dynamic _decode(http.Response response) {
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return response.body;
    }
  }

  String _errorMessage(dynamic decoded, int status) {
    if (decoded is Map) {
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is Map && detail['message'] is String) return detail['message'];
      if (detail is List && detail.isNotEmpty) {
        // FastAPI validation errors: [{loc: [...], msg: "..."}]
        final first = detail.first;
        if (first is Map && first['msg'] is String) {
          final loc = first['loc'];
          final field = loc is List && loc.isNotEmpty ? loc.last.toString() : null;
          final msg = first['msg'].toString().replaceFirst('Value error, ', '');
          return field != null && field != 'body' ? '${_prettyField(field)}: $msg' : msg;
        }
      }
    }
    if (status >= 500) return 'The server ran into a problem. Please try again shortly.';
    if (status == 404) return 'The requested item was not found.';
    if (status == 429) return 'Too many requests. Please wait a moment and try again.';
    return 'Request failed ($status).';
  }

  String _prettyField(String field) {
    final words = field.replaceAll('_', ' ');
    return words.isEmpty ? field : words[0].toUpperCase() + words.substring(1);
  }

  Future<bool> _refreshAccessToken() {
    // Share a single in-flight refresh between concurrent requests.
    return _refreshing ??= () async {
      try {
        final response = await _client
            .post(
              _uri('/auth/refresh'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': _refreshToken}),
            )
            .timeout(AppConfig.requestTimeout);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final token = data is Map ? data['access_token'] as String? : null;
          if (token != null) {
            await saveTokens(access: token);
            return true;
          }
        }
        return false;
      } catch (_) {
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }
}
