import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../services/errors.dart';

/// Optional app lock for the phone-only version (it has no password).
///
/// Uses the phone's own screen lock: fingerprint, face, PIN, pattern or
/// password. When on, the app is locked at launch and after it has been in
/// the background for [relockAfter].
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({LocalAuthentication? auth, this.storage = const FlutterSecureStorage()}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;
  final FlutterSecureStorage storage;

  static const _key = 'finverse_app_lock';
  static const relockAfter = Duration(seconds: 30);

  bool enabled = false;
  bool locked = false;
  bool _authenticating = false;
  DateTime? _backgroundedAt;

  Future<void> init() async {
    enabled = await storage.read(key: _key) == 'on';
    locked = enabled;
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!enabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null && DateTime.now().difference(since) >= relockAfter && !_authenticating) {
        locked = true;
        notifyListeners();
      }
    }
  }

  /// Shows the phone's unlock prompt. Returns true when unlocked.
  Future<bool> unlock() async {
    if (_authenticating) return false;
    final ok = await _authenticate('Unlock Finverse');
    if (ok) {
      locked = false;
      notifyListeners();
    }
    return ok;
  }

  /// Turns the lock on or off. Both need the phone's unlock, so someone
  /// holding an unlocked phone can't silently switch it off.
  /// Throws a user-readable message if the phone has no screen lock.
  Future<void> setEnabled(bool value) async {
    if (value && !await _auth.isDeviceSupported()) {
      throw const ServiceException('Set a screen lock (PIN, pattern or fingerprint) on your phone first.');
    }
    if (!await _authenticate(value ? 'Confirm to turn on App lock' : 'Confirm to turn off App lock')) return;
    enabled = value;
    await storage.write(key: _key, value: value ? 'on' : 'off');
    notifyListeners();
  }

  Future<bool> _authenticate(String reason) async {
    _authenticating = true;
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } on LocalAuthException {
      return false;
    } finally {
      _authenticating = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Covers the whole app with a lock screen while [AppLock.locked].
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.lock, required this.child});
  final AppLock lock;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  @override
  void initState() {
    super.initState();
    widget.lock.addListener(_changed);
    if (widget.lock.locked) WidgetsBinding.instance.addPostFrameCallback((_) => widget.lock.unlock());
  }

  @override
  void dispose() {
    widget.lock.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (widget.lock.locked) widget.lock.unlock();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.lock.locked) return widget.child;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Finverse is locked', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Use your fingerprint, face or phone PIN to continue.', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: widget.lock.unlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
