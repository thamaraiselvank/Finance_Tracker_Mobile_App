import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../widgets/common.dart';
import 'budgets_tab.dart';
import 'home_shell.dart';
import 'transactions_tab.dart';

const accountTypes = {
  'SAVINGS': 'Savings',
  'CURRENT': 'Current',
  'CREDIT_CARD': 'Credit card',
  'WALLET': 'Wallet / Cash',
  'FIXED_DEPOSIT': 'Fixed deposit',
  'INVESTMENT': 'Investment',
  'OTHER': 'Other',
};

class MoneyScreen extends StatelessWidget {
  const MoneyScreen({super.key, this.initialTab = 0});

  /// 0 Transactions, 1 Budgets, 2 Accounts.
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: const Scaffold(
        appBar: AppScaffoldBar(
          title: 'Money',
          bottom: TabBar(tabs: [Tab(text: 'Transactions'), Tab(text: 'Budgets'), Tab(text: 'Accounts')]),
        ),
        body: TabBarView(children: [TransactionsTab(), BudgetsTab(), AccountsTab()]),
      ),
    );
  }
}

class AppScaffoldBar extends StatelessWidget implements PreferredSizeWidget {
  const AppScaffoldBar({super.key, required this.title, this.bottom, this.actions = const []});
  final String title;
  final PreferredSizeWidget? bottom;

  /// Shown before the hide-amounts button.
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(title: Text(title), actions: [...actions, const HideAmountsButton()], bottom: bottom);
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

class TransactionForm extends StatefulWidget {
  const TransactionForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<TransactionForm> createState() => _TransactionFormState();
}

class _TransactionFormState extends State<TransactionForm> {
  final _formKey = GlobalKey<FormState>();
  late String _type;
  String? _accountId, _categoryId, _subcategoryId;
  late DateTime _date;
  late final TextEditingController _amount, _description, _notes;
  bool _busy = false;
  bool _loadingOptions = true;
  String? _optionsError;
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _categories = [];

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _type = (e['type'] as String?)?.toUpperCase() ?? 'EXPENSE';
    _accountId = e['account_id']?.toString();
    _categoryId = e['category_id']?.toString();
    _subcategoryId = e['subcategory_id']?.toString();
    _date = toDate(e['date']) ?? DateTime.now();
    _amount = TextEditingController(text: e['amount'] != null ? _trim(toDouble(e['amount'])) : '');
    _description = TextEditingController(text: e['description']?.toString() ?? '');
    _notes = TextEditingController(text: e['notes']?.toString() ?? '');
    _loadOptions();
  }

