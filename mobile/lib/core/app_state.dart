import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'format.dart';

enum AuthStatus { loading, signedOut, signedIn }

/// Holds the signed-in user, session state and app-wide preferences.
class AppState extends ChangeNotifier {
  AppState(this.api) {
    api.onSessionExpired = _handleSessionExpired;
  }

  final ApiClient api;
  final _storage = const FlutterSecureStorage();

  static const _userKey = 'finverse_user';
  static const _themeKey = 'finverse_theme';

  AuthStatus status = AuthStatus.loading;
  Map<String, dynamic>? user;
  ThemeMode themeMode = ThemeMode.system;
  bool hideAmounts = false;
  String? sessionMessage;

  Money get money => Money(user?['currency'] as String?);

  bool get needsOnboarding {
    if (user == null) return false;
    final onboarded = user!['is_onboarded'] == true;
    return !onboarded && toDouble(user!['monthly_income']) <= 0;
  }

  String get displayName {
    final name = (user?['full_name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    return (user?['username'] as String?) ?? 'there';
  }

  Future<void> bootstrap() async {
    final savedTheme = await _storage.read(key: _themeKey);
    themeMode = switch (savedTheme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    await api.loadTokens();
    final cachedUser = await _storage.read(key: _userKey);
    if (!api.hasSession || cachedUser == null) {
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }

    // Show the cached profile immediately, then refresh it from the server.
    user = Map<String, dynamic>.from(jsonDecode(cachedUser));
    status = AuthStatus.signedIn;
    notifyListeners();
    try {
      await refreshUser();
    } on ApiException catch (e) {
      if (e.isUnauthorized) await signOut();
      // Other errors (offline etc.): keep the cached profile.
    }
  }

  Future<void> refreshUser() async {
    final data = await api.get('/auth/me');
    await _setUser(Map<String, dynamic>.from(data));
  }

  Future<void> login(String usernameOrEmail, String password) async {
    final data = await api.post('/auth/login', body: {
      'username_or_email': usernameOrEmail.trim(),
      'password': password,
    });
    await _completeSignIn(data);
  }

  Future<void> register(Map<String, dynamic> payload) async {
    final data = await api.post('/auth/register', body: payload);
    await _completeSignIn(data);
  }

  Future<void> _completeSignIn(dynamic data) async {
    await api.saveTokens(access: data['access_token'], refresh: data['refresh_token']);
    sessionMessage = null;
    status = AuthStatus.signedIn;
    await _setUser(Map<String, dynamic>.from(data['user']));
  }

  Future<void> updateProfile(Map<String, dynamic> changes) async {
    final data = await api.put('/auth/me', body: changes);
    await _setUser(Map<String, dynamic>.from(data));
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await api.post('/auth/change-password', body: {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  Future<void> signOut() async {
    await api.clearTokens();
    await _storage.delete(key: _userKey);
    user = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  void _handleSessionExpired() {
    sessionMessage = 'Your session has expired. Please sign in again.';
    signOut();
  }

  Future<void> _setUser(Map<String, dynamic> value) async {
    user = value;
    await _storage.write(key: _userKey, value: jsonEncode(value));
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _storage.write(
      key: _themeKey,
      value: switch (mode) { ThemeMode.light => 'light', ThemeMode.dark => 'dark', _ => 'system' },
    );
  }

  void toggleHideAmounts() {
    hideAmounts = !hideAmounts;
    notifyListeners();
  }
}
