import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../export/export_data.dart' show ExportSection;
import 'export_screen.dart' show ExportButton;
import 'money_screen.dart' show AppScaffoldBar;

const goalTypes = {
  'RETIREMENT': 'Retirement',
  'DOWN_PAYMENT': 'House down payment',
  'EMERGENCY_FUND': 'Emergency fund',
  'EDUCATION': 'Education',
  'VACATION': 'Vacation',
  'WEALTH_BUILD': 'Wealth building',
  'DEBT_PAYOFF': 'Debt payoff',
  'BUSINESS': 'Business',
  'OTHER': 'Other',
};

/// Things to buy. Offline version only (the web backend doesn't know them).
const goalPurchaseTypes = {
  'CAR': 'Buy a car',
  'BIKE': 'Buy a bike / scooter',
  'HOME': 'Buy a home',
  'GADGET': 'Phone, laptop or gadget',
  'WEDDING': 'Wedding',
  'GOLD': 'Gold / jewellery',
};

/// Goal types offered in the form (and used for labels).
Map<String, String> get goalTypeChoices => AppConfig.isLocal ? {...goalPurchaseTypes, ...goalTypes} : goalTypes;

String goalTypeLabel(Object? type) => {...goalTypes, ...goalPurchaseTypes}[type] ?? humanize(type?.toString());

const goalPriorities = {1: '1 – Highest', 2: '2 – High', 3: '3 – Medium', 4: '4 – Low', 5: '5 – Lowest'};

