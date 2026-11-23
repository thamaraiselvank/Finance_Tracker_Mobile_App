import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/transaction_tile.dart';
import 'essentials_screen.dart';
import 'home_shell.dart';
import 'schedules_screen.dart';

/// Top 4 expense categories this month as labelled bars.
class _TopSpending extends StatelessWidget {
  const _TopSpending({required this.transactions, required this.total});
  final List<Map<String, dynamic>> transactions;
  final double total;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final byCat = <String, (double, String?)>{};
    for (final t in transactions) {
      final name = t['category_name']?.toString() ?? 'Uncategorised';
      final prev = byCat[name];
      byCat[name] = ((prev?.$1 ?? 0) + toDouble(t['amount']), t['category_color'] as String?);
    }
    final sorted = byCat.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    final sum = total > 0 ? total : sorted.fold<double>(0, (s, e) => s + e.value.$1);
    const fallback = [Color(0xFF10B981), Color(0xFF0EA5E9), Color(0xFFF59E0B), Color(0xFF8B5CF6)];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          for (var i = 0; i < sorted.length && i < 4; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                Row(children: [
                  Expanded(child: Text(sorted[i].key, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Text(state.money.format(sorted[i].value.$1, hidden: state.hideAmounts), style: const TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(width: 44, child: Text(percent(sum > 0 ? sorted[i].value.$1 / sum * 100 : 0, digits: 0), textAlign: TextAlign.right)),
                ]),
                const SizedBox(height: 4),
                ProgressBar(value: sum > 0 ? sorted[i].value.$1 / sum : 0, color: parseHexColor(sorted[i].value.$2, fallback[i])),
              ]),
            ),
        ]),
      ),
    );
  }
}