  String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _loadingOptions = true;
      _optionsError = null;
    });
    try {
      final s = context.services;
      final results = await Future.wait([s.accounts.list(), s.categories.list()]);
      if (!mounted) return;
      setState(() {
        _accounts = results[0];
        _categories = results[1];
        if (_accountId == null && _accounts.length == 1) _accountId = _accounts.first['id'].toString();
        _loadingOptions = false;
      });
    } catch (e) {
      if (mounted) setState(() { _optionsError = e.toString(); _loadingOptions = false; });
    }
  }

  List<Map<String, dynamic>> get _typeCategories =>
      _categories.where((c) => (c['type'] as String?)?.toUpperCase() == _type).toList();

  List<Map<String, dynamic>> get _subcategories {
    final cat = _categories.where((c) => c['id'].toString() == _categoryId).firstOrNull;
    return (cat?['subcategories'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Transaction updated' : 'Transaction added',
        action: () async {
          final payload = {
            'type': _type,
            'account_id': _accountId,
            'category_id': _categoryId,
            'subcategory_id': _subcategoryId,
            'amount': parseAmount(_amount),
            'date': apiDate(_date),
            'description': _description.text.trim(),
            'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          };
          if (_isEdit) {
            await context.services.transactions.update(widget.existing!['id'].toString(), payload);
          } else {
            await context.services.transactions.create(payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete transaction?', message: 'This will also reverse its effect on the account balance.');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.services.transactions.delete(widget.existing!['id'].toString());
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Transaction deleted');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        context.showSnack(e.toString(), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingOptions) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
    if (_optionsError != null) return ErrorView(message: _optionsError!, onRetry: _loadOptions);
    if (_accounts.isEmpty) {
      return const EmptyState(
        icon: Icons.account_balance_outlined,
        title: 'Add an account first',
        message: 'Every transaction belongs to an account. Create one in Money → Accounts, then come back.',
      );
    }
    final money = context.read<AppState>().money;
    final isTransfer = _type == 'TRANSFER';
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'EXPENSE', label: Text('Expense')),
              const ButtonSegment(value: 'INCOME', label: Text('Income')),
              if (isTransfer) const ButtonSegment(value: 'TRANSFER', label: Text('Transfer')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _categoryId = null;
              _subcategoryId = null;
            }),
          ),
        ),
        AmountField(controller: _amount, label: 'Amount', prefix: money.symbol),
        TextInput(controller: _description, label: 'Description', required: true),
        DropdownInput<String>(
          label: 'Account',
          value: _accountId,
          items: {for (final a in _accounts) a['id'].toString(): a['name'].toString()},
          onChanged: (v) => setState(() => _accountId = v),
        ),
        DropdownInput<String>(
          key: ValueKey('cat-$_type'),
          label: 'Category',
          value: _categoryId,
          required: false,
          items: {for (final c in _typeCategories) c['id'].toString(): c['name'].toString()},
          onChanged: (v) => setState(() {
            _categoryId = v;
            _subcategoryId = null;
          }),
        ),
        if (_subcategories.isNotEmpty)
          DropdownInput<String>(
            key: ValueKey('sub-$_categoryId'),
            label: 'Subcategory',
            value: _subcategoryId,
            required: false,
            items: {for (final s in _subcategories) s['id'].toString(): s['name'].toString()},
            onChanged: (v) => setState(() => _subcategoryId = v),
          ),
        DateInput(label: 'Date', value: _date, lastDate: DateTime.now().add(const Duration(days: 365)), onChanged: (d) => setState(() => _date = d ?? _date)),
        TextInput(controller: _notes, label: 'Notes (optional)', maxLines: 2),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Add transaction'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete transaction'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

class AccountsTab extends StatefulWidget {
  const AccountsTab({super.key});

  @override
  State<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<AccountsTab> with AutomaticKeepAliveClientMixin {
  final _viewKey = GlobalKey<AsyncViewState<List<Map<String, dynamic>>>>();

  @override
  bool get wantKeepAlive => true;

  Future<List<Map<String, dynamic>>> _load() => context.services.accounts.list();

  Future<void> _openForm([Map<String, dynamic>? account]) async {
    final saved = await showFormSheet<bool>(context,
        title: account == null ? 'Add account' : 'Edit account', child: AccountForm(existing: account));
    if (saved == true) _viewKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Account')),
      body: AsyncView<List<Map<String, dynamic>>>(
        key: _viewKey,
        load: _load,
        builder: (context, accounts, reload) {
          final total = accounts.where((a) => a['is_active'] != false).fold<double>(0, (s, a) => s + toDouble(a['balance']));
          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
            StatTile(label: 'Total balance (active accounts)', value: state.money.format(total, hidden: state.hideAmounts), icon: Icons.account_balance_wallet_outlined),
            const SizedBox(height: 12),
            if (accounts.isEmpty)
              EmptyState(
                icon: Icons.account_balance_outlined,
                title: 'No accounts yet',
                message: 'Add your bank accounts, cards and wallets to start tracking.',
                action: FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Add account')),
              )
            else
              Card(
                child: Column(children: [
                  for (final a in accounts)
                    ListTile(
                      onTap: () => _openForm(a),
                      leading: CircleAvatar(child: Icon(_accountIcon(a['account_type']?.toString()), size: 20)),
                      title: Text(a['name'].toString()),
                      subtitle: Text([accountTypes[a['account_type']] ?? humanize(a['account_type']), if (a['institution'] != null) a['institution'], if (a['is_active'] == false) 'Inactive'].join(' • ')),
                      trailing: MoneyText(a['balance'], style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                ]),
              ),
          ]);
        },
      ),
    );
  }

  IconData _accountIcon(String? type) => switch (type) {
        'CREDIT_CARD' => Icons.credit_card,
        'WALLET' => Icons.account_balance_wallet_outlined,
        'FIXED_DEPOSIT' => Icons.lock_clock_outlined,
        'INVESTMENT' => Icons.trending_up,
        _ => Icons.account_balance_outlined,
      };
}

class AccountForm extends StatefulWidget {
  const AccountForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<AccountForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _institution, _balance;
  late String? _type;
  late bool _active;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _name = TextEditingController(text: e['name']?.toString() ?? '');
    _institution = TextEditingController(text: e['institution']?.toString() ?? '');
    _balance = TextEditingController(text: e['balance'] != null ? toDouble(e['balance']).toStringAsFixed(2) : '');
    _type = e['account_type']?.toString() ?? 'SAVINGS';
    _active = e['is_active'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _institution.dispose();
    _balance.dispose();
    super.dispose();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Account updated' : 'Account added',
        action: () async {
          final payload = {
            'name': _name.text.trim(),
            'account_type': _type,
            'balance': parseAmount(_balance) ?? 0,
            'institution': _institution.text.trim().isEmpty ? null : _institution.text.trim(),
            'is_active': _active,
          };
          if (_isEdit) {
            await context.services.accounts.update(widget.existing!['id'].toString(), payload);
          } else {
            await context.services.accounts.create(payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context,
        title: 'Delete account?',
        message: 'This permanently deletes "${widget.existing!['name']}" AND all transactions linked to it. This cannot be undone.');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.services.accounts.delete(widget.existing!['id'].toString());
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Account deleted');
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
        TextInput(controller: _name, label: 'Account name', required: true),
        DropdownInput<String>(label: 'Type', value: _type, items: accountTypes, onChanged: (v) => setState(() => _type = v)),
        TextInput(controller: _institution, label: 'Bank / institution (optional)'),
        AmountField(controller: _balance, label: 'Current balance', prefix: money.symbol, allowZero: true),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: _active, onChanged: (v) => setState(() => _active = v)),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Add account'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete account'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}
