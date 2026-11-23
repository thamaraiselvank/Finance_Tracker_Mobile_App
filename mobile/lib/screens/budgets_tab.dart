import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

/// Money → Budgets: monthly spending limit per expense category.
class BudgetsTab extends StatefulWidget {
  const BudgetsTab({super.key});

  @override
  State<BudgetsTab> createState() => _BudgetsTabState();
}

class _BudgetsTabState extends State<BudgetsTab> with AutomaticKeepAliveClientMixin {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  final _viewKey = GlobalKey<AsyncViewState<List<Map<String, dynamic>>>>();
  bool _copying = false;

  @override
  bool get wantKeepAlive => true;

  Future<List<Map<String, dynamic>>> _fetch(DateTime month) => context.services.budgets.forMonth(month.month, month.year);

  void _shift(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
    _viewKey.currentState?.reload();
  }

  Future<void> _editLimit(Map<String, dynamic> b) async {
    final money = context.read<AppState>().money;
    final controller = TextEditingController(text: b['monthly_limit'] == null ? '' : toDouble(b['monthly_limit']).toStringAsFixed(0));
    final formKey = GlobalKey<FormState>();
    final limit = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Budget for ${b['category_name']}'),
        content: SingleChildScrollView(child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Spent so far in ${DateFormat('MMMM').format(_month)}: ${money.format(b['spent'])}'),
            const SizedBox(height: 14),
            AmountField(controller: controller, label: 'Monthly limit', prefix: money.symbol, allowZero: true),
          ]),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, double.parse(controller.text));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (limit == null || !mounted) return;
    try {
      await _save(b['category_id'].toString(), limit, _month);
      if (!mounted) return;
      context.showSnack('Budget saved');
      _viewKey.currentState?.reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
  }

  Future<void> _save(String categoryId, double limit, DateTime month) =>
      context.services.budgets.setLimit(categoryId: categoryId, monthlyLimit: limit, month: month.month, year: month.year);

  /// Copy every limit from the previous month into this month.
  Future<void> _copyFromLastMonth() async {
    setState(() => _copying = true);
    try {
      final previous = await _fetch(DateTime(_month.year, _month.month - 1));
      final withLimits = previous.where((b) => b['monthly_limit'] != null).toList();
      if (withLimits.isEmpty) {
        if (mounted) context.showSnack('No budgets were set last month.');
        return;
      }
      for (final b in withLimits) {
        await _save(b['category_id'].toString(), toDouble(b['monthly_limit']), _month);
      }
      if (!mounted) return;
      context.showSnack('Copied ${withLimits.length} budgets from last month');
      _viewKey.currentState?.reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(children: [
          IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
          Expanded(child: Text(DateFormat('MMMM yyyy').format(_month), textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right)),
        ]),
      ),
      Expanded(
        child: AsyncView<List<Map<String, dynamic>>>(
          key: _viewKey,
          load: () => _fetch(_month),
          builder: (context, budgets, reload) {
            final set = budgets.where((b) => b['monthly_limit'] != null).toList()
              ..sort((a, b) => _usage(b).compareTo(_usage(a)));
            final unset = budgets.where((b) => b['monthly_limit'] == null).toList()
              ..sort((a, b) => toDouble(b['spent']).compareTo(toDouble(a['spent'])));
            final totalLimit = set.fold<double>(0, (s, b) => s + toDouble(b['monthly_limit']));
            final totalSpentBudgeted = set.fold<double>(0, (s, b) => s + toDouble(b['spent']));
            final over = set.where((b) => b['over_budget'] == true).length;

            // How far through the month we are, to judge pace.
            final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
            final monthProgress = isCurrent ? now.day / daysInMonth : 1.0;

            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              if (set.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Budgeted spending', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
                      const SizedBox(height: 4),
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(state.money.format(totalSpentBudgeted, hidden: state.hideAmounts), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                        Text('  of ${state.money.format(totalLimit, hidden: state.hideAmounts)}', style: TextStyle(color: theme.colorScheme.outline)),
                      ]),
                      const SizedBox(height: 10),
                      ProgressBar(value: totalLimit > 0 ? totalSpentBudgeted / totalLimit : 0, color: totalSpentBudgeted > totalLimit ? AppColors.expense : null),
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (over > 0) '$over over budget',
                          if (totalLimit - totalSpentBudgeted >= 0) '${state.money.format(totalLimit - totalSpentBudgeted, hidden: state.hideAmounts)} left',
                          if (isCurrent) '${daysInMonth - now.day} days to go',
                        ].join(' • '),
                        style: theme.textTheme.bodySmall?.copyWith(color: over > 0 ? AppColors.expense : theme.colorScheme.outline),
                      ),
                    ]),
                  ),
                ),
              if (set.isEmpty)
                EmptyState(
                  icon: Icons.pie_chart_outline,
                  title: 'No budgets for ${DateFormat('MMMM').format(_month)}',
                  message: 'Tap any category below to set a monthly limit, or copy last month\'s budgets.',
                  action: OutlinedButton.icon(
                    onPressed: _copying ? null : _copyFromLastMonth,
                    icon: _copying ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.copy_all),
                    label: const Text('Copy last month'),
                  ),
                ),
              if (set.isNotEmpty) ...[
                const SectionHeader('Your budgets'),
                Card(
                  child: Column(children: [
                    for (final b in set) _BudgetRow(budget: b, monthProgress: monthProgress, onTap: () => _editLimit(b)),
                  ]),
                ),
              ],
              if (unset.isNotEmpty) ...[
                const SectionHeader('Categories without a budget'),
                Card(
                  child: Column(children: [
                    for (final b in unset)
                      ListTile(
                        dense: true,
                        title: Text(b['category_name'].toString()),
                        subtitle: toDouble(b['spent']) > 0 ? Text('Spent ${state.money.format(b['spent'], hidden: state.hideAmounts)}') : null,
                        trailing: const Text('Set limit'),
                        onTap: () => _editLimit(b),
                      ),
                  ]),
                ),
              ],
            ]);
          },
        ),
      ),
    ]);
  }

  double _usage(Map<String, dynamic> b) {
    final limit = toDouble(b['monthly_limit']);
    return limit > 0 ? toDouble(b['spent']) / limit : (toDouble(b['spent']) > 0 ? 99 : 0);
  }
}

