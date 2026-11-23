import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import 'money_screen.dart' show AppScaffoldBar;

const debtTypes = {
  'HOME_LOAN': 'Home loan',
  'CAR_LOAN': 'Car loan',
  'PERSONAL_LOAN': 'Personal loan',
  'EDUCATION_LOAN': 'Education loan',
  'CREDIT_CARD': 'Credit card',
  'GOLD_LOAN': 'Gold loan',
  'BUSINESS_LOAN': 'Business loan',
  'OTHER': 'Other',
};

class _DebtsData {
  final List<Map<String, dynamic>> debts;
  final Map<String, dynamic> summary;
  _DebtsData(this.debts, this.summary);
}

class DebtsScreen extends StatefulWidget {
  const DebtsScreen({super.key});

  @override
  State<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends State<DebtsScreen> {
  final _viewKey = GlobalKey<AsyncViewState<_DebtsData>>();

  Future<_DebtsData> _load() async {
    final results = await Future.wait([context.api.get('/debts/'), context.api.get('/debts/summary/overview')]);
    return _DebtsData((results[0] as List).map((e) => Map<String, dynamic>.from(e)).toList(), Map<String, dynamic>.from(results[1]));
  }

  Future<void> _openForm([Map<String, dynamic>? debt]) async {
    final saved = await showFormSheet<bool>(context, title: debt == null ? 'Add debt' : 'Edit debt', child: DebtForm(existing: debt));
    if (saved == true) _viewKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const AppScaffoldBar(title: 'Debts & loans'),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Debt')),
      body: AsyncView<_DebtsData>(
        key: _viewKey,
        load: _load,
        builder: (context, d, reload) {
          final s = d.summary;
          final debtFree = toDate(s['estimated_debt_free_date']);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            StatGrid(children: [
              StatTile(label: 'Outstanding', value: state.money.compact(s['total_outstanding'], hidden: state.hideAmounts), color: AppColors.expense),
              StatTile(label: 'Monthly EMI', value: state.money.compact(s['total_monthly_emi'], hidden: state.hideAmounts)),
              StatTile(label: 'Avg. interest', value: percent(s['total_interest_rate_avg'])),
              StatTile(label: 'Debt-to-income', value: percent(s['debt_to_income_ratio']), subtitle: debtFree != null ? 'Debt-free ${displayDate(debtFree)}' : null),
            ]),
            if (d.debts.isEmpty)
              EmptyState(
                icon: Icons.celebration_outlined,
                title: 'No debts recorded',
                message: 'Add loans or credit card balances to plan your payoff.',
                action: FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Add debt')),
              )
            else ...[
              const SectionHeader('Your debts'),
              Card(
                child: Column(children: [
                  for (final debt in d.debts)
                    ListTile(
                      onTap: () => _openForm(debt),
                      title: Text(debt['debt_name'].toString()),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${debtTypes[debt['debt_type']] ?? humanize(debt['debt_type'])} • ${percent(debt['interest_rate_pct'])} • EMI ${state.money.compact(debt['monthly_emi'], hidden: state.hideAmounts)}',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                        const SizedBox(height: 6),
                        ProgressBar(
                          value: toDouble(debt['principal_amount']) > 0 ? 1 - toDouble(debt['current_outstanding']) / toDouble(debt['principal_amount']) : 0,
                        ),
                      ]),
                      trailing: MoneyText(debt['current_outstanding'], style: const TextStyle(fontWeight: FontWeight.w700), color: AppColors.expense),
                    ),
                ]),
              ),
              if (d.debts.length > 1) const _PayoffPlan(),
            ],
            if (d.debts.isNotEmpty)
              DeleteAllButton(
                label: 'Delete all debts (${d.debts.length})',
                onPressed: () => deleteAllFlow<Map<String, dynamic>>(
                  context,
                  items: d.debts,
                  what: 'debts',
                  pathFor: (x) => '/debts/${x['id']}',
                  onDone: () => _viewKey.currentState?.reload(),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// Avalanche (highest interest first) vs Snowball (smallest balance first).
class _PayoffPlan extends StatefulWidget {
  const _PayoffPlan();

  @override
  State<_PayoffPlan> createState() => _PayoffPlanState();
}

class _PayoffPlanState extends State<_PayoffPlan> {
  String _strategy = 'avalanche';
  Future<dynamic>? _future;

  @override
  void initState() {
    super.initState();
    _future = context.api.get('/debts/strategy/$_strategy');
  }

  void _set(String s) => setState(() {
        _strategy = s;
        _future = context.api.get('/debts/strategy/$s');
      });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Payoff plan'),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'avalanche', label: Text('Avalanche'), tooltip: 'Highest interest first – saves the most money'),
          ButtonSegment(value: 'snowball', label: Text('Snowball'), tooltip: 'Smallest balance first – quick wins'),
        ],
        selected: {_strategy},
        onSelectionChanged: (s) => _set(s.first),
      ),
      const SizedBox(height: 10),
      FutureBuilder<dynamic>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
          if (snap.hasError) return Text(snap.error.toString(), style: TextStyle(color: theme.colorScheme.error));
          final data = Map<String, dynamic>.from(snap.data ?? {});
          final order = (data['recommended_order'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
          return Card(
            child: Column(children: [
              ListTile(
                title: Text(_strategy == 'avalanche' ? 'Pay highest interest first' : 'Pay smallest balance first'),
                subtitle: Text('All debts cleared in ~${toInt(data['months_to_complete'])} months'),
              ),
              const Divider(height: 1),
              for (var i = 0; i < order.length; i++)
                ListTile(
                  leading: CircleAvatar(radius: 14, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                  title: Text(order[i]['debt_name'].toString()),
                  subtitle: Text('${percent(order[i]['interest_rate_pct'])} • paid off ${displayDate(toDate(order[i]['payoff_date']))}'),
                  trailing: Text(state.money.compact(order[i]['current_outstanding'], hidden: state.hideAmounts)),
                ),
            ]),
          );
        },
      ),
    ]);
  }
}

class DebtForm extends StatefulWidget {
  const DebtForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<DebtForm> createState() => _DebtFormState();
}

class _DebtFormState extends State<DebtForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _principal, _outstanding, _rate, _tenure, _emi, _creditor;
  String? _type;
  DateTime? _startDate;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    String num(dynamic v) => v == null ? '' : toDouble(v).toStringAsFixed(toDouble(v) == toDouble(v).roundToDouble() ? 0 : 2);
    _name = TextEditingController(text: e['debt_name']?.toString() ?? '');
    _principal = TextEditingController(text: num(e['principal_amount']));
    _outstanding = TextEditingController(text: num(e['current_outstanding']));
    _rate = TextEditingController(text: num(e['interest_rate_pct']));
    _tenure = TextEditingController(text: e['tenure_months']?.toString() ?? '');
    _emi = TextEditingController(text: num(e['monthly_emi']));
    _creditor = TextEditingController(text: e['creditor_name']?.toString() ?? '');
    _type = e['debt_type']?.toString();
    _startDate = toDate(e['start_date']);
  }

  @override
  void dispose() {
    for (final c in [_name, _principal, _outstanding, _rate, _tenure, _emi, _creditor]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Debt updated' : 'Debt added',
        action: () async {
          final tenure = int.tryParse(_tenure.text.trim());
          final payload = {
            'debt_name': _name.text.trim(),
            'debt_type': _type,
            'principal_amount': parseAmount(_principal),
            'current_outstanding': parseAmount(_outstanding) ?? 0,
            'interest_rate_pct': parseAmount(_rate) ?? 0,
            'tenure_months': (tenure != null && tenure > 0) ? tenure : null,
            'monthly_emi': parseAmount(_emi),
            'start_date': _startDate == null ? null : apiDate(_startDate!),
            if (!_isEdit) 'creditor_name': _creditor.text.trim().isEmpty ? null : _creditor.text.trim(),
          };
          if (_isEdit) {
            await context.api.put('/debts/${widget.existing!['id']}', body: payload);
          } else {
            await context.api.post('/debts/', body: payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete debt?', message: 'Delete "${widget.existing!['debt_name']}"?');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.api.delete('/debts/${widget.existing!['id']}');
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Debt deleted');
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
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextInput(controller: _name, label: 'Name (e.g. HDFC Home Loan)', required: true),
        DropdownInput<String>(label: 'Type', value: _type, items: debtTypes, onChanged: (v) => setState(() => _type = v)),
        AmountField(controller: _principal, label: 'Original loan amount', prefix: money.symbol),
        AmountField(controller: _outstanding, label: 'Current outstanding', prefix: money.symbol, allowZero: true),
        AmountField(controller: _rate, label: 'Interest rate', suffix: '% p.a.', allowZero: true),
        AmountField(controller: _emi, label: 'Monthly EMI (optional)', prefix: money.symbol, required: false),
        TextInput(
          controller: _tenure,
          label: 'Tenure in months (optional)',
          keyboardType: TextInputType.number,
          validator: (v) => (v != null && v.trim().isNotEmpty && (int.tryParse(v.trim()) ?? 0) <= 0) ? 'Enter whole months' : null,
        ),
        DateInput(label: 'Start date (optional)', value: _startDate, required: false, lastDate: DateTime.now(), onChanged: (d) => setState(() => _startDate = d)),
        if (!_isEdit) TextInput(controller: _creditor, label: 'Lender (optional)'),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Add debt'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete debt'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}
