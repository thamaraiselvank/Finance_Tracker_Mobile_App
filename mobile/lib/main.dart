import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'backup/backup_manager.dart';
import 'capture/app_capture.dart';
import 'capture/sms_sync.dart';
import 'config.dart';
import 'core/api_client.dart';
import 'core/app_lock.dart';
import 'core/app_state.dart';
import 'core/pro.dart';
import 'core/theme.dart';
import 'insights/insight_alerts.dart';
import 'local/local_db.dart';
import 'local/local_services.dart';
import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/insights_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/remote/remote_services.dart';
import 'services/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The one place that decides where data comes from. Screens only see
  // `Services`, so they work the same with either implementation.
  final Services services;
  AppLock? lock;
  if (AppConfig.isLocal) {
    try {
      services = localServices(await LocalDb.openEncrypted(), taxRules: await loadTaxRules());
    } catch (e) {
      runApp(_StartupError(e.toString()));
      return;
    }
    lock = AppLock();
    await lock.init();
  } else {
    services = remoteServices(ApiClient());
  }

  final state = AppState(services.auth)..bootstrap();
  final pro = ProStatus();
  await pro.init();

  // Phone-only version: automatic capture into the review inbox from bank
  // SMS, UPI app notifications and "Share to Finverse".
  final capture = services.capture;
  SmsSync? sms;
  NotificationSync? notifications;
  if (capture != null) {
    sms = SmsSync(capture)..init();
    notifications = NotificationSync(capture, onAdded: sms.refreshCount)..init();
    ShareCapture(capture, navigatorKey, onAdded: sms.refreshCount).init();
  }

  // Phone-only version: encrypted backups (file / Google Drive).
  final backupService = services.backup;
  final backup = backupService == null ? null : (BackupManager(backupService)..autoAllowed = (() => pro.isPro)..init());

  // Phone-only version: alerts and reminders as phone notifications.
  final insightsService = services.insights;
  final alerts = insightsService == null
      ? null
      : (InsightAlerts(
          insightsService,
          hideAmounts: () => state.hideAmounts,
          onTap: (target) {
            final context = navigatorKey.currentContext;
            if (context != null && state.status == AuthStatus.signedIn && !state.needsOnboarding) openInsightTarget(context, target);
          },
        )..init());
  runApp(MultiProvider(
    providers: [
      Provider<Services>.value(value: services),
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<ProStatus>.value(value: pro),
      if (lock != null) ChangeNotifierProvider<AppLock>.value(value: lock),
      if (sms != null) ChangeNotifierProvider<SmsSync>.value(value: sms),
      if (notifications != null) ChangeNotifierProvider<NotificationSync>.value(value: notifications),
      if (backup != null) ChangeNotifierProvider<BackupManager>.value(value: backup),
      if (alerts != null) ChangeNotifierProvider<InsightAlerts>.value(value: alerts),
    ],
    child: FinverseApp(lock: lock),
  ));
}

/// Lets code outside the widget tree (e.g. a share from another app) open screens.
final navigatorKey = GlobalKey<NavigatorState>();

class FinverseApp extends StatelessWidget {
  const FinverseApp({super.key, this.lock});

  /// Only in the phone-only version.
  final AppLock? lock;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Finverse',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: state.themeMode,
      builder: lock == null ? null : (context, child) => AppLockGate(lock: lock!, child: child!),
      home: switch (state.status) {
        AuthStatus.loading => const _Splash(),
        AuthStatus.signedOut => const AuthScreen(),
        AuthStatus.signedIn => state.needsOnboarding ? const OnboardingScreen() : const HomeShell(),
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FinverseLogo(size: 64),
          SizedBox(height: 20),
          CircularProgressIndicator(),
        ]),
      ),
    );
  }
}

/// Shown if the on-phone database can't be opened (should never happen; it
/// would mean the stored encryption key and the database file don't match).
class _StartupError extends StatelessWidget {
  const _StartupError(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              const Text('Finverse could not open your data on this phone.', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ]),
          ),
        ),
      ),
    );
  }
}

class FinverseLogo extends StatelessWidget {
  const FinverseLogo({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF0EA5E9)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Text('F', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.5)),
    );
  }
}
