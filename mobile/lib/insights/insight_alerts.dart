/// Phone notifications for insights (phone-only version).
///
/// Everything is made on the phone: no push server, no internet.
///  * Alerts (over budget, spending higher than usual, unusual or double
///    payments) are shown once each, when Finverse opens, comes back to the
///    front or goes to the background.
///  * Reminders (bills and EMIs due, policy renewals, the monthly summary and
///    a check-in after 3 days away) are scheduled ahead with Android's alarm
///    service, so they arrive even while Finverse is closed. They are worked
///    out again every time the app runs.
library;

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:material_ui/material_ui.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../services/services.dart';

class InsightAlerts extends ChangeNotifier with WidgetsBindingObserver {
  InsightAlerts(this.service, {required this.hideAmounts, this.onTap, this.storage = const FlutterSecureStorage()});

  final InsightsService service;

  /// Whether amounts are hidden in the app (then notifications hide them too).
  final bool Function() hideAmounts;

  /// The user tapped a notification while Finverse was running; [target]
  /// says where it points (bills, budgets, ...).
  final void Function(String? target)? onTap;

  /// Remembers that Android's permission prompt was shown.
  final FlutterSecureStorage storage;
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _busy = false;
  String? _launchTarget;

  /// Android allows Finverse to show notifications.
  bool permitted = false;

  /// The user's choices (see InsightsService.settings).
  Json settings = const {'enabled': true, 'kinds': {}};

  static const _askedKey = 'finverse_notifications_asked';
  static const _maxAlertsAtOnce = 3;
  static const _maxReminders = 40;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.isAndroid) return;
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
      } catch (_) {
        tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
      }
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_finverse')),
        onDidReceiveNotificationResponse: (response) => onTap?.call(response.payload),
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) _launchTarget = launch!.notificationResponse?.payload ?? '';
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
    // Give SMS and UPI capture a moment to bring in new payments first.
    Future.delayed(const Duration(seconds: 6), refresh);
  }

  /// Where a notification that opened the app points (once), else null.
  String? takeLaunchTarget() {
    final target = _launchTarget;
    _launchTarget = null;
    return target;
  }

  /// Asks Android for permission to show notifications, once ever (Android
  /// 13+ shows its own prompt; older versions allow them by default).
  Future<void> askOnce() async {
    if (!_ready) return;
    try {
      if (await storage.read(key: _askedKey) != null) return;
      await storage.write(key: _askedKey, value: '1');
    } catch (_) {
      return;
    }
    await requestPermission();
  }

  /// Shows Android's permission prompt, or its settings screen if the user
  /// already said no there.
  Future<void> requestPermission() async {
    final android = _android;
    if (android == null) return;
    final granted = await android.requestNotificationsPermission() ?? false;
    if (!granted) await android.openAppNotificationSettings();
    await refresh();
  }

  Future<void> updateSettings(Json changes) async {
    await service.updateSettings(changes);
    await refresh();
  }

  /// Sends new alerts and re-schedules reminders.
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      settings = await service.settings();
      if (!_ready) return;
      permitted = await _android?.areNotificationsEnabled() ?? false;
      final enabled = settings['enabled'] == true;
      final kinds = settings['kinds'] as Map? ?? const {};
      bool on(Object? kind) => permitted && enabled && kinds[kind] == true;
      final hidden = hideAmounts();

      // Alerts: each is sent at most once. Ones that can't be sent now (turned
      // off) are still marked, so switching on later doesn't send old news.
      final alerts = [for (final i in await service.list(hideAmounts: hidden)) if (i['notify'] == true) i];
      final fresh = (await service.markNotified([for (final i in alerts) i['key'] as String])).toSet();
      var shown = 0;
      for (final i in alerts) {
        if (!fresh.contains(i['key']) || !on(i['kind'])) continue;
        await _plugin.show(
          id: _idFor(i['key'] as String),
          title: i['title'] as String,
          body: i['body'] as String,
          notificationDetails: _details(_alerts, i['body'] as String),
          payload: i['target'] as String?,
        );
        if (++shown == _maxAlertsAtOnce) break;
      }

      // Reminders: worked out afresh each time (bills may have been paid or
      // added since), so drop the old schedule first.
      await _plugin.cancelAllPendingNotifications();
      var scheduled = 0;
      for (final r in await service.reminders(hideAmounts: hidden)) {
        if (!on(r['kind'])) continue;
        final at = tz.TZDateTime.from(DateTime.parse(r['at'] as String), tz.local);
        final channel = r['kind'] == 'bill' ? _reminders : _updates;
        await _plugin.zonedSchedule(
          id: _idFor(r['key'] as String),
          scheduledDate: at,
          title: r['title'] as String,
          body: r['body'] as String,
          notificationDetails: _details(channel, r['body'] as String),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: r['kind'] == 'bill' ? 'bills' : null,
        );
        if (++scheduled == _maxReminders) break;
      }
    } catch (e) {
      debugPrint('Could not update notifications: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static const _alerts = AndroidNotificationChannel(
    'finverse_alerts',
    'Alerts',
    description: 'Over budget, spending higher than usual, unusual or double payments',
    importance: Importance.high,
  );
  static const _reminders = AndroidNotificationChannel(
    'finverse_reminders',
    'Bills and renewals',
    description: 'Bills, EMIs and insurance renewals coming up',
    importance: Importance.high,
  );
  static const _updates = AndroidNotificationChannel(
    'finverse_updates',
    'Summaries and reminders',
    description: 'Monthly summary and a reminder when you have not opened Finverse for a while',
  );

  static NotificationDetails _details(AndroidNotificationChannel channel, String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: channel.importance == Importance.high ? Priority.high : Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(body),
          color: const Color(0xFF10B981),
          // Money details stay off the lock screen.
          visibility: NotificationVisibility.private,
        ),
      );

  /// A stable notification id for a key, so the same alert or reminder
  /// replaces itself instead of piling up (FNV-1a, 31 bits).
  static int _idFor(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future.delayed(const Duration(seconds: 4), refresh);
    } else if (state == AppLifecycleState.paused) {
      refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
