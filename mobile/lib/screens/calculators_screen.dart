import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/pro.dart';
import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';

/// One numeric input of a calculator.
class _Field {
  final String key;
  final String label;
  final String initial;
  final bool money;
  final bool integer;
  final String? suffix;
  const _Field(
    this.key,
    this.label,
    this.initial, {
    this.money = false,
    this.integer = false,
    this.suffix,
  });
}

/// A calculator definition: inputs, which calculation, and how to render results.
class _CalcDef {
  final String title;
  final String subtitle;
  final IconData icon;
  final CalculatorKind kind;
  final List<_Field> fields;
  final List<(String, String, bool)> Function(Map<String, dynamic> r)
  results; // label, key/value, isMoney
  const _CalcDef(
    this.title,
    this.subtitle,
    this.icon,
    this.kind,
    this.fields,
    this.results,
  );
}

List<_CalcDef> _calculators(Map<String, dynamic>? user) => [
  _CalcDef(
    'SIP',
    'Monthly investment growth',
    Icons.trending_up,
    CalculatorKind.sip,
    const [
      _Field('monthly_investment', 'Monthly investment', '10000', money: true),
      _Field(
        'expected_return_rate_pct',
        'Expected return',
        '12',
        suffix: '% p.a.',
      ),
      _Field(
        'time_period_years',
        'Time period',
        '10',
        integer: true,
        suffix: 'years',
      ),
      _Field('annual_step_up_pct', 'Annual step-up', '0', suffix: '%'),
    ],
    (r) => [
      ('Total invested', 'total_invested', true),
      ('Estimated returns', 'estimated_returns', true),
      ('Total value', 'total_value', true),
    ],
  ),
  _CalcDef(
    'Lumpsum',
    'One-time investment growth',
    Icons.savings_outlined,
    CalculatorKind.lumpsum,
    const [
      _Field('total_investment', 'Investment amount', '100000', money: true),
      _Field(
        'expected_return_rate_pct',
        'Expected return',
        '12',
        suffix: '% p.a.',
      ),
      _Field(
        'time_period_years',
        'Time period',
        '10',
        integer: true,
        suffix: 'years',
      ),
    ],
    (r) => [
      ('Invested', 'total_invested', true),
      ('Estimated returns', 'estimated_returns', true),
      ('Total value', 'total_value', true),
    ],
  ),
  _CalcDef(
    'EMI',
    'Loan instalment & interest',
    Icons.request_quote_outlined,
    CalculatorKind.emi,
    const [
      _Field('loan_amount', 'Loan amount', '2500000', money: true),
      _Field('interest_rate_pct', 'Interest rate', '8.5', suffix: '% p.a.'),
      _Field('tenure_months', 'Tenure', '240', integer: true, suffix: 'months'),
    ],
    (r) => [
      ('Monthly EMI', 'monthly_emi', true),
      ('Total interest', 'total_interest', true),
      ('Total payment', 'total_payment', true),
    ],
  ),
  _CalcDef(
    'CAGR',
    'Annualised growth rate',
    Icons.show_chart,
    CalculatorKind.cagr,
    const [
      _Field('initial_value', 'Initial value', '100000', money: true),
      _Field('final_value', 'Final value', '200000', money: true),
      _Field('duration_years', 'Duration', '5', suffix: 'years'),
    ],
    (r) => [
      ('CAGR', '${toDouble(r['cagr_percentage']).toStringAsFixed(2)}%', false),
      (
        'Absolute growth',
        '${toDouble(r['absolute_growth_percentage']).toStringAsFixed(2)}%',
        false,
      ),
      ('Total gain', 'total_gain', true),
    ],
  ),
  _CalcDef(
    'FIRE',
    'Financial independence / retirement',
    Icons.local_fire_department_outlined,
    CalculatorKind.fire,
    [
      _Field(
        'current_age',
        'Current age',
        '${toInt(user?['current_age'], 28)}',
        integer: true,
      ),
      _Field(
        'target_retirement_age',
        'Target retirement age',
        '${toInt(user?['target_retirement_age'], 50)}',
        integer: true,
      ),
      _Field(
        'monthly_expense',
        'Monthly expenses today',
        toDouble(user?['monthly_expense']) > 0
            ? toDouble(user?['monthly_expense']).toStringAsFixed(0)
            : '50000',
        money: true,
      ),
      const _Field(
        'current_portfolio_value',
        'Current investments',
        '0',
        money: true,
      ),
      const _Field(
        'existing_monthly_investment',
        'Monthly investment',
        '0',
        money: true,
      ),
      const _Field(
        'expected_pre_retire_return_pct',
        'Return before retirement',
        '12',
        suffix: '%',
      ),
      const _Field('expected_inflation_pct', 'Inflation', '6', suffix: '%'),
    ],
    (r) => [
      ('Corpus needed (FIRE)', 'standard_fire_corpus', true),
      (
        'Projected corpus at target age',
        'projected_corpus_at_retire_age',
        true,
      ),
      (
        toDouble(r['shortfall_or_surplus']) >= 0 ? 'Surplus' : 'Shortfall',
        '${toDouble(r['shortfall_or_surplus']).abs()}',
        true,
      ),
      ('Extra monthly SIP needed', 'required_monthly_sip', true),
      (
        'Can retire at target age?',
        r['can_retire_at_target_age'] == true ? 'Yes' : 'Not yet',
        false,
      ),
      ('Estimated FIRE age', '${toInt(r['estimated_fire_age'])}', false),
    ],
  ),
];

