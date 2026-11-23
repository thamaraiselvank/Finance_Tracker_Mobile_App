import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

/// India income-tax estimator: old vs new regime, pre-filled from the user's records.
class TaxScreen extends StatefulWidget {
  const TaxScreen({super.key});

  @override
  State<TaxScreen> createState() => _TaxScreenState();
}

class _TaxScreenState extends State<TaxScreen> {
  static const _incomeFields = {
    'salary_income': 'Salary (gross, yearly)',
    'interest_income': 'Interest (bank, FD)',
    'dividend_income': 'Dividends',
    'rental_taxable_income': 'Rental income (taxable)',
    'business_taxable_income': 'Business / freelance (taxable)',
    'other_regular_income': 'Other income',
  };
  static const _deductionFields = {
    'section_80c': '80C (PPF, ELSS, LIC, tuition…)',
    'employee_pf_contribution': 'Employee PF contribution',
    'section_80d': '80D (health insurance premium)',
    'home_loan_interest_self_occupied': 'Home-loan interest (self-occupied)',
    'other_old_regime_deductions': 'Other old-regime deductions',
    'employer_nps_deduction_new': "Employer's NPS contribution",
  };

  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _age = TextEditingController(text: '30');
  final _taxPaid = TextEditingController(text: '0');
  List<String> _years = [];
  String? _year;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  String? _currencyWarning;
  final _sources = <String, String>{};
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    for (final k in [..._incomeFields.keys, ..._deductionFields.keys]) {
      _controllers[k] = TextEditingController(text: '0');
    }
    _age.text = '${toInt(context.read<AppState>().user?['current_age'], 30)}';
    _init();
  }

  @override
  void dispose() {
    for (final c in [..._controllers.values, _age, _taxPaid]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final rules = Map<String, dynamic>.from(await context.api.get('/tax/rules'));
      _years = (rules['available_tax_years'] as List? ?? [rules['tax_year']]).map((e) => e.toString()).toList();
      _year = rules['tax_year']?.toString() ?? (_years.isNotEmpty ? _years.first : null);
      await _prefill();
    } catch (e) {
      _loadError = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Suggest values from the user's own transactions, profile and policies.
  Future<void> _prefill() async {
    if (_year == null) return;
    final profile = Map<String, dynamic>.from(await context.api.get('/tax/profile', query: {'tax_year': _year}));
    _currencyWarning = profile['currency_warning']?.toString();
    _sources.clear();
    final suggestions = Map<String, dynamic>.from(profile['suggestions'] ?? {});
    suggestions.forEach((key, value) {
      if (value is Map && _controllers.containsKey(key)) {
        final v = toDouble(value['value']);
        _controllers[key]!.text = v.toStringAsFixed(0);
        if (v > 0) _sources[key] = value['source']?.toString() ?? '';
      }
    });
  }

  Future<void> _estimate() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{
        'tax_year': _year,
        'age': int.parse(_age.text.trim()),
        'tax_already_paid': toDouble(_taxPaid.text),
        for (final e in _controllers.entries) e.key: toDouble(e.value.text),
      };
      final res = await context.api.post('/tax/estimate', body: body);
      if (mounted) setState(() => _result = Map<String, dynamic>.from(res));
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Income tax estimate')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? ErrorView(message: _loadError!, onRetry: _init)
              : Form(
                  key: _formKey,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    Text('India · compares the old and new tax regimes. Amounts are yearly, in ₹.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                    if (_currencyWarning != null) ...[
                      const SizedBox(height: 8),
                      Text(_currencyWarning!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
                    ],
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(
                        child: DropdownInput<String>(
                          label: 'Tax year',
                          value: _year,
                          items: {for (final y in _years) y: 'FY $y'},
                          onChanged: (v) async {
                            setState(() {
                              _year = v;
                              _loading = true;
                            });
                            try {
                              await _prefill();
                            } catch (_) {}
                            if (mounted) setState(() => _loading = false);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 100,
                        child: TextInput(controller: _age, label: 'Age', keyboardType: TextInputType.number, validator: (v) {
                          final n = int.tryParse(v?.trim() ?? '');
                          return n == null || n < 18 || n > 120 ? '18–120' : null;
                        }),
                      ),
                    ]),
                    const SectionHeader('Income'),
                    for (final e in _incomeFields.entries) _amount(e.key, e.value),
                    const SectionHeader('Deductions (old regime)'),
                    for (final e in _deductionFields.entries) _amount(e.key, e.value),
                    const SectionHeader('Already paid'),
                    AmountField(controller: _taxPaid, label: 'TDS / advance tax paid', prefix: '₹', allowZero: true),
                    SaveButton(busy: _busy, onPressed: _estimate, label: 'Estimate my tax'),
                    if (_result != null) _TaxResult(result: _result!),
                    const SizedBox(height: 12),
                    Text(
                      'This is an estimate for planning only. Check figures against Form 16, AIS and your payslips, and consult a tax professional before filing.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ]),
                ),
    );
  }

  Widget _amount(String key, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AmountField(controller: _controllers[key]!, label: label, prefix: '₹', allowZero: true),
        if (_sources[key] != null)
          Padding(
            padding: const EdgeInsets.only(top: 0, bottom: 10, left: 4),
            child: Text('Suggested from: ${_sources[key]}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
      ]);
}

class _TaxResult extends StatelessWidget {
  const _TaxResult({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = Money('INR');
    final results = Map<String, dynamic>.from(result['results'] ?? {});
    final better = result['lower_estimate_regime']?.toString();
    Widget column(String regime) {
      final r = Map<String, dynamic>.from(results[regime] ?? {});
      final isBetter = regime == better;
      final balance = toDouble(r['estimated_balance']);
      return Expanded(
        child: Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: isBetter ? AppColors.income : theme.dividerColor, width: isBetter ? 2 : 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${regime == 'new' ? 'New' : 'Old'} regime', style: const TextStyle(fontWeight: FontWeight.w700)),
              if (isBetter) const Text('Lower tax', style: TextStyle(color: AppColors.income, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              FittedBox(child: Text(money.format(r['estimated_tax']), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
              const SizedBox(height: 6),
              _line('Taxable income', money.format(r['taxable_income'])),
              _line('Deductions', money.format(r['total_deductions'])),
              _line('Rebate 87A', money.format(r['rebate_87a'])),
              _line('Cess', money.format(r['cess'])),
              _line('Effective rate', percent(r['effective_rate_pct'])),
              _line(balance >= 0 ? 'Still to pay' : 'Refund', money.format(balance.abs())),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Result'),
      IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [column('new'), const SizedBox(width: 10), column('old')])),
      if (better != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'The ${better == 'new' ? 'new' : 'old'} regime saves about ${money.format(result['estimated_difference'])} based on these figures.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
    ]);
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}
