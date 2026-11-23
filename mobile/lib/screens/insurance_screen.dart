import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import 'money_screen.dart' show AppScaffoldBar;

const policyTypes = {
  'HEALTH': 'Health',
  'TERM_LIFE': 'Term life',
  'CRITICAL_ILLNESS': 'Critical illness',
  'MOTOR': 'Motor',
  'HOME': 'Home',
  'TRAVEL': 'Travel',
  'OTHER': 'Other',
};

const paymentFrequencies = {'MONTHLY': 'Monthly', 'QUARTERLY': 'Quarterly', 'HALF_YEARLY': 'Half-yearly', 'YEARLY': 'Yearly'};

class _InsuranceData {
  final List<Map<String, dynamic>> policies;
  final Map<String, dynamic> summary;
  _InsuranceData(this.policies, this.summary);
}

class InsuranceScreen extends StatefulWidget {
  const InsuranceScreen({super.key});

  @override
  State<InsuranceScreen> createState() => _InsuranceScreenState();
}

class _InsuranceScreenState extends State<InsuranceScreen> {
  final _viewKey = GlobalKey<AsyncViewState<_InsuranceData>>();

  Future<_InsuranceData> _load() async {
    final results = await Future.wait([context.api.get('/insurance/'), context.api.get('/insurance/summary/overview')]);
    return _InsuranceData((results[0] as List).map((e) => Map<String, dynamic>.from(e)).toList(), Map<String, dynamic>.from(results[1]));
  }

  Future<void> _openForm([Map<String, dynamic>? policy]) async {
    final saved = await showFormSheet<bool>(context, title: policy == null ? 'Add policy' : 'Edit policy', child: PolicyForm(existing: policy));
    if (saved == true) _viewKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const AppScaffoldBar(title: 'Insurance'),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Policy')),
      body: AsyncView<_InsuranceData>(
        key: _viewKey,
        load: _load,
        builder: (context, d, reload) {
          final s = d.summary;
          final gaps = (s['critical_gaps'] as List? ?? []).map((e) => e.toString()).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            StatGrid(children: [
              StatTile(label: 'Total cover', value: state.money.compact(s['total_sum_insured'], hidden: state.hideAmounts), icon: Icons.shield_outlined),
              StatTile(label: 'Annual premium', value: state.money.compact(s['total_annual_premium'], hidden: state.hideAmounts)),
              StatTile(
                label: 'Health cover',
                value: s['health_coverage_adequate'] == true ? 'Adequate' : 'Review',
                color: s['health_coverage_adequate'] == true ? AppColors.income : AppColors.warning,
              ),
              StatTile(
                label: 'Life cover',
                value: s['life_coverage_adequate'] == true ? 'Adequate' : 'Review',
                color: s['life_coverage_adequate'] == true ? AppColors.income : AppColors.warning,
              ),
            ]),
            if (gaps.isNotEmpty) ...[
              const SectionHeader('Coverage gaps'),
              ...gaps.map((g) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(leading: const Icon(Icons.warning_amber_rounded, color: AppColors.warning), title: Text(g)),
                  )),
            ],
            if (d.policies.isEmpty)
              EmptyState(
                icon: Icons.health_and_safety_outlined,
                title: 'No policies yet',
                message: 'Add health, life and other policies to check your protection and renewal dates.',
                action: FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Add policy')),
              )
            else ...[
              const SectionHeader('Policies'),
              Card(
                child: Column(children: [
                  for (final p in d.policies)
                    ListTile(
                      onTap: () => _openForm(p),
                      leading: CircleAvatar(child: Icon(_icon(p['policy_type']?.toString()), size: 20)),
                      title: Text(p['policy_name'].toString()),
                      subtitle: Text(
                        [
                          policyTypes[p['policy_type']] ?? humanize(p['policy_type']),
                          if (p['insurer_name'] != null) p['insurer_name'],
                          if (p['next_payment_date'] != null) 'Due ${displayDate(toDate(p['next_payment_date']))}',
                        ].join(' • '),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        MoneyText(p['sum_insured'], compact: true, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${state.money.compact(p['annual_premium'], hidden: state.hideAmounts)}/yr', style: theme.textTheme.bodySmall),
                      ]),
                    ),
                ]),
              ),
            ],
            if (d.policies.isNotEmpty)
              DeleteAllButton(
                label: 'Delete all policies (${d.policies.length})',
                onPressed: () => deleteAllFlow<Map<String, dynamic>>(
                  context,
                  items: d.policies,
                  what: 'insurance policies',
                  pathFor: (p) => '/insurance/${p['id']}',
                  onDone: () => _viewKey.currentState?.reload(),
                ),
              ),
          ]);
        },
      ),
    );
  }

  IconData _icon(String? type) => switch (type) {
        'HEALTH' || 'CRITICAL_ILLNESS' => Icons.local_hospital_outlined,
        'TERM_LIFE' => Icons.favorite_outline,
        'MOTOR' => Icons.directions_car_outlined,
        'HOME' => Icons.home_outlined,
        'TRAVEL' => Icons.flight_outlined,
        _ => Icons.shield_outlined,
      };
}

