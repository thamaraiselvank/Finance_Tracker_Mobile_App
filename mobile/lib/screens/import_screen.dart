import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

/// Import a bank statement (CSV / Excel / PDF) into Money, or broker holdings
/// (Groww, Zerodha, Upstox, Angel One...) into Wealth. Rows are reviewed before saving.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  static const _brokers = {
    'GROWW': 'Groww',
    'ZERODHA': 'Zerodha (Console holdings)',
    'UPSTOX': 'Upstox',
    'ANGEL_ONE': 'Angel One',
    'OTHER': 'Other broker / generic CSV',
  };
  static const _brokerTips = {
    'GROWW': 'Groww app → Stocks → Holdings → ⋮ → Download holdings (Excel).',
    'ZERODHA': 'Zerodha Console → Portfolio → Holdings → Download (XLSX). Stock and mutual-fund sheets are both read.',
    'UPSTOX': 'Upstox → Portfolio → Holdings → Download / Export (CSV or Excel).',
    'ANGEL_ONE': 'Angel One → Portfolio → Holdings → Download report (Excel).',
    'OTHER': 'Any CSV/Excel with columns like: Stock Name, ISIN, Quantity, Buy Average, Buy Value, LTP, Current Value.',
  };

  final _password = TextEditingController();
  String _mode = 'transactions'; // or 'stocks'
  String _broker = 'GROWW';
  List<Map<String, dynamic>> _accounts = [];
  String? _accountId;
  PlatformFile? _file;
  bool _loadingAccounts = true;
  bool _parsing = false;
  bool _committing = false;
  Map<String, dynamic>? _parsed;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    try {
      _accounts = (await context.api.get('/accounts') as List).map((e) => Map<String, dynamic>.from(e)).toList();
      if (_accounts.length == 1) _accountId = _accounts.first['id'].toString();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
    if (mounted) setState(() => _loadingAccounts = false);
  }

  bool get _isPdf => (_file?.name.toLowerCase() ?? '').endsWith('.pdf');
  bool get _isStocks => _mode == 'stocks';

  void _setMode(String mode) => setState(() {
        _mode = mode;
        _file = null;
        _parsed = null;
        _rows = [];
        _password.clear();
      });

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: _isStocks ? const ['csv', 'xlsx', 'xls'] : const ['csv', 'xlsx', 'xls', 'pdf', 'txt']);
    if (file == null) return;
    final size = await file.length();
    if (size != null && size > 15 * 1024 * 1024) {
      if (mounted) context.showSnack('That file is larger than the 15 MB limit.', error: true);
      return;
    }
    setState(() {
      _file = file;
      _parsed = null;
      _rows = [];
    });
  }

  Future<void> _parse() async {
    if (_file == null) return;
    setState(() => _parsing = true);
    try {
      final bytes = await _file!.readAsBytes();
      if (!mounted) return;
      final res = Map<String, dynamic>.from(await context.api.postFile(
        '/import/parse-file',
        bytes: bytes,
        filename: _file!.name,
        fields: {
          'import_type': _mode,
          if (_isStocks) 'broker': _broker,
          if (!_isStocks && _isPdf && _password.text.isNotEmpty) 'password': _password.text,
        },
      ));
      setState(() {
        _parsed = res;
        _rows = (res['preview'] as List? ?? []).map((e) => {...Map<String, dynamic>.from(e), 'included': true}).toList();
      });
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  bool _invalid(Map<String, dynamic> r) =>
      !const ['INCOME', 'EXPENSE'].contains((r['type'] as String? ?? '').toUpperCase()) ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(r['date']?.toString() ?? '') ||
      (r['description']?.toString().trim() ?? '').isEmpty ||
      toDouble(r['amount']) <= 0 ||
      (r['needs_review'] == true && r['reviewed'] != true);

  List<Map<String, dynamic>> get _included => _rows.where((r) => r['included'] != false).toList();
  List<Map<String, dynamic>> get _unresolved => _isStocks ? [] : _included.where(_invalid).toList();

  Future<void> _commitHoldings() async {
    if (_included.isEmpty) {
      context.showSnack('Select at least one holding to import.', error: true);
      return;
    }
    setState(() => _committing = true);
    try {
      final res = await context.api.post('/import/commit-assets', body: {
        'assets': [
          for (final r in _included) Map<String, dynamic>.from(r)..remove('included')..remove('row_index'),
        ],
      });
      if (!mounted) return;
      context.showSnack(res is Map && res['message'] != null ? res['message'].toString() : 'Holdings imported – see the Wealth tab');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  Future<void> _commit() async {
    if (_isStocks) return _commitHoldings();
    if (_accountId == null) {
      context.showSnack('Choose the account these transactions belong to.', error: true);
      return;
    }
    if (_unresolved.isNotEmpty) {
      context.showSnack('${_unresolved.length} rows still need review – fix them, mark reviewed, or exclude them.', error: true);
      return;
    }
    setState(() => _committing = true);
    try {
      final res = await context.api.post('/import/commit', body: {
        'account_id': _accountId,
        'transactions': [
          for (final r in _included)
            {
              'date': r['date'],
              if (r['time'] != null) 'time': r['time'],
              'description': r['description'],
              'amount': toDouble(r['amount']),
              'type': (r['type'] as String).toUpperCase(),
              if ((r['category'] ?? r['category_name']) != null) 'category': r['category'] ?? r['category_name'],
              if (r['subcategory'] != null) 'subcategory': r['subcategory'],
              if ((r['category_name'] ?? r['category']) != null) 'notes': r['category_name'] ?? r['category'],
            },
        ],
      });
      if (!mounted) return;
      context.showSnack(res is Map && res['message'] != null ? res['message'].toString() : 'Import complete');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  Future<void> _editRow(int index) async {
    final updated = await showFormSheet<Map<String, dynamic>>(context, title: 'Check this row', child: _RowEditor(row: _rows[index]));
    if (updated != null) setState(() => _rows[index] = updated);
  }

  Widget _filePicker() => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _parsing ? null : _pick,
        icon: const Icon(Icons.upload_file),
        label: Text(_file == null ? (_isStocks ? 'Choose holdings file' : 'Choose statement file') : _file!.name, overflow: TextOverflow.ellipsis),
      );

  String _qty(dynamic v) {
    final d = toDouble(v);
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
  }

  List<Widget> _holdingsPreview(AppState state, ThemeData theme) {
    final included = _included;
    final invested = included.fold<double>(0, (s, r) => s + toDouble(r['invested_amount']));
    final current = included.fold<double>(0, (s, r) => s + toDouble(r['current_value']));
    final pnl = current - invested;
    final allOn = _rows.every((r) => r['included'] != false);
    return [
      SectionHeader(
        'Preview',
        trailing: TextButton(
          onPressed: () => setState(() {
            for (final r in _rows) {
              r['included'] = !allOn;
            }
          }),
          child: Text(allOn ? 'Untick all' : 'Tick all'),
        ),
      ),
      Text('Found ${_rows.length} holdings in ${_parsed!['filename'] ?? _file!.name}.'),
      if (toInt(_parsed!['parsed_rows_count']) > _rows.length)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Only the first ${_rows.length} of ${toInt(_parsed!['parsed_rows_count'])} rows can be imported at once.',
              style: const TextStyle(color: AppColors.warning)),
        ),
      const SizedBox(height: 10),
      StatGrid(children: [
        StatTile(label: 'Invested', value: state.money.compact(invested, hidden: state.hideAmounts)),
        StatTile(
          label: 'Current value',
          value: state.money.compact(current, hidden: state.hideAmounts),
          color: pnl >= 0 ? AppColors.income : AppColors.expense,
          subtitle: '${pnl >= 0 ? '+' : '−'}${state.money.compact(pnl.abs(), hidden: state.hideAmounts)}',
        ),
      ]),
      Card(
        child: Column(children: [
          for (final r in _rows)
            Builder(builder: (context) {
              final on = r['included'] != false;
              final p = toDouble(r['current_value']) - toDouble(r['invested_amount']);
              return CheckboxListTile(
                value: on,
                onChanged: (v) => setState(() => r['included'] = v),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(r['name']?.toString() ?? '—',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(decoration: on ? null : TextDecoration.lineThrough)),
                subtitle: Text('${r['sub_type'] ?? 'Stock'} • Qty ${_qty(r['quantity'])} • Invested ${state.money.compact(r['invested_amount'], hidden: state.hideAmounts)}'),
                secondary: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(state.money.compact(r['current_value'], hidden: state.hideAmounts), style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${p >= 0 ? '+' : '−'}${state.money.compact(p.abs(), hidden: state.hideAmounts)}',
                      style: TextStyle(fontSize: 12, color: p >= 0 ? AppColors.income : AppColors.expense)),
                ]),
              );
            }),
        ]),
      ),
      const SizedBox(height: 80),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Import')),
      bottomNavigationBar: _parsed == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SaveButton(busy: _committing, onPressed: _commit, label: 'Import ${_included.length} ${_isStocks ? 'holdings' : 'transactions'}'),
              ),
            ),
      body: _loadingAccounts
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'transactions', icon: Icon(Icons.account_balance_outlined), label: Text('Bank statement')),
                  ButtonSegment(value: 'stocks', icon: Icon(Icons.candlestick_chart_outlined), label: Text('Stocks & holdings')),
                ],
                selected: {_mode},
                onSelectionChanged: _parsing || _committing ? null : (s) => _setMode(s.first),
              ),
              const SizedBox(height: 12),
              Text(
                _isStocks
                    ? 'Upload the holdings file (CSV or Excel) from your broker. Your stocks and funds are added to Wealth. You can untick any holding before importing.'
                    : 'Upload a CSV, Excel or PDF bank statement. Transactions are added to Money. You can review and correct every row before anything is saved.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 16),
              if (_isStocks) ...[
                DropdownInput<String>(
                  label: 'Broker',
                  value: _broker,
                  items: _brokers,
                  onChanged: (v) => setState(() {
                    _broker = v ?? 'OTHER';
                    _parsed = null;
                    _rows = [];
                  }),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lightbulb_outline),
                    title: const Text('Where to get the file'),
                    subtitle: Text(_brokerTips[_broker]!),
                  ),
                ),
                const SizedBox(height: 14),
                _filePicker(),
                if (_file != null && _parsed == null) ...[
                  const SizedBox(height: 8),
                  SaveButton(busy: _parsing, onPressed: _parse, label: 'Read & preview holdings'),
                ],
              ] else if (_accounts.isEmpty)
                const EmptyState(icon: Icons.account_balance_outlined, title: 'Add an account first', message: 'Imported transactions are added to one of your accounts.')
              else ...[
                DropdownInput<String>(
                  label: 'Add transactions to account',
                  value: _accountId,
                  items: {for (final a in _accounts) a['id'].toString(): a['name'].toString()},
                  onChanged: (v) => setState(() => _accountId = v),
                ),
                _filePicker(),
                if (_isPdf) ...[
                  const SizedBox(height: 12),
                  TextInput(controller: _password, label: 'PDF password (if any – not stored)', obscure: true, keyboardType: TextInputType.visiblePassword),
                ],
                if (_file != null && _parsed == null) ...[
                  const SizedBox(height: 8),
                  SaveButton(busy: _parsing, onPressed: _parse, label: 'Read & preview'),
                  if (_parsing && _isPdf)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text('Scanned PDFs can take up to a minute to read.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall)),
                ],
              ],
              if (_parsed != null && _isStocks) ..._holdingsPreview(state, theme),
              if (_parsed != null && !_isStocks) ...[
                const SectionHeader('Preview'),
                Text('Found ${_rows.length} transactions in ${_parsed!['filename'] ?? _file!.name}.'),
                if (_parsed!['review_notice'] != null)
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text(_parsed!['review_notice'].toString(), style: const TextStyle(color: AppColors.warning))),
                if (_unresolved.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('${_unresolved.length} rows need your review (marked orange). Tap a row to check it, or untick it to skip.', style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w600)),
                  ),
                const SizedBox(height: 8),
                Card(
                  child: Column(children: [
                    for (var i = 0; i < _rows.length; i++)
                      Builder(builder: (context) {
                        final r = _rows[i];
                        final included = r['included'] != false;
                        final bad = included && _invalid(r);
                        final isIncome = (r['type'] as String? ?? '').toUpperCase() == 'INCOME';
                        return ListTile(
                          onTap: () => _editRow(i),
                          tileColor: bad ? AppColors.warning.withValues(alpha: 0.08) : null,
                          leading: Checkbox(value: included, onChanged: (v) => setState(() => r['included'] = v)),
                          title: Text(r['description']?.toString() ?? '—', maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: TextStyle(decoration: included ? null : TextDecoration.lineThrough)),
                          subtitle: Text([r['date'] ?? '?', r['category_name'] ?? r['category'], if (bad) 'Needs review'].where((e) => e != null).join(' • '),
                              style: TextStyle(color: bad ? AppColors.warning : null)),
                          trailing: Text(
                            '${(r['type'] == null) ? '?' : (isIncome ? '+' : '−')}${state.money.format(r['amount'], hidden: state.hideAmounts)}',
                            style: TextStyle(fontWeight: FontWeight.w700, color: isIncome ? AppColors.income : null),
                          ),
                        );
                      }),
                  ]),
                ),
                const SizedBox(height: 80),
              ],
            ]),
    );
  }
}

