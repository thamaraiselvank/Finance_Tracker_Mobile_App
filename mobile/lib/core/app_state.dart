import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/services.dart';
import 'api_client.dart';
import 'format.dart';

enum AuthStatus { loading, signedOut, signedIn }

/// Holds the signed-in user, session state and app-wide preferences.
class AppState extends ChangeNotifier {
  AppState(this.auth) {
    auth.onSessionExpired = _handleSessionExpired;
  }

  final AuthService auth;
  final _storage = const FlutterSecureStorage();

  static const _userKey = 'finverse_user';
  static const _themeKey = 'finverse_theme';

  AuthStatus status = AuthStatus.loading;
  Map<String, dynamic>? user;
  ThemeMode themeMode = ThemeMode.system;
  bool hideAmounts = false;
  String? sessionMessage;

  Money get money => Money(user?['currency'] as String?);

  /// Phone-only version: no sign-in, data in the on-phone database.
  bool get isLocal => !auth.hasAccounts;

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

    final hasSession = await auth.restoreSession();
    if (isLocal) {
      // The profile lives in the on-phone database: read it directly.
      await refreshUser();
      status = AuthStatus.signedIn;
      notifyListeners();
      return;
    }
    final cachedUser = await _storage.read(key: _userKey);
    if (!hasSession || cachedUser == null) {
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
    await _setUser(await auth.currentUser());
  }

  Future<void> login(String usernameOrEmail, String password) async {
    await _completeSignIn(await auth.login(usernameOrEmail, password));
  }

  Future<void> register(Map<String, dynamic> payload) async {
    await _completeSignIn(await auth.register(payload));
  }

  Future<void> _completeSignIn(Map<String, dynamic> signedInUser) async {
    sessionMessage = null;
    status = AuthStatus.signedIn;
    await _setUser(signedInUser);
  }

  Future<void> updateProfile(Map<String, dynamic> changes) async {
    await _setUser(await auth.updateProfile(changes));
  }

  Future<void> changePassword(String oldPassword, String newPassword) =>
      auth.changePassword(oldPassword, newPassword);

  Future<void> signOut() async {
    await auth.signOut();
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
    // The cloud profile is cached for instant start-up; the local one is
    // already on the phone (in the encrypted database), so no copy is kept.
    if (!isLocal) await _storage.write(key: _userKey, value: jsonEncode(value));
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
