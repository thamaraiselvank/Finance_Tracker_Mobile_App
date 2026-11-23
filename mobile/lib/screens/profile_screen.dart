import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_lock.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../widgets/common.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _income, _expense, _emergency, _age, _retireAge, _dependents, _savingsRate;
  late String _currency;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user ?? {};
    String amt(dynamic v) => toDouble(v).toStringAsFixed(0);
    _name = TextEditingController(text: u['full_name']?.toString() ?? '');
    _income = TextEditingController(text: amt(u['monthly_income']));
    _expense = TextEditingController(text: amt(u['monthly_expense']));
    _emergency = TextEditingController(text: amt(u['emergency_fund_amount']));
    _age = TextEditingController(text: '${toInt(u['current_age'], 28)}');
    _retireAge = TextEditingController(text: '${toInt(u['target_retirement_age'], 50)}');
    _dependents = TextEditingController(text: '${toInt(u['dependents_count'])}');
    _savingsRate = TextEditingController(text: amt(u['target_savings_rate']));
    _currency = u['currency']?.toString() ?? 'INR';
  }

  @override
  void dispose() {
    for (final c in [_name, _income, _expense, _emergency, _age, _retireAge, _dependents, _savingsRate]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
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
        'target_savings_rate': toDouble(_savingsRate.text, 30),
      });
      if (mounted) context.showSnack('Profile saved');
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _intValidator(String? v) => int.tryParse(v?.trim() ?? '') == null ? 'Enter a whole number' : null;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final symbol = Money(_currency).symbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (state.isLocal)
            const _LocalDataCard()
          else
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(state.displayName.isNotEmpty ? state.displayName[0].toUpperCase() : '?')),
                title: Text(state.user?['username']?.toString() ?? ''),
                subtitle: Text(state.user?['email']?.toString() ?? ''),
              ),
            ),
          const SectionHeader('Personal details'),
          TextInput(controller: _name, label: 'Full name'),
          DropdownInput<String>(
            label: 'Currency',
            value: _currency,
            items: const {'INR': '₹ Indian Rupee', 'USD': r'$ US Dollar', 'EUR': '€ Euro', 'GBP': '£ British Pound'},
            onChanged: (v) => setState(() => _currency = v ?? 'INR'),
          ),
          TextInput(controller: _age, label: 'Current age', keyboardType: TextInputType.number, validator: _intValidator),
          TextInput(controller: _retireAge, label: 'Target retirement age', keyboardType: TextInputType.number, validator: _intValidator),
          TextInput(controller: _dependents, label: 'Dependents', keyboardType: TextInputType.number, validator: _intValidator),
          const SectionHeader('Monthly finances'),
          AmountField(controller: _income, label: 'Monthly income', prefix: symbol, allowZero: true),
          AmountField(controller: _expense, label: 'Monthly expenses', prefix: symbol, allowZero: true),
          AmountField(controller: _emergency, label: 'Emergency fund', prefix: symbol, allowZero: true),
          AmountField(controller: _savingsRate, label: 'Target savings rate', suffix: '%', allowZero: true),
          SaveButton(busy: _busy, onPressed: _save, label: 'Save profile'),
          if (!state.isLocal) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => showFormSheet(context, title: 'Change password', child: const _ChangePasswordForm()),
              icon: const Icon(Icons.lock_outline),
              label: const Text('Change password'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Phone-only version: explains where data lives and offers the app lock.
class _LocalDataCard extends StatefulWidget {
  const _LocalDataCard();

  @override
  State<_LocalDataCard> createState() => _LocalDataCardState();
}

class _LocalDataCardState extends State<_LocalDataCard> {
  bool _busy = false;

  Future<void> _toggle(AppLock lock, bool value) async {
    setState(() => _busy = true);
    try {
      await lock.setEnabled(value);
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    return Card(
      child: Column(children: [
        const ListTile(
          leading: CircleAvatar(child: Icon(Icons.phone_android)),
          title: Text('Your data stays on this phone'),
          subtitle: Text('Stored encrypted on this device only. No account, no server.'),
        ),
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint),
          title: const Text('App lock'),
          subtitle: const Text('Ask for fingerprint, face or phone PIN when opening Finverse'),
          value: lock.enabled,
          onChanged: _busy ? null : (v) => _toggle(lock, v),
        ),
      ]),
    );
  }
}

class _ChangePasswordForm extends StatefulWidget {
  const _ChangePasswordForm();

  @override
  State<_ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends State<_ChangePasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextInput(controller: _old, label: 'Current password', obscure: true, keyboardType: TextInputType.visiblePassword, required: true),
        TextInput(
          controller: _new,
          label: 'New password',
          obscure: true,
          keyboardType: TextInputType.visiblePassword,
          validator: (v) => (v == null || v.length < 6) ? 'At least 6 characters' : null,
        ),
        TextInput(
          controller: _confirm,
          label: 'Confirm new password',
          obscure: true,
          keyboardType: TextInputType.visiblePassword,
          validator: (v) => v != _new.text ? 'Passwords do not match' : null,
        ),
        SaveButton(
          busy: _busy,
          label: 'Update password',
          onPressed: () => runSave(
            context,
            formKey: _formKey,
            setBusy: (b) => setState(() => _busy = b),
            successMessage: 'Password changed',
            action: () => context.read<AppState>().changePassword(_old.text, _new.text),
          ),
        ),
      ]),
    );
  }
}
