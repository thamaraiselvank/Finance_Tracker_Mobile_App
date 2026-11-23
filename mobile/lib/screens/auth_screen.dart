import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../main.dart';
import '../widgets/common.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _fullName = TextEditingController();
  final _password = TextEditingController();
  bool _isLogin = true;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_identifier, _email, _username, _fullName, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = context.read<AppState>();
    try {
      if (_isLogin) {
        await state.login(_identifier.text, _password.text);
      } else {
        await state.register({
          'email': _email.text.trim(),
          'username': _username.text.trim(),
          'password': _password.text,
          if (_fullName.text.trim().isNotEmpty) 'full_name': _fullName.text.trim(),
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionMessage = context.watch<AppState>().sessionMessage;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Center(child: FinverseLogo(size: 64)),
                  const SizedBox(height: 16),
                  Text('Finverse', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    _isLogin ? 'Sign in to your finance workspace' : 'Create your account',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 28),
                  if (sessionMessage != null && _isLogin) _Banner(text: sessionMessage, color: theme.colorScheme.tertiary),
                  if (_error != null) _Banner(text: _error!, color: theme.colorScheme.error),
                  if (_isLogin)
                    TextInput(controller: _identifier, label: 'Username or email', required: true, keyboardType: TextInputType.emailAddress)
                  else ...[
                    TextInput(controller: _fullName, label: 'Full name (optional)'),
                    TextInput(
                      controller: _email,
                      label: 'Email',
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) => (v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) ? 'Enter a valid email' : null,
                    ),
                    TextInput(
                      controller: _username,
                      label: 'Username',
                      keyboardType: TextInputType.text,
                      validator: (v) => (v == null || v.trim().length < 3) ? 'At least 3 characters' : null,
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextFormField(
                      controller: _password,
                      obscureText: !_showPassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      onFieldSubmitted: (_) => _submit(),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        if (!_isLogin && v.length < 6) return 'At least 6 characters';
                        return null;
                      },
                    ),
                  ),
                  SaveButton(busy: _busy, onPressed: _submit, label: _isLogin ? 'Sign in' : 'Create account'),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : () => setState(() { _isLogin = !_isLogin; _error = null; }),
                    child: Text(_isLogin ? "Don't have an account? Create one" : 'Already have an account? Sign in'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
