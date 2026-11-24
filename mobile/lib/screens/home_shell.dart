import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../insights/insight_alerts.dart';
import 'ai_advisor_screen.dart';
import 'dashboard_screen.dart';
import 'goals_screen.dart';
import 'insights_screen.dart';
import 'money_screen.dart';
import 'more_screen.dart';
import 'wealth_screen.dart';

/// Main app shell with bottom navigation. Each tab keeps its state.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final alerts = context.read<InsightAlerts?>();
      if (alerts == null) return;
      // Opened by tapping a notification: go where it points.
      final target = alerts.takeLaunchTarget();
      if (target != null) openInsightTarget(context, target);
      alerts.askOnce();
    });
  }

  void _goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(onNavigate: _goTo),
      const MoneyScreen(),
      const WealthScreen(),
      const GoalsScreen(),
      const MoreScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              tooltip: 'AI advisor',
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiAdvisorScreen())),
              child: const Icon(Icons.auto_awesome),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Money'),
          NavigationDestination(icon: Icon(Icons.trending_up_outlined), selectedIcon: Icon(Icons.trending_up), label: 'Wealth'),
          NavigationDestination(icon: Icon(Icons.flag_outlined), selectedIcon: Icon(Icons.flag), label: 'Goals'),
          NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
        ],
      ),
    );
  }
}

/// Eye icon that hides/shows all money amounts in the app.
class HideAmountsButton extends StatelessWidget {
  const HideAmountsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final hidden = context.select<AppState, bool>((s) => s.hideAmounts);
    return IconButton(
      tooltip: hidden ? 'Show amounts' : 'Hide amounts',
      icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
      onPressed: () => context.read<AppState>().toggleHideAmounts(),
    );
  }
}