class PolicyForm extends StatefulWidget {
  const PolicyForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<PolicyForm> createState() => _PolicyFormState();
}

class _PolicyFormState extends State<PolicyForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _sumInsured, _premium, _insurer, _policyNumber, _dependents;
  String? _type;
  String _frequency = 'YEARLY';
  String _paymentStatus = 'PENDING';
  DateTime? _nextPayment;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    String num(dynamic v) => v == null ? '' : toDouble(v).toStringAsFixed(0);
    _name = TextEditingController(text: e['policy_name']?.toString() ?? '');
    _sumInsured = TextEditingController(text: num(e['sum_insured']));
    _premium = TextEditingController(text: num(e['annual_premium']));
    _insurer = TextEditingController(text: e['insurer_name']?.toString() ?? '');
    _policyNumber = TextEditingController(text: e['policy_number']?.toString() ?? '');
    _dependents = TextEditingController(text: '${toInt(e['dependents_covered'])}');
    _type = e['policy_type']?.toString();
    _frequency = e['payment_frequency']?.toString() ?? 'YEARLY';
    _paymentStatus = e['payment_status']?.toString() ?? 'PENDING';
    _nextPayment = toDate(e['next_payment_date']);
  }

  @override
  void dispose() {
    for (final c in [_name, _sumInsured, _premium, _insurer, _policyNumber, _dependents]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Policy updated' : 'Policy added',
        action: () async {
          String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
          final payload = {
            'policy_name': _name.text.trim(),
            'policy_type': _type,
            'sum_insured': parseAmount(_sumInsured),
            'annual_premium': parseAmount(_premium) ?? 0,
            'insurer_name': opt(_insurer),
            'policy_number': opt(_policyNumber),
            'dependents_covered': int.tryParse(_dependents.text.trim()) ?? 0,
            'payment_frequency': _frequency,
            'payment_status': _paymentStatus,
            'next_payment_date': _nextPayment == null ? null : apiDate(_nextPayment!),
          };
          if (_isEdit) {
            await context.api.put('/insurance/${widget.existing!['id']}', body: payload);
          } else {
            await context.api.post('/insurance/', body: payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete policy?', message: 'Delete "${widget.existing!['policy_name']}"?');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.api.delete('/insurance/${widget.existing!['id']}');
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Policy deleted');
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
        TextInput(controller: _name, label: 'Policy name', required: true),
        DropdownInput<String>(label: 'Type', value: _type, items: policyTypes, onChanged: (v) => setState(() => _type = v)),
        AmountField(controller: _sumInsured, label: 'Sum insured / cover', prefix: money.symbol),
        AmountField(controller: _premium, label: 'Annual premium', prefix: money.symbol, allowZero: true),
        DropdownInput<String>(label: 'Premium frequency', value: _frequency, items: paymentFrequencies, onChanged: (v) => setState(() => _frequency = v ?? 'YEARLY')),
        DateInput(label: 'Next premium due (optional)', value: _nextPayment, required: false, onChanged: (d) => setState(() => _nextPayment = d)),
        DropdownInput<String>(label: 'Current premium status', value: _paymentStatus, items: const {'PENDING': 'Pending', 'PAID': 'Paid'}, onChanged: (v) => setState(() => _paymentStatus = v ?? 'PENDING')),
        TextInput(controller: _insurer, label: 'Insurer (optional)'),
        TextInput(controller: _policyNumber, label: 'Policy number (optional)', keyboardType: TextInputType.text),
        TextInput(controller: _dependents, label: 'Family members covered', keyboardType: TextInputType.number),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Add policy'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete policy'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}
