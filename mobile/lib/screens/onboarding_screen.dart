import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../widgets/common.dart';

/// 3-step setup shown to new users, mirroring the web onboarding.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  int _step = 0;
  bool _busy = false;
  late String _currency;
  late final TextEditingController _name, _income, _expense, _emergency, _age, _retireAge, _dependents;
  double _savingsRate = 30;

  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user ?? {};
    String amt(dynamic v) => toDouble(v) > 0 ? toDouble(v).toStringAsFixed(0) : '';
    _currency = (u['currency'] as String?) ?? 'INR';
    _name = TextEditingController(text: (u['full_name'] as String?)?.trim() ?? '');
    _income = TextEditingController(text: amt(u['monthly_income']));
    _expense = TextEditingController(text: amt(u['monthly_expense']));
    _emergency = TextEditingController(text: amt(u['emergency_fund_amount']));
    _age = TextEditingController(text: '${toInt(u['current_age'], 28)}');
    _retireAge = TextEditingController(text: '${toInt(u['target_retirement_age'], 50)}');
    _dependents = TextEditingController(text: '${toInt(u['dependents_count'])}');
    _savingsRate = toDouble(u['target_savings_rate'], 30).clamp(0, 90);
  }

  @override
  void dispose() {
    for (final c in [_name, _income, _expense, _emergency, _age, _retireAge, _dependents]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _next() async {
    if (!_formKey.currentState!.validate()) return;
    if (_step < 2) {
      setState(() => _step++);
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppState>().updateProfile({
        'full_name': _name.text.trim(),
        'currency': _currency,
        'monthly_income': toDouble(_income.text),
        'monthly_expense': toDouble(_expense.text),
        'emergency_fund_amount': toDouble(_emergency.text),
        'current_age': toInt(_age.text, 28),
        'target_retirement_age': toInt(_retireAge.text, 50),
        'dependents_count': toInt(_dependents.text),
        'target_savings_rate': _savingsRate,
        'is_onboarded': true,
      });
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _ageValidator(String? v) {
    final n = int.tryParse(v ?? '');
    if (n == null || n < 18 || n > 80) return 'Enter an age between 18 and 80';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbol = Money(_currency).symbol;
    final steps = [
      Column(children: [
        TextInput(
          controller: _name,
          label: 'Your name',
          required: true,
          keyboardType: TextInputType.name,
          textCapitalization: TextCapitalization.words,
        ),
        DropdownInput<String>(
          label: 'Currency',
          value: _currency,
          items: const {'INR': '₹ Indian Rupee', 'USD': r'$ US Dollar', 'EUR': '€ Euro', 'GBP': '£ British Pound'},
          onChanged: (v) => setState(() => _currency = v ?? 'INR'),
        ),
        AmountField(controller: _income, label: 'Monthly take-home income', prefix: symbol),
        AmountField(controller: _expense, label: 'Monthly expenses', prefix: symbol, required: false),
      ]),
      Column(children: [
        TextInput(controller: _age, label: 'Your current age', keyboardType: TextInputType.number, validator: _ageValidator),
        TextInput(
          controller: _retireAge,
          label: 'Target retirement age',
          keyboardType: TextInputType.number,
          validator: (v) {
            final base = _ageValidator(v);
            if (base != null) return base;
            if (int.parse(v!) <= (int.tryParse(_age.text) ?? 0)) return 'Must be greater than your current age';
            return null;
          },
        ),
        TextInput(controller: _dependents, label: 'Number of dependents', keyboardType: TextInputType.number),
      ]),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AmountField(controller: _emergency, label: 'Current emergency fund', prefix: symbol, required: false),
        Text('Target savings rate: ${_savingsRate.round()}%', style: theme.textTheme.titleSmall),
        Slider(value: _savingsRate, min: 0, max: 90, divisions: 18, label: '${_savingsRate.round()}%', onChanged: (v) => setState(() => _savingsRate = v)),
      ]),
    ];
    const titles = ['About you', 'Age & retirement', 'Safety net & savings'];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Let's personalise Finverse"),
        actions: [
          if (!context.read<AppState>().isLocal)
            TextButton(onPressed: () => context.read<AppState>().signOut(), child: const Text('Sign out')),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Text('Step ${_step + 1} of 3', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            Text(titles[_step], style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            ProgressBar(value: (_step + 1) / 3),
            const SizedBox(height: 24),
            steps[_step],
            const SizedBox(height: 8),
            Row(children: [
              if (_step > 0) ...[
                Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)), onPressed: _busy ? null : () => setState(() => _step--), child: const Text('Back'))),
                const SizedBox(width: 12),
              ],
              Expanded(child: SaveButton(busy: _busy, onPressed: _next, label: _step == 2 ? 'Finish' : 'Next')),
            ]),
          ]),
        ),
      ),
    );
  }
}