class _GoalsData {
  final List<Map<String, dynamic>> goals;
  final Map<String, dynamic> summary;
  _GoalsData(this.goals, this.summary);
}

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  final _viewKey = GlobalKey<AsyncViewState<_GoalsData>>();

  Future<_GoalsData> _load() async {
    final goals = context.services.goals;
    final r = await Future.wait<Object>([goals.list(), goals.progressSummary()]);
    return _GoalsData(r[0] as List<Map<String, dynamic>>, r[1] as Map<String, dynamic>);
  }

  void _reload() => _viewKey.currentState?.reload();

  Future<void> _openForm([Map<String, dynamic>? goal]) async {
    final saved = await showFormSheet<bool>(context, title: goal == null ? 'New goal' : 'Edit goal', child: GoalForm(existing: goal));
    if (saved == true) _reload();
  }

  Future<void> _contribute(Map<String, dynamic> goal) async {
    final history = goal['saving_history'] as Map?;
    final left = toDouble(history?['left_this_month']);
    final controller = TextEditingController(text: left > 0 ? left.toStringAsFixed(0) : '');
    final formKey = GlobalKey<FormState>();
    final money = context.read<AppState>().money;
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add to "${goal['goal_name']}"'),
        content: Form(key: formKey, child: AmountField(controller: controller, label: 'Amount', prefix: money.symbol)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, double.parse(controller.text));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (amount == null || !mounted) return;
    try {
      await context.services.goals.addContribution(goal['id'].toString(), amount);
      if (!mounted) return;
      final plan = toDouble(history?['plan']);
      final before = toDouble(history?['this_month']);
      final streak = toInt(history?['streak']);
      final money = context.read<AppState>().money;
      if (plan > 0 && before < plan && before + amount >= plan) {
        final months = streak + 1;
        context.showSnack(months > 1 ? "This month's saving is done. $months months in a row! 🔥" : "This month's saving is done! 🎉");
      } else if (plan > 0 && before + amount < plan) {
        context.showSnack("Added. ${money.format(plan - before - amount)} more to reach this month's plan.");
      } else {
        context.showSnack('Added to your goal');
      }
      _reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
  }

  Future<void> _complete(Map<String, dynamic> goal) async {
    final ok = await confirmDialog(context, title: 'Mark as completed?', message: '"${goal['goal_name']}" will move to your completed goals.', confirmLabel: 'Complete', destructive: false);
    if (!ok || !mounted) return;
    try {
      await context.services.goals.update(goal['id'].toString(), {'status': 'COMPLETED'});
      if (!mounted) return;
      context.showSnack('Goal completed 🎉');
      _reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: const AppScaffoldBar(title: 'Goals', actions: [ExportButton(sections: {ExportSection.goals})]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Goal')),
      body: AsyncView<_GoalsData>(
        key: _viewKey,
        load: _load,
        builder: (context, d, reload) {
          final active = d.goals.where((g) => (g['status'] ?? 'ACTIVE') != 'COMPLETED').toList();
          final done = d.goals.where((g) => g['status'] == 'COMPLETED').toList();
          final tracked = active.where((g) => g['saving_history'] is Map).toList();
          final savedThisMonth = tracked.fold<double>(0, (s, g) => s + toDouble((g['saving_history'] as Map)['this_month']));
          final planThisMonth = tracked.fold<double>(0, (s, g) => s + toDouble((g['saving_history'] as Map)['plan']));
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            StatGrid(children: [
              StatTile(label: 'Saved so far', value: state.money.compact(d.summary['total_current_amount'], hidden: state.hideAmounts), color: AppColors.income),
              StatTile(label: 'Total target', value: state.money.compact(d.summary['total_target_amount'], hidden: state.hideAmounts)),
              StatTile(label: 'Active goals', value: '${toInt(d.summary['active_goals'])}'),
              if (tracked.isNotEmpty)
                StatTile(
                  label: 'Saved this month',
                  value: state.money.compact(savedThisMonth, hidden: state.hideAmounts),
                  color: planThisMonth > 0 && savedThisMonth >= planThisMonth ? AppColors.income : null,
                  subtitle: planThisMonth > 0 ? 'Plan ${state.money.compact(planThisMonth, hidden: state.hideAmounts)}' : null,
                )
              else
                StatTile(label: 'Monthly allocation', value: state.money.compact(d.summary['total_monthly_allocation'], hidden: state.hideAmounts)),
            ]),
            if (d.goals.isEmpty)
              EmptyState(
                icon: Icons.flag_outlined,
                title: 'No goals yet',
                message: 'Set a target – a house, education, retirement – and track your progress.',
                action: FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Create a goal')),
              ),
            if (active.isNotEmpty) const SectionHeader('Active'),
            ...active.map((g) => _GoalCard(goal: g, onEdit: () => _openForm(g), onContribute: () => _contribute(g), onComplete: () => _complete(g))),
            if (done.isNotEmpty) const SectionHeader('Completed'),
            ...done.map((g) => _GoalCard(goal: g, onEdit: () => _openForm(g))),
            if (d.goals.isNotEmpty)
              DeleteAllButton(
                label: 'Delete all goals (${d.goals.length})',
                onPressed: () => deleteAllFlow<Map<String, dynamic>>(context, items: d.goals, what: 'goals', deleteItem: (g) => context.services.goals.delete(g['id'].toString()), onDone: _reload),
              ),
          ]);
        },
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.onEdit, this.onContribute, this.onComplete});
  final Map<String, dynamic> goal;
  final VoidCallback onEdit;
  final VoidCallback? onContribute;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final target = toDouble(goal['target_amount']);
    final current = toDouble(goal['current_amount']);
    final progress = target > 0 ? current / target : 0.0;
    final targetDate = toDate(goal['target_date']);
    final suggested = toDouble(goal['suggested_monthly_savings']);
    final completed = goal['status'] == 'COMPLETED';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(goal['goal_name'].toString(), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              Chip(label: Text(goalTypeLabel(goal['goal_type'])), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Text(state.money.format(current, hidden: state.hideAmounts), style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(' of ${state.money.format(target, hidden: state.hideAmounts)}', style: TextStyle(color: theme.colorScheme.outline)),
              const Spacer(),
              Text(percent(progress * 100, digits: 0), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            ProgressBar(value: progress, color: completed ? AppColors.income : null),
            const SizedBox(height: 8),
            if (!completed && goal['saving_history'] is Map) ...[
              _SavingTracker(history: Map<String, dynamic>.from(goal['saving_history'] as Map)),
              const SizedBox(height: 8),
            ],
            Text(
              [
                'Target ${displayDate(targetDate)}',
                if (!completed && suggested > 0) 'Save ${state.money.compact(suggested, hidden: state.hideAmounts)}/mo to stay on track',
              ].join(' • '),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
            if (!completed && (onContribute != null || onComplete != null)) ...[
              const SizedBox(height: 8),
              Row(children: [
                if (onContribute != null) TextButton.icon(onPressed: onContribute, icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Add money')),
                if (onComplete != null && progress >= 1) TextButton.icon(onPressed: onComplete, icon: const Icon(Icons.check_circle_outline, size: 18), label: const Text('Complete')),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

/// This month's saving for a goal, the last few months as saved / missed
/// dots, and the streak of months that met the plan.
class _SavingTracker extends StatelessWidget {
  const _SavingTracker({required this.history});
  final Map<String, dynamic> history;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final months = (history['months'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final plan = toDouble(history['plan']);
    final saved = toDouble(history['this_month']);
    final left = toDouble(history['left_this_month']);
    final streak = toInt(history['streak']);
    final lastMonth = months.length >= 2 ? months[months.length - 2]['status'] : null;
    String m(double v) => state.money.format(v, hidden: state.hideAmounts);

    final String message;
    final Color tone;
    if (plan <= 0) {
      message = saved > 0 ? 'You saved ${m(saved)} this month' : 'Nothing saved this month yet';
      tone = saved > 0 ? AppColors.income : theme.colorScheme.outline;
    } else if (left <= 0) {
      message = "This month's ${m(plan)} is saved. Well done!";
      tone = AppColors.income;
    } else if (lastMonth == 'missed' || lastMonth == 'partial') {
      message = 'Last month fell short. Save ${m(left)} this month to get back on track.';
      tone = AppColors.warning;
    } else {
      message = saved > 0 ? '${m(saved)} of ${m(plan)} saved this month · ${m(left)} to go' : 'Save ${m(plan)} this month to stay on track';
      tone = saved > 0 ? AppColors.info : theme.colorScheme.outline;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: tone.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(message, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
          if (streak >= 2) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppColors.warning.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
              child: Text('🔥 $streak months', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ],
        ]),
        if (plan > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (saved / plan).clamp(0.0, 1.0),
              minHeight: 6,
              color: left <= 0 ? AppColors.income : AppColors.info,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (final month in months) _MonthDot(month: month),
        ]),
      ]),
    );
  }
}

/// One month: saved (tick), less than planned (dash), missed (cross),
/// this month (ring) or before the goal existed (faint ring).
class _MonthDot extends StatelessWidget {
  const _MonthDot({required this.month});
  final Map<String, dynamic> month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final date = DateTime.parse('${month['month']}-01');
    final status = month['status'] as String;
    final (IconData? icon, Color color, String tip) = switch (status) {
      'met' => (Icons.check, AppColors.income, 'Saved'),
      'partial' => (Icons.remove, AppColors.warning, 'Saved less than planned'),
      'missed' => (Icons.close, AppColors.expense, 'Missed'),
      'open' => (null, AppColors.info, 'This month'),
      _ => (null, theme.colorScheme.outlineVariant, 'Before this goal'),
    };
    final saved = toDouble(month['saved']);
    return Tooltip(
      message: '${DateFormat('MMMM').format(date)}: $tip${saved > 0 ? ' · ${state.money.format(saved, hidden: state.hideAmounts)}' : ''}',
      triggerMode: TooltipTriggerMode.tap,
      child: Column(children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: status == 'open' || status == 'before' ? null : color.withValues(alpha: 0.18),
            border: Border.all(color: color, width: status == 'open' ? 2 : 1),
          ),
          child: icon == null ? null : Icon(icon, size: 15, color: color),
        ),
        const SizedBox(height: 3),
        Text(DateFormat('MMM').format(date), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
      ]),
    );
  }
}

class GoalForm extends StatefulWidget {
  const GoalForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends State<GoalForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _target, _current, _monthly, _description;
  String? _type;
  int _priority = 3;
  DateTime? _targetDate;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    String num(dynamic v) => v == null ? '' : toDouble(v).toStringAsFixed(0);
    _name = TextEditingController(text: e['goal_name']?.toString() ?? '');
    _target = TextEditingController(text: num(e['target_amount']));
    _current = TextEditingController(text: num(e['current_amount']));
    _monthly = TextEditingController(text: toDouble(e['allocated_monthly_savings']) > 0 ? num(e['allocated_monthly_savings']) : '');
    _description = TextEditingController(text: e['description']?.toString() ?? '');
    _type = e['goal_type']?.toString();
    _priority = toInt(e['priority'], 3);
    _targetDate = toDate(e['target_date']);
  }

  @override
  void dispose() {
    for (final c in [_name, _target, _current, _monthly, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Goal updated' : 'Goal created',
        action: () async {
          final payload = {
            'goal_name': _name.text.trim(),
            'goal_type': _type,
            'target_amount': parseAmount(_target),
            'current_amount': parseAmount(_current) ?? 0,
            'target_date': apiDate(_targetDate!),
            'priority': _priority,
            'allocated_monthly_savings': parseAmount(_monthly) ?? 0,
            'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
          };
          if (_isEdit) {
            await context.services.goals.update(widget.existing!['id'].toString(), payload);
          } else {
            await context.services.goals.create(payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete goal?', message: 'Delete "${widget.existing!['goal_name']}" and its progress?');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.services.goals.delete(widget.existing!['id'].toString());
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Goal deleted');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        context.showSnack(e.toString(), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = context.read<AppState>().money;
    final now = DateTime.now();
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextInput(controller: _name, label: 'Goal name', required: true),
        DropdownInput<String>(label: 'Goal type', value: _type, items: {...goalTypeChoices, if (_type != null && !goalTypeChoices.containsKey(_type)) _type!: goalTypeLabel(_type)}, onChanged: (v) => setState(() => _type = v)),
        AmountField(controller: _target, label: 'Target amount', prefix: money.symbol),
        AmountField(controller: _current, label: 'Already saved', prefix: money.symbol, required: false),
        DateInput(
          label: 'Target date',
          value: _targetDate,
          firstDate: _isEdit ? DateTime(now.year - 10) : now,
          onChanged: (d) => setState(() => _targetDate = d),
        ),
        AmountField(controller: _monthly, label: 'Monthly savings allocated (optional)', prefix: money.symbol, required: false),
        DropdownInput<int>(label: 'Priority', value: _priority, items: goalPriorities, onChanged: (v) => setState(() => _priority = v ?? 3)),
        TextInput(controller: _description, label: 'Notes (optional)', maxLines: 2),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Create goal'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete goal'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}
