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
/// it comes back to the foreground. How far back the first read goes is the
/// user's choice ([historyChoices]: none, 15 days … 6 months); after that
/// only new messages are read. Older ones can be read later ([readHistory]).
class SmsSync extends ChangeNotifier with WidgetsBindingObserver {
  SmsSync(this.capture, {this.inbox = const SmsInbox()});

  final CaptureService capture;
  final SmsInbox inbox;

  /// Days of past SMS the user can choose to read (0 = only new messages).
  static const historyChoices = {0: 'Only new messages', 15: 'Last 15 days', 30: 'Last 1 month', 90: 'Last 3 months', 180: 'Last 6 months'};
  static const defaultHistoryDays = 30;
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

  /// SMS access is on but the user hasn't said how far back to read yet.
  bool get needsHistoryChoice => granted && lastScan == null;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    lastScan = await capture.lastSmsScan();
    await refreshCount();
    if (!supported) return;
    final status = await Permission.sms.status;
    granted = status.isGranted;
    permanentlyDenied = status.isPermanentlyDenied;
    notifyListeners();
    if (granted && !needsHistoryChoice) await scan();
  }

  /// Asks for SMS access. Reading starts after [startReading].
  Future<bool> enable() async {
    if (!supported) return false;
    final status = await Permission.sms.request();
    granted = status.isGranted;
    permanentlyDenied = status.isPermanentlyDenied;
    notifyListeners();
    if (granted && !needsHistoryChoice) await scan(force: true);
    return granted;
  }

  /// The user's choice: read the last [days] of SMS now (0 = none), then
  /// keep reading new ones.
  Future<void> startReading(int days) async {
    if (!supported || !granted) return;
    if (days <= 0) {
      final now = DateTime.now();
      await capture.setLastSmsScan(now);
      lastScan = now;
      lastResult = null;
      notifyListeners();
      return;
    }
    await _read(since: DateTime.now().subtract(Duration(days: days)));
  }

  /// Reads older SMS again (already captured ones are recognised and skipped).
  Future<void> readHistory(int days) => _read(since: DateTime.now().subtract(Duration(days: days)));

  Future<void> openSettings() => openAppSettings();

  /// Reads SMS received since the last scan.
  Future<void> scan({bool force = false}) async {
    if (!supported || !granted || scanning || lastScan == null) return;
    final now = DateTime.now();
    if (!force && now.difference(lastScan!) < _minGap) return;
    await _read(since: lastScan!);
  }

  Future<void> _read({required DateTime since}) async {
    if (!supported || !granted || scanning) return;
    final now = DateTime.now();
    scanning = true;
    error = null;
    notifyListeners();
    try {
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
