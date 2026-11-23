import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/app_state.dart';
import 'core/theme.dart';
import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(ApiClient())..bootstrap();
  runApp(ChangeNotifierProvider.value(value: state, child: const FinverseApp()));
}

class FinverseApp extends StatelessWidget {
  const FinverseApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return MaterialApp(
      title: 'Finverse',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: state.themeMode,
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
