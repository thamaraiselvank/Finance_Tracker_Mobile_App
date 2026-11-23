import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
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
    final results = await Future.wait([context.api.get('/goals/'), context.api.get('/goals/summary/progress')]);
    return _GoalsData(
      (results[0] as List).map((e) => Map<String, dynamic>.from(e)).toList(),
      Map<String, dynamic>.from(results[1]),
    );
  }

  void _reload() => _viewKey.currentState?.reload();

  Future<void> _openForm([Map<String, dynamic>? goal]) async {
    final saved = await showFormSheet<bool>(context, title: goal == null ? 'New goal' : 'Edit goal', child: GoalForm(existing: goal));
    if (saved == true) _reload();
  }

  Future<void> _contribute(Map<String, dynamic> goal) async {
    final controller = TextEditingController();
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
      await context.api.post('/goals/${goal['id']}/contributions', body: {'amount': amount});
      if (!mounted) return;
      context.showSnack('Contribution added');
      _reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
  }

  Future<void> _complete(Map<String, dynamic> goal) async {
    final ok = await confirmDialog(context, title: 'Mark as completed?', message: '"${goal['goal_name']}" will move to your completed goals.', confirmLabel: 'Complete', destructive: false);
    if (!ok || !mounted) return;
    try {
      await context.api.put('/goals/${goal['id']}', body: {'status': 'COMPLETED'});
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
      appBar: const AppScaffoldBar(title: 'Goals'),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Goal')),
      body: AsyncView<_GoalsData>(
        key: _viewKey,
        load: _load,
        builder: (context, d, reload) {
          final active = d.goals.where((g) => (g['status'] ?? 'ACTIVE') != 'COMPLETED').toList();
          final done = d.goals.where((g) => g['status'] == 'COMPLETED').toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            StatGrid(children: [
              StatTile(label: 'Saved so far', value: state.money.compact(d.summary['total_current_amount'], hidden: state.hideAmounts), color: AppColors.income),
              StatTile(label: 'Total target', value: state.money.compact(d.summary['total_target_amount'], hidden: state.hideAmounts)),
              StatTile(label: 'Active goals', value: '${toInt(d.summary['active_goals'])}'),
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
                onPressed: () => deleteAllFlow<Map<String, dynamic>>(context, items: d.goals, what: 'goals', pathFor: (g) => '/goals/${g['id']}', onDone: _reload),
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
              Chip(label: Text(goalTypes[goal['goal_type']] ?? humanize(goal['goal_type'])), visualDensity: VisualDensity.compact),
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
            await context.api.put('/goals/${widget.existing!['id']}', body: payload);
          } else {
            await context.api.post('/goals/', body: payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete goal?', message: 'Delete "${widget.existing!['goal_name']}" and its progress?');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.api.delete('/goals/${widget.existing!['id']}');
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
        DropdownInput<String>(label: 'Goal type', value: _type, items: goalTypes, onChanged: (v) => setState(() => _type = v)),
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