class DashboardData {
  final Map<String, dynamic> wealth;
  final Map<String, dynamic> cashflow;
  final Map<String, dynamic> goals;
  final Map<String, dynamic> debts;
  final Map<String, dynamic> insurance;
  final List<Map<String, dynamic>> monthTransactions;
  final List<Map<String, dynamic>> occurrences;
  final Map<String, dynamic> health;
  DashboardData(this.wealth, this.cashflow, this.goals, this.debts, this.insurance, this.monthTransactions, this.occurrences, this.health);
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.onNavigate});
  final ValueChanged<int> onNavigate;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Future<DashboardData> _load() async {
    final s = context.services;
    // Each section degrades gracefully if it fails, like the web app.
    Future<Map<String, dynamic>> safe(Future<Map<String, dynamic>> f) async {
      try {
        return await f;
      } catch (_) {
        return {};
      }
    }

    Future<List<Map<String, dynamic>>> safeList(Future<List<Map<String, dynamic>>> f) async {
      try {
        return await f;
      } catch (_) {
        return [];
      }
    }

    final now = DateTime.now();
    final results = await Future.wait<dynamic>([
      s.assets.summary(), // required: surfaces errors
      safe(s.transactions.summary()),
      safe(s.goals.progressSummary()),
      safe(s.debts.summary()),
      safe(s.insurance.summary()),
      safeList(s.transactions.list(
        start: DateTime(now.year, now.month, 1),
        end: DateTime(now.year, now.month + 1, 0),
        type: 'EXPENSE',
        limit: 5000,
      )),
      safeList(s.schedules.occurrences(
        start: DateTime(now.year, now.month, 1),
        end: now.add(const Duration(days: 7)),
      )),
      safe(s.essentials.healthCheck()),
    ]);
    return DashboardData(results[0], results[1], results[2], results[3], results[4], results[5], results[6], results[7]);
  }

  /// Overdue (this month) and not-yet-done items in the next 7 days.
  List<Map<String, dynamic>> _dueSoon(List<Map<String, dynamic>> occ) =>
      occ.where((o) => o['status'] == 'overdue' || o['status'] == 'upcoming').toList();

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_greeting(), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          Text(state.displayName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ]),
        actions: const [HideAmountsButton()],
      ),
      body: AsyncView<DashboardData>(
        load: _load,
        builder: (context, d, reload) {
          final income = toDouble(d.cashflow['total_income']);
          final expense = toDouble(d.cashflow['total_expense']);
          final net = toDouble(d.cashflow['net_savings']);
          final savingsRate = income > 0 ? (net / income * 100) : 0.0;
          final goalTarget = toDouble(d.goals['total_target_amount']);
          final goalCurrent = toDouble(d.goals['total_current_amount']);
          final recent = (d.cashflow['recent_transactions'] as List? ?? []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
          final gaps = (d.insurance['critical_gaps'] as List? ?? []).map((e) => e.toString()).toList();

          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            _NetWorthCard(wealth: d.wealth),
            const SectionHeader('This month'),
            StatGrid(children: [
              StatTile(label: 'Income', value: state.money.compact(income, hidden: state.hideAmounts), color: AppColors.income, icon: Icons.south_west),
              StatTile(label: 'Expenses', value: state.money.compact(expense, hidden: state.hideAmounts), color: AppColors.expense, icon: Icons.north_east),
              StatTile(label: 'Net savings', value: state.money.compact(net, hidden: state.hideAmounts), color: net >= 0 ? AppColors.income : AppColors.expense, icon: Icons.savings_outlined),
              StatTile(label: 'Savings rate', value: percent(savingsRate, digits: 0), icon: Icons.percent, subtitle: 'Target ${percent(state.user?['target_savings_rate'], digits: 0)}'),
            ]),
            if (d.monthTransactions.isNotEmpty) ...[
              SectionHeader('Top spending this month', trailing: TextButton(onPressed: () => widget.onNavigate(1), child: const Text('Breakdown'))),
              _TopSpending(transactions: d.monthTransactions, total: expense),
            ],
            if (_dueSoon(d.occurrences).isNotEmpty) ...[
              SectionHeader(
                'Due in the next 7 days',
                trailing: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SchedulesScreen())), child: const Text('All bills')),
              ),
              Card(
                child: Column(children: [
                  for (final o in _dueSoon(d.occurrences).take(4))
                    ListTile(
                      dense: true,
                      leading: Icon(
                        o['status'] == 'overdue' ? Icons.error_outline : (o['flow_type'] == 'INCOME' ? Icons.south_west : Icons.event_outlined),
                        color: o['status'] == 'overdue' ? AppColors.expense : (o['flow_type'] == 'INCOME' ? AppColors.income : theme.colorScheme.primary),
                      ),
                      title: Text(o['description'].toString()),
                      subtitle: Text(o['status'] == 'overdue' ? 'Overdue since ${shortDate(toDate(o['occurrence_date']))}' : 'Due ${shortDate(toDate(o['occurrence_date']))}'),
                      trailing: MoneyText(o['amount'], style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                ]),
              ),
            ],
            const SectionHeader('Snapshot'),
            Card(
              child: Column(children: [
                if (d.health.isNotEmpty) ...[
                  _SnapshotRow(
                    icon: Icons.monitor_heart_outlined,
                    title: 'Financial health',
                    subtitle: '${d.health['health_score_status'] ?? '—'} • ${toDouble(d.health['emergency_runway_months']).toStringAsFixed(1)} months emergency runway',
                    trailing: '${toDouble(d.health['overall_health_score']).toStringAsFixed(1)}/10',
                    progress: toDouble(d.health['overall_health_score']) / 10,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EssentialsScreen())),
                  ),
                  const Divider(height: 1),
                ],
                _SnapshotRow(
                  icon: Icons.flag_outlined,
                  title: 'Goals',
                  subtitle: '${toInt(d.goals['active_goals'])} active • ${toInt(d.goals['completed_goals'])} completed',
                  trailing: goalTarget > 0 ? percent(goalCurrent / goalTarget * 100, digits: 0) : '—',
                  progress: goalTarget > 0 ? goalCurrent / goalTarget : null,
                  onTap: () => widget.onNavigate(3),
                ),
                const Divider(height: 1),
                _SnapshotRow(
                  icon: Icons.credit_card_outlined,
                  title: 'Debt outstanding',
                  subtitle: '${toInt(d.debts['number_of_debts'])} debts • EMI ${state.money.compact(d.debts['total_monthly_emi'], hidden: state.hideAmounts)}/mo',
                  trailing: state.money.compact(d.wealth['total_liabilities_outstanding'], hidden: state.hideAmounts),
                  onTap: () => widget.onNavigate(4),
                ),
                const Divider(height: 1),
                _SnapshotRow(
                  icon: Icons.health_and_safety_outlined,
                  title: 'Insurance',
                  subtitle: '${toInt(d.insurance['active_policies'])} active policies',
                  trailing: state.money.compact(d.insurance['total_sum_insured'], hidden: state.hideAmounts),
                  onTap: () => widget.onNavigate(4),
                ),
              ]),
            ),
            if (gaps.isNotEmpty) ...[
              const SectionHeader('Needs attention'),
              ...gaps.take(3).map((g) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(leading: const Icon(Icons.warning_amber_rounded, color: AppColors.warning), title: Text(g)),
                  )),
            ],
            SectionHeader('Recent activity', trailing: TextButton(onPressed: () => widget.onNavigate(1), child: const Text('See all'))),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: recent.isEmpty
                    ? const EmptyState(icon: Icons.receipt_long_outlined, title: 'No transactions yet', message: 'Add your first income or expense from the Money tab.')
                    : Column(children: recent.take(6).map((t) => TransactionTile(tx: t)).toList()),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _NetWorthCard extends StatelessWidget {
  const _NetWorthCard({required this.wealth});
  final Map<String, dynamic> wealth;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final pnl = toDouble(wealth['total_assets_pnl']);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(colors: [Color(0xFF059669), Color(0xFF0E7490)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Net worth', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(state.money.format(wealth['net_worth'], hidden: state.hideAmounts),
                style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _mini('Assets', state.money.compact(wealth['total_assets_current'], hidden: state.hideAmounts))),
            Expanded(child: _mini('Liabilities', state.money.compact(wealth['total_liabilities_outstanding'], hidden: state.hideAmounts))),
            Expanded(child: _mini('Returns', '${pnl >= 0 ? '+' : ''}${percent(wealth['total_assets_pnl_pct'])}')),
          ]),
        ]),
      ),
    );
  }

  Widget _mini(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
      ]);
}

class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({required this.icon, required this.title, required this.subtitle, required this.trailing, this.progress, this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        if (progress != null) ...[const SizedBox(height: 6), ProgressBar(value: progress!)],
      ]),
      trailing: Text(trailing, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}
