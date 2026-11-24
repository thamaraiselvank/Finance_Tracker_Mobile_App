import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/theme.dart';
import '../insights/insight_alerts.dart';
import '../services/services.dart';
import '../widgets/common.dart';
import 'goals_screen.dart';
import 'insurance_screen.dart';
import 'money_screen.dart';
import 'schedules_screen.dart';

/// Opens the screen an insight (or a notification) points to.
Future<void> openInsightTarget(BuildContext context, String? target) {
  final Widget? screen = switch (target) {
    'budgets' => const MoneyScreen(initialTab: 1),
    'transactions' => const MoneyScreen(),
    'bills' => const SchedulesScreen(),
    'insurance' => const InsuranceScreen(),
    'goals' => const GoalsScreen(),
    _ => null,
  };
  return Navigator.push(context, MaterialPageRoute(builder: (_) => screen ?? const InsightsScreen()));
}

/// Masks amounts in an insight's text when the user has hidden amounts.
String _visible(BuildContext context, String text) {
  final state = context.watch<AppState>();
  if (!state.hideAmounts) return text;
  final symbol = state.money.symbol;
  return text.replaceAll(RegExp('${RegExp.escape(symbol)}[0-9][0-9,]*(\\.[0-9]+)?'), '$symbol ••••');
}

({IconData icon, Color color}) _look(BuildContext context, Json insight) {
  final icon = switch (insight['kind']) {
    'budget' => Icons.account_balance_wallet_outlined,
    'spending' => Icons.trending_up,
    'unusual' => Icons.gpp_maybe_outlined,
    'bill' => Icons.event_outlined,
    'goal' => Icons.flag_outlined,
    'recurring' => Icons.autorenew,
    'summary' => Icons.insights_outlined,
    _ => Icons.lightbulb_outline,
  };
  final color = switch (insight['severity']) {
    'alert' => AppColors.expense,
    'warning' => AppColors.warning,
    'good' => AppColors.income,
    _ => Theme.of(context).colorScheme.primary,
  };
  return (icon: icon, color: color);
}

/// One insight as a list row (Home screen card and the Insights screen).
class InsightTile extends StatelessWidget {
  const InsightTile({super.key, required this.insight, this.onReturn});
  final Json insight;
  final VoidCallback? onReturn;

  @override
  Widget build(BuildContext context) {
    final look = _look(context, insight);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: look.color.withValues(alpha: 0.14),
        foregroundColor: look.color,
        child: Icon(look.icon, size: 20),
      ),
      title: Text(_visible(context, insight['title'] as String), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(_visible(context, insight['body'] as String)),
      isThreeLine: (insight['body'] as String).length > 60,
      onTap: () async {
        await openInsightTarget(context, insight['target'] as String?);
        onReturn?.call();
      },
    );
  }
}

/// Home screen: the top few insights, with a link to all of them.
class InsightsCard extends StatelessWidget {
  const InsightsCard({super.key, required this.insights, required this.onChanged});
  final List<Json> insights;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        'For you',
        trailing: TextButton(
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const InsightsScreen()));
            onChanged();
          },
          child: Text(insights.length > 3 ? 'See all ${insights.length}' : 'See all'),
        ),
      ),
      Card(
        child: Column(children: [
          for (var i = 0; i < insights.length && i < 3; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 72),
            InsightTile(insight: insights[i], onReturn: onChanged),
          ],
        ]),
      ),
    ]);
  }
}

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final _view = GlobalKey<AsyncViewState<List<Json>>>();

  @override
  Widget build(BuildContext context) {
    final service = context.services.insights!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Insights'),
        actions: [
          if (context.watch<InsightAlerts?>() != null)
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationSettingsScreen())),
            ),
        ],
      ),
      body: AsyncView<List<Json>>(
        key: _view,
        load: () => service.list(),
        builder: (context, insights, reload) {
          if (insights.isEmpty) {
            return const EmptyState(
              icon: Icons.insights_outlined,
              title: 'All clear',
              message: 'Budget alerts, unusual payments, bills due and your monthly summary will show up here.',
            );
          }
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  'Worked out on this phone from your own data. Swipe one away to hide it.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              for (final insight in insights)
                Dismissible(
                  key: ValueKey(insight['key']),
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: const Icon(Icons.visibility_off_outlined),
                  ),
                  onDismissed: (_) async {
                    await service.dismiss(insight['key'] as String);
                    insights.remove(insight);
                    if (insights.isEmpty) reload();
                  },
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: InsightTile(insight: insight, onReturn: reload)),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

/// Which notifications Finverse sends.
class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final alerts = context.watch<InsightAlerts>();
    final theme = Theme.of(context);
    final enabled = alerts.settings['enabled'] == true;
    final kinds = alerts.settings['kinds'] as Map? ?? const {};
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        if (!alerts.permitted)
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: Icon(Icons.notifications_off_outlined, color: theme.colorScheme.onErrorContainer),
              title: Text('Notifications are off for Finverse', style: TextStyle(color: theme.colorScheme.onErrorContainer, fontWeight: FontWeight.w700)),
              subtitle: Text('Allow them in Android settings to get alerts and reminders.', style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              trailing: FilledButton(onPressed: alerts.requestPermission, child: const Text('Allow')),
            ),
          ),
        Card(
          child: SwitchListTile(
            title: const Text('Send notifications', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Alerts and reminders on this phone'),
            value: enabled,
            onChanged: (v) => alerts.updateSettings({'enabled': v}),
          ),
        ),
        const SectionHeader('What to send'),
        Card(
          child: Column(children: [
            for (final e in notificationKinds.entries)
              SwitchListTile(
                title: Text(e.value),
                subtitle: Text(_kindHelp[e.key] ?? ''),
                value: enabled && kinds[e.key] == true,
                onChanged: enabled ? (v) => alerts.updateSettings({'kinds': {e.key: v}}) : null,
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            'Everything is worked out on this phone. Nothing is sent to a server. '
            'Amounts are not shown on the lock screen, and are hidden in notifications too while you hide amounts in the app.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ]),
    );
  }

  static const _kindHelp = {
    'budget': 'When a category reaches 80% or goes over its budget',
    'spending': 'When this month is well above your usual',
    'unusual': 'A much bigger payment than usual, or one added twice',
    'bill': 'The day before a bill or EMI is due, and a week before a policy renews',
    'summary': 'On the 1st: what came in, what went out, what you saved',
    'checkin': 'If you have not opened Finverse for 3 days, to pick up new payments',
  };
}
