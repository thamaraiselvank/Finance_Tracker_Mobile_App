import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/services.dart';

/// Reads SMS from the phone's inbox through the native "finverse/sms"
/// channel (android/.../SmsReader.kt). Only letter sender IDs (banks, apps)
/// are returned; messages from people never reach Dart.
class SmsInbox {
  const SmsInbox();
  static const _channel = MethodChannel('finverse/sms');

  bool get supported => Platform.isAndroid;

  Future<List<CapturedMessage>> read({required DateTime since, int limit = 5000}) async {
    final rows = await _channel.invokeListMethod<Map>('readInbox', {'sinceMillis': since.millisecondsSinceEpoch, 'limit': limit}) ?? [];
    return [
      for (final r in rows)
        CapturedMessage(
          source: 'SMS',
          sender: r['address'] as String,
          body: r['body'] as String,
          receivedAt: DateTime.fromMillisecondsSinceEpoch((r['date'] as num).toInt()),
        ),
    ];
  }
}

/// Keeps the review inbox fed from bank SMS.
///
/// No background service: new SMS are read when the app starts and whenever
/// it comes back to the foreground. The first scan looks back [firstScanDays].
class SmsSync extends ChangeNotifier with WidgetsBindingObserver {
  SmsSync(this.capture, {this.inbox = const SmsInbox()});

  final CaptureService capture;
  final SmsInbox inbox;

  static const firstScanDays = 180;
  static const _minGap = Duration(minutes: 1);

  bool get supported => inbox.supported;
  bool granted = false;
  bool permanentlyDenied = false;
  bool scanning = false;
  int pendingCount = 0;
  DateTime? lastScan;

  /// Result of the latest scan: read / added / duplicates / skipped.
  Map<String, dynamic>? lastResult;
  String? error;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    lastScan = await capture.lastSmsScan();
    await refreshCount();
    if (!supported) return;
    final status = await Permission.sms.status;
    granted = status.isGranted;
    permanentlyDenied = status.isPermanentlyDenied;
    notifyListeners();
    if (granted) await scan();
  }

  /// Asks for SMS access and, if given, reads past messages.
  Future<bool> enable() async {
    if (!supported) return false;
    final status = await Permission.sms.request();
    granted = status.isGranted;
    permanentlyDenied = status.isPermanentlyDenied;
    notifyListeners();
    if (granted) await scan(force: true);
    return granted;
  }

  Future<void> openSettings() => openAppSettings();

  /// Reads SMS received since the last scan (or the last [firstScanDays]).
  Future<void> scan({bool force = false}) async {
    if (!supported || !granted || scanning) return;
    final now = DateTime.now();
    if (!force && lastScan != null && now.difference(lastScan!) < _minGap) return;
    scanning = true;
    error = null;
    notifyListeners();
    try {
      final since = lastScan ?? now.subtract(const Duration(days: firstScanDays));
      final messages = await inbox.read(since: since);
      lastResult = await capture.ingest(messages);
      await capture.setLastSmsScan(now);
      lastScan = now;
      await refreshCount();
    } on PlatformException catch (e) {
      error = e.code == 'NO_PERMISSION' ? 'SMS access was turned off.' : 'Could not read SMS (${e.message ?? e.code}).';
      if (e.code == 'NO_PERMISSION') granted = false;
    } catch (e) {
      error = e.toString();
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> refreshCount() async {
    pendingCount = await capture.pendingCount();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !supported) return;
    // The user may have changed the permission in Settings meanwhile.
    Permission.sms.status.then((status) {
      final was = granted;
      granted = status.isGranted;
      permanentlyDenied = status.isPermanentlyDenied;
      if (granted != was) notifyListeners();
      if (granted) scan();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