class _RowEditor extends StatefulWidget {
  const _RowEditor({required this.row});
  final Map<String, dynamic> row;

  @override
  State<_RowEditor> createState() => _RowEditorState();
}

class _RowEditorState extends State<_RowEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _description, _amount;
  String? _type;
  DateTime? _date;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.row['description']?.toString() ?? '');
    _amount = TextEditingController(text: toDouble(widget.row['amount']) > 0 ? toDouble(widget.row['amount']).toString() : '');
    final t = (widget.row['type'] as String?)?.toUpperCase();
    _type = (t == 'INCOME' || t == 'EXPENSE') ? t : null;
    _date = toDate(widget.row['date']);
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final money = context.read<AppState>().money;
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownInput<String>(label: 'Type', value: _type, items: const {'EXPENSE': 'Expense (money out)', 'INCOME': 'Income (money in)'}, onChanged: (v) => setState(() => _type = v)),
        TextInput(controller: _description, label: 'Description', required: true),
        AmountField(controller: _amount, label: 'Amount', prefix: money.symbol),
        DateInput(label: 'Date', value: _date, onChanged: (d) => setState(() => _date = d)),
        SaveButton(
          busy: false,
          label: 'Looks right – mark reviewed',
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(context, {
              ...widget.row,
              'type': _type,
              'description': _description.text.trim(),
              'amount': double.parse(_amount.text),
              'date': apiDate(_date!),
              'reviewed': true,
              'included': true,
            });
          },
        ),
      ]),
    );
  }
}