class CalculatorsScreen extends StatelessWidget {
  const CalculatorsScreen({super.key});

  /// SIP, lumpsum and EMI are free; the rest are Pro.
  static bool _isPro(CalculatorKind kind) => kind == CalculatorKind.cagr || kind == CalculatorKind.fire;

  @override
  Widget build(BuildContext context) {
    final calcs = _calculators(context.read<AppState>().user);
    return Scaffold(
      appBar: AppBar(title: const Text('Calculators')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                for (final c in calcs)
                  ListTile(
                    leading: CircleAvatar(child: Icon(c.icon, size: 20)),
                    title: Text(
                      c.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(c.subtitle),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_isPro(c.kind)) const ProBadge(),
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _isPro(c.kind)
                            ? ProGate(feature: ProFeature.calculators, child: _CalculatorPage(def: c))
                            : _CalculatorPage(def: c),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CalculatorPage extends StatefulWidget {
  const _CalculatorPage({required this.def});
  final _CalcDef def;

  @override
  State<_CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<_CalculatorPage> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers = {
    for (final f in widget.def.fields)
      f.key: TextEditingController(text: f.initial),
  };
  Map<String, dynamic>? _result;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _calculate() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final body = {
        for (final f in widget.def.fields)
          f.key: f.integer
              ? int.parse(_controllers[f.key]!.text.trim())
              : double.parse(_controllers[f.key]!.text.trim()),
      };
      final res = await context.services.calculators.calculate(widget.def.kind, body);
      if (mounted) setState(() => _result = res);
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.def.title} calculator')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final f in widget.def.fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _controllers[f.key],
                      keyboardType: TextInputType.numberWithOptions(
                        decimal: !f.integer,
                      ),
                      decoration: InputDecoration(
                        labelText: f.label,
                        prefixText: f.money ? '${state.money.symbol} ' : null,
                        suffixText: f.suffix,
                      ),
                      validator: (v) {
                        final t = v?.trim() ?? '';
                        if (t.isEmpty) return 'Required';
                        final n = f.integer
                            ? int.tryParse(t)
                            : double.tryParse(t);
                        if (n == null) {
                          return f.integer ? 'Enter a whole number' : 'Enter a number';
                          }
                        if (n < 0) return 'Cannot be negative';
                        return null;
                      },
                    ),
                    if (f.money)
                      AmountWords(
                        controller: _controllers[f.key]!,
                        currency: state.money.code,
                      ),
                  ],
                ),
              ),
            SaveButton(busy: _busy, onPressed: _calculate, label: 'Calculate'),
            if (_result != null) ...[
              const SectionHeader('Result'),
              Card(
                child: Column(
                  children: [
                    for (final (label, keyOrValue, isMoney)
                        in widget.def.results(_result!))
                      ListTile(
                        title: Text(label),
                        trailing: Text(
                          isMoney
                              ? state.money.format(
                                  _result!.containsKey(keyOrValue)
                                      ? _result![keyOrValue]
                                      : toDouble(keyOrValue),
                                )
                              : (_result!.containsKey(keyOrValue)
                                    ? _result![keyOrValue].toString()
                                    : keyOrValue),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.brand,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