class _BudgetRow extends StatelessWidget {
  const _BudgetRow({required this.budget, required this.monthProgress, required this.onTap});
  final Map<String, dynamic> budget;
  final double monthProgress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final limit = toDouble(budget['monthly_limit']);
    final spent = toDouble(budget['spent']);
    final ratio = limit > 0 ? spent / limit : (spent > 0 ? 1.0 : 0.0);
    final over = budget['over_budget'] == true;
    // Ahead of pace = spending faster than the month is passing.
    final aheadOfPace = !over && monthProgress < 1 && ratio > monthProgress + 0.1;
    final color = over ? AppColors.expense : (aheadOfPace ? AppColors.warning : AppColors.income);
    final remaining = limit - spent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(budget['category_name'].toString(), style: const TextStyle(fontWeight: FontWeight.w600))),
            Text('${state.money.format(spent, hidden: state.hideAmounts)} / ${state.money.compact(limit, hidden: state.hideAmounts)}'),
          ]),
          const SizedBox(height: 8),
          ProgressBar(value: ratio, color: color),
          const SizedBox(height: 6),
          Text(
            over
                ? 'Over by ${state.money.format(-remaining, hidden: state.hideAmounts)}'
                : '${state.money.format(remaining, hidden: state.hideAmounts)} left${aheadOfPace ? ' • spending faster than usual' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(color: over || aheadOfPace ? color : theme.colorScheme.outline),
          ),
        ]),
      ),
    );
  }
}
