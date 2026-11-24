import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/app_state.dart';
import '../insights/insight_alerts.dart';
import '../widgets/common.dart';
import 'ai_advisor_screen.dart';
import 'assessment_screen.dart';
import 'backup_screen.dart';
import 'calculators_screen.dart';
import 'capture_rules_screen.dart';
import 'debts_screen.dart';
import 'essentials_screen.dart';
import 'export_screen.dart';
import 'import_screen.dart';
import 'insights_screen.dart';
import 'insurance_screen.dart';
import 'learn_screen.dart';
import 'profile_screen.dart';
import 'review_inbox_screen.dart';
import 'schedules_screen.dart';
import 'tax_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  void _push(BuildContext context, Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  Widget _item(BuildContext context, IconData icon, String title, String subtitle, Widget page) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _push(context, page),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(state.displayName.isNotEmpty ? state.displayName[0].toUpperCase() : '?')),
            title: Text(state.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(state.isLocal ? 'Profile & app lock' : state.user?['email']?.toString() ?? ''),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(context, const ProfileScreen()),
          ),
        ),
        const SectionHeader('Money tools'),
        Card(
          child: Column(children: [
            if (context.services.capture != null)
              _item(context, Icons.inbox_outlined, 'Review inbox', 'Payments from bank SMS, UPI apps and screenshots', const ReviewInboxScreen()),
            if (context.services.capture != null)
              _item(context, Icons.auto_awesome_outlined, 'Auto-categorise rules', 'What Finverse learned from your choices', const CaptureRulesScreen()),
            if (context.services.insights != null)
              _item(context, Icons.insights_outlined, 'Insights', 'Budget alerts, unusual payments, bills due', const InsightsScreen()),
            _item(context, Icons.event_repeat, 'Bills & recurring', 'Rent, EMIs, subscriptions, salary', const SchedulesScreen()),
            _item(context, Icons.upload_file, 'Import', 'Bank statements & broker holdings', const ImportScreen()),
            _item(context, Icons.receipt_outlined, 'Income tax estimate', 'Old vs new regime (India)', const TaxScreen()),
          ]),
        ),
        const SectionHeader('Plan & protect'),
        Card(
          child: Column(children: [
            _item(context, Icons.auto_awesome, 'AI advisor', 'Ask about your finances', const AiAdvisorScreen()),
            _item(context, Icons.monitor_heart_outlined, 'Financial health', 'Emergency fund, cover, debt ratio', const EssentialsScreen()),
            _item(context, Icons.fact_check_outlined, 'Financial check-up', '15 questions, personalised next steps', const AssessmentScreen()),
            _item(context, Icons.credit_card_outlined, 'Debts & loans', 'Balances and payoff plans', const DebtsScreen()),
            _item(context, Icons.health_and_safety_outlined, 'Insurance', 'Policies, cover and renewals', const InsuranceScreen()),
            _item(context, Icons.calculate_outlined, 'Calculators', 'SIP, EMI, FIRE and more', const CalculatorsScreen()),
            _item(context, Icons.school_outlined, 'Learn', 'Money basics and glossary', const LearnScreen()),
          ]),
        ),
        const SectionHeader('Settings'),
        Card(
          child: Column(children: [
            if (context.services.backup != null)
              _item(context, Icons.backup_outlined, 'Backup & export', 'Google Drive, backup file, Excel / CSV / PDF', const BackupScreen())
            else
              _item(context, Icons.table_view_outlined, 'Export', 'Excel, CSV or PDF', const ExportScreen()),
            if (context.watch<InsightAlerts?>() != null)
              _item(context, Icons.notifications_outlined, 'Notifications', 'Alerts and reminders', const NotificationSettingsScreen()),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Theme'),
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto, size: 18)),
                  ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined, size: 18)),
                  ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined, size: 18)),
                ],
                selected: {state.themeMode},
                onSelectionChanged: (s) => context.read<AppState>().setThemeMode(s.first),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide amounts'),
              value: state.hideAmounts,
              onChanged: (_) => context.read<AppState>().toggleHideAmounts(),
            ),
            if (!state.isLocal)
              ListTile(
                leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                title: Text('Sign out', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  final ok = await confirmDialog(context, title: 'Sign out?', message: 'You will need to sign in again to use Finverse.', confirmLabel: 'Sign out');
                  if (ok && context.mounted) await context.read<AppState>().signOut();
                },
              ),
          ]),
        ),
        const SizedBox(height: 16),
        Text(
          state.isLocal ? 'Finverse mobile • offline, data stays on this phone' : 'Finverse mobile • ${Uri.parse(AppConfig.apiBaseUrl).host}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
      ]),
    );
  }
}
