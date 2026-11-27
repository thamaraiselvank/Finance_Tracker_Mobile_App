import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../export/export_data.dart' show ExportSection;
import 'export_screen.dart' show ExportButton;
import 'money_screen.dart' show AppScaffoldBar;
import 'schedules_screen.dart' show markOccurrenceDone;
import 'wealth_overview.dart';

const assetClasses = {
  'EQUITY': 'Stocks / Equity',
  'MUTUAL_FUND': 'Mutual funds',
  'COMMODITY_GOLD': 'Gold',
  'REAL_ESTATE': 'Real estate',
  'CASH_EQUIVALENT': 'Cash equivalent',
  'FIXED_INCOME': 'Fixed income (FD, bonds, PPF)',
  'CRYPTO': 'Crypto',
  'OTHER': 'Other',
};

/// Regular income a holding can pay.
const incomeKinds = {'DIVIDEND': 'Dividend', 'INTEREST': 'Interest', 'RENTAL_INCOME': 'Rent', 'OTHER': 'Other income'};

/// How often it pays: label -> (frequency, interval).
const incomeFrequencies = {
  'Every month': ('MONTHLY', 1),
  'Every 3 months': ('QUARTERLY', 1),
  'Every 6 months': ('MONTHLY', 6),
  'Every year': ('YEARLY', 1),
};

String incomeFrequencyLabel(String? frequency, int interval) {
  for (final e in incomeFrequencies.entries) {
    if (e.value.$1 == frequency && e.value.$2 == interval) return e.key;
  }
  return switch (frequency) {
    'WEEKLY' => interval == 1 ? 'Every week' : 'Every $interval weeks',
    'MONTHLY' => 'Every $interval months',
    'QUARTERLY' => 'Every ${interval * 3} months',
    _ => 'Every $interval years',
  };
}

/// "Dividend ₹2,000 every 3 months".
String incomeSummary(Map<String, dynamic> income, Money money, {bool hidden = false}) =>
    '${incomeKinds[income['source_type']] ?? 'Income'} ${money.compact(income['amount'], hidden: hidden)} '
    '${incomeFrequencyLabel(income['frequency'] as String?, toInt(income['interval_count'], 1)).toLowerCase()}';

const _chartColors = [
  Color(0xFF10B981), Color(0xFF0EA5E9), Color(0xFFF59E0B), Color(0xFF8B5CF6),
  Color(0xFFEC4899), Color(0xFF14B8A6), Color(0xFFF97316), Color(0xFF64748B),
];

class WealthScreen extends StatefulWidget {
  const WealthScreen({super.key});

  @override
  State<WealthScreen> createState() => _WealthScreenState();
}

class _WealthScreenState extends State<WealthScreen> {
  final _viewKey = GlobalKey<AsyncViewState<Map<String, dynamic>>>();
  bool _refreshingPrices = false;

  /// The summary, plus the phone-only overview (net worth over time,
  /// safety cushion, best and worst holdings, accounts) when available.
  Future<Map<String, dynamic>> _load() async {
    final services = context.services;
    final summary = await services.assets.summary();
    final insights = services.insights;
    if (insights == null) return summary;
    return {...summary, 'overview': await insights.wealthOverview()};
  }

  Future<void> _openForm([Map<String, dynamic>? asset]) async {
    final saved = await showFormSheet<bool>(context, title: asset == null ? 'Add asset' : 'Edit asset', child: AssetForm(existing: asset));
    if (saved == true) _viewKey.currentState?.reload();
  }

  Future<void> _deleteAllAssets(int count) async {
    final ok = await confirmDeleteAll(context, count: count, what: 'assets', extraWarning: 'Bank account balances are not affected.');
    if (!ok || !mounted) return;
    try {
      await context.services.assets.deleteAll();
      if (!mounted) return;
      context.showSnack('Deleted all assets');
      _viewKey.currentState?.reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
  }

  Future<void> _refreshPrices() async {
    setState(() => _refreshingPrices = true);
    try {
      final res = await context.services.assets.refreshPrices();
      if (!mounted) return;
      context.showSnack(res['message']?.toString() ?? 'Prices refreshed');
      _viewKey.currentState?.reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _refreshingPrices = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const AppScaffoldBar(title: 'Wealth', actions: [ExportButton(sections: {ExportSection.holdings})]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Asset')),
      body: AsyncView<Map<String, dynamic>>(
        key: _viewKey,
        load: _load,
        builder: (context, s, reload) {
          final classes = (s['asset_classes'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList()
            ..sort((a, b) => toDouble(b['total_current_value']).compareTo(toDouble(a['total_current_value'])));
          final hasEquity = classes.any((c) => c['asset_class'] == 'EQUITY');
          final pnl = toDouble(s['total_assets_pnl']);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            StatGrid(children: [
              StatTile(label: 'Net worth', value: state.money.compact(s['net_worth'], hidden: state.hideAmounts), icon: Icons.account_balance),
              StatTile(label: 'Total assets', value: state.money.compact(s['total_assets_current'], hidden: state.hideAmounts), subtitle: 'Includes account balances'),
              StatTile(label: 'Invested', value: state.money.compact(s['total_assets_invested'], hidden: state.hideAmounts)),
              StatTile(
                label: 'Gain / loss',
                value: state.money.compact(pnl, hidden: state.hideAmounts),
                color: pnl >= 0 ? AppColors.income : AppColors.expense,
                subtitle: percent(s['total_assets_pnl_pct']),
              ),
              StatTile(label: 'Liabilities', value: state.money.compact(s['total_liabilities_outstanding'], hidden: state.hideAmounts), color: AppColors.expense),
              StatTile(label: 'Monthly EMIs', value: state.money.compact(s['total_monthly_emi'], hidden: state.hideAmounts)),
            ]),
            if (s['passive_income'] is Map && classes.isNotEmpty) ...[
              const SectionHeader('Passive income'),
              _PassiveIncomeCard(
                data: Map<String, dynamic>.from(s['passive_income'] as Map),
                onChanged: () => _viewKey.currentState?.reload(),
              ),
            ],
            ...wealthOverviewSections(s['overview'] as Map<String, dynamic>?),
            if (classes.isNotEmpty) ...[
              const SectionHeader('Allocation'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    SizedBox(
                      width: 130,
                      height: 130,
                      child: PieChart(PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 34,
                        sections: [
                          for (var i = 0; i < classes.length; i++)
                            PieChartSectionData(
                              value: toDouble(classes[i]['total_current_value']).clamp(0.0001, double.infinity),
                              color: _chartColors[i % _chartColors.length],
                              radius: 28,
                              showTitle: false,
                            ),
                        ],
                      )),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (var i = 0; i < classes.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(children: [
                              Container(width: 10, height: 10, decoration: BoxDecoration(color: _chartColors[i % _chartColors.length], shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Expanded(child: Text(assetClasses[classes[i]['asset_class']] ?? humanize(classes[i]['asset_class']), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                              Text(percent(classes[i]['allocation_percentage'], digits: 0), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                            ]),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ],
            SectionHeader(
              'Holdings',
              trailing: hasEquity
                  ? TextButton.icon(
                      onPressed: _refreshingPrices ? null : _refreshPrices,
                      icon: _refreshingPrices ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 18),
                      label: const Text('Live prices'),
                    )
                  : null,
            ),
            if (classes.isEmpty)
              EmptyState(
                icon: Icons.pie_chart_outline,
                title: 'No assets yet',
                message: 'Add stocks, mutual funds, gold, property or deposits to see your allocation.',
                action: FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Add asset')),
              )
            else
              for (final c in classes) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
                  child: Text('${assetClasses[c['asset_class']] ?? humanize(c['asset_class'])} (${toInt(c['count'])})', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline)),
                ),
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Column(children: [
                    for (final a in (c['items'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)))
                      ListTile(
                        onTap: () => _openForm(a),
                        title: Text(a['name'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          'Invested ${state.money.compact(a['invested_amount'], hidden: state.hideAmounts)}',
                          if (a['income'] is Map) incomeSummary(Map<String, dynamic>.from(a['income'] as Map), state.money, hidden: state.hideAmounts),
                        ].join('\n')),
                        isThreeLine: a['income'] is Map,
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          MoneyText(a['current_value'], style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            '${toDouble(a['pnl']) >= 0 ? '+' : ''}${percent(a['pnl_percentage'])}',
                            style: TextStyle(fontSize: 12, color: toDouble(a['pnl']) >= 0 ? AppColors.income : AppColors.expense),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ],
            if (classes.isNotEmpty)
              DeleteAllButton(
                label: 'Delete all assets (${classes.fold<int>(0, (s, c) => s + toInt(c['count']))})',
                onPressed: () => _deleteAllAssets(classes.fold<int>(0, (s, c) => s + toInt(c['count']))),
              ),
          ]);
        },
      ),
    );
  }
}

/// Expected income from holdings, what came in this year, and payouts that
/// are due (with a quick "Received" button).
class _PassiveIncomeCard extends StatelessWidget {
  const _PassiveIncomeCard({required this.data, required this.onChanged});
  final Map<String, dynamic> data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    String c(dynamic v) => state.money.compact(v, hidden: state.hideAmounts);
    if (toInt(data['count']) == 0) {
      return Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.payments_outlined, size: 20)),
          title: const Text('Do your holdings pay you?'),
          subtitle: const Text('Tap a holding below and switch on "Pays regular income" for dividends, interest or rent. '
              'Finverse will add each payout to Money on its date.'),
        ),
      );
    }
    final payouts = (data['payouts'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(c(data['yearly']), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: AppColors.income)),
            const SizedBox(width: 6),
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('a year', style: muted)),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('≈ ${c(data['monthly'])} / month', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('Received this year: ${c(data['received_this_year'])}', style: muted),
            ]),
          ]),
          if (payouts.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(),
            for (final o in payouts)
              Builder(builder: (context) {
                final date = toDate(o['occurrence_date'])!;
                final days = date.difference(todayDate).inDays;
                final due = days <= 0;
                final when = days < 0
                    ? 'Not marked received · ${shortDate(date)}'
                    : days == 0
                        ? 'Due today'
                        : days == 1
                            ? 'Tomorrow'
                            : 'In $days days · ${shortDate(date)}';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    switch (o['source_type']) { 'INTEREST' => Icons.percent, 'RENTAL_INCOME' => Icons.home_outlined, _ => Icons.payments_outlined },
                    color: due ? AppColors.warning : AppColors.income,
                  ),
                  title: Text(o['description'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(when, style: due ? theme.textTheme.bodySmall?.copyWith(color: AppColors.warning) : muted),
                  trailing: due
                      ? FilledButton.tonal(
                          onPressed: () async {
                            if (await markOccurrenceDone(context, o)) onChanged();
                          },
                          child: const Text('Received'),
                        )
                      : Text('+${c(o['amount'])}', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.income)),
                );
              }),
          ],
        ]),
      ),
    );
  }
}

class AssetForm extends StatefulWidget {
  const AssetForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<AssetForm> createState() => _AssetFormState();
}

class _AssetFormState extends State<AssetForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _invested, _current, _quantity, _ticker, _notes;
  String? _class;
  DateTime? _purchaseDate;
  bool _busy = false;

  // Regular income (offline version only).
  final _incomeAmount = TextEditingController();
  bool _earns = false;
  String _incomeKind = 'DIVIDEND';
  (String, int) _incomeFrequency = ('QUARTERLY', 1);
  DateTime? _incomeDate;
  String? _incomeAccount;
  bool _autoAdd = true;
  List<Map<String, dynamic>> _accounts = [];

  bool get _isEdit => widget.existing != null;
  bool get _canEarn => AppConfig.isLocal;

  Map<String, dynamic> get _meta {
    final m = widget.existing?['meta_data'];
    return m is Map ? Map<String, dynamic>.from(m) : {};
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    String num(dynamic v) => v == null ? '' : toDouble(v).toStringAsFixed(toDouble(v) == toDouble(v).roundToDouble() ? 0 : 2);
    _name = TextEditingController(text: e['name']?.toString() ?? '');
    _invested = TextEditingController(text: num(e['invested_amount']));
    _current = TextEditingController(text: num(e['current_value']));
    _quantity = TextEditingController(text: e['quantity'] == null ? '' : toDouble(e['quantity']).toString().replaceAll(RegExp(r'\.0$'), ''));
    _ticker = TextEditingController(text: (_meta['symbol'] ?? _meta['ticker'] ?? '').toString());
    _notes = TextEditingController(text: e['notes']?.toString() ?? '');
    _class = e['asset_class']?.toString();
    _purchaseDate = toDate(e['purchase_date']);
    final income = e['income'];
    if (income is Map) {
      _earns = true;
      _incomeKind = incomeKinds.containsKey(income['source_type']) ? income['source_type'] as String : 'OTHER';
      _incomeAmount.text = toDouble(income['amount']).toStringAsFixed(toDouble(income['amount']) == toDouble(income['amount']).roundToDouble() ? 0 : 2);
      _incomeFrequency = (income['frequency']?.toString() ?? 'QUARTERLY', toInt(income['interval_count'], 1));
      _incomeDate = toDate(income['next_date']) ?? toDate(income['start_date']);
      _incomeAccount = income['account_id']?.toString();
      _autoAdd = income['auto_add'] != false;
    }
    if (_canEarn) _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final list = await context.services.accounts.list();
      if (!mounted) return;
      setState(() {
        _accounts = list.where((a) => a['is_active'] != false).toList();
        if (_incomeAccount == null && _accounts.isNotEmpty) _incomeAccount = _accounts.first['id'].toString();
      });
    } catch (_) {}
  }

  /// A sensible kind of income for the asset class.
  static String _kindFor(String? assetClass) => switch (assetClass) {
        'FIXED_INCOME' || 'CASH_EQUIVALENT' => 'INTEREST',
        'REAL_ESTATE' => 'RENTAL_INCOME',
        'EQUITY' || 'MUTUAL_FUND' => 'DIVIDEND',
        _ => 'OTHER',
      };

  @override
  void dispose() {
    for (final c in [_name, _invested, _current, _quantity, _ticker, _notes, _incomeAmount]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Asset updated' : 'Asset added',
        action: () async {
          final meta = _meta;
          final ticker = _ticker.text.trim().toUpperCase();
          if (_class == 'EQUITY' && ticker.isNotEmpty) {
            meta['symbol'] = ticker;
          } else {
            meta.remove('symbol');
          }
          final payload = {
            'name': _name.text.trim(),
            'asset_class': _class,
            'invested_amount': parseAmount(_invested) ?? 0,
            'current_value': parseAmount(_current) ?? 0,
            'quantity': parseAmount(_quantity) ?? 1,
            'purchase_date': _purchaseDate == null ? null : apiDate(_purchaseDate!),
            'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            'meta_data': meta,
            if (_canEarn)
              'income': !_earns
                  ? null
                  : {
                      'source_type': _incomeKind,
                      'amount': parseAmount(_incomeAmount),
                      'frequency': _incomeFrequency.$1,
                      'interval_count': _incomeFrequency.$2,
                      'start_date': apiDate(_incomeDate!),
                      'account_id': _incomeAccount,
                      'auto_add': _autoAdd,
                    },
          };
          if (_isEdit) {
            await context.services.assets.update(widget.existing!['id'].toString(), payload);
          } else {
            await context.services.assets.create(payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete asset?', message: 'Remove "${widget.existing!['name']}" from your holdings?');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.services.assets.delete(widget.existing!['id'].toString());
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Asset deleted');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        context.showSnack(e.toString(), error: true);
      }
    }
  }

  List<Widget> _incomeFields(Money money) {
    final theme = Theme.of(context);
    final frequencies = {
      for (final e in incomeFrequencies.entries) e.value: e.key,
      if (!incomeFrequencies.values.contains(_incomeFrequency)) _incomeFrequency: incomeFrequencyLabel(_incomeFrequency.$1, _incomeFrequency.$2),
    };
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Pays regular income'),
        subtitle: const Text('Dividend, interest, rent…'),
        value: _earns,
        onChanged: (v) => setState(() {
          _earns = v;
          if (v && widget.existing?['income'] == null) {
            _incomeKind = _kindFor(_class);
            if (_incomeKind == 'INTEREST' || _incomeKind == 'RENTAL_INCOME') _incomeFrequency = ('MONTHLY', 1);
          }
        }),
      ),
      if (_earns) ...[
        if (_accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text('Add a bank account in Money first, so Finverse knows where this income goes.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
        DropdownInput<String>(label: 'Type of income', value: _incomeKind, items: incomeKinds, onChanged: (v) => setState(() => _incomeKind = v ?? _incomeKind)),
        AmountField(controller: _incomeAmount, label: 'Amount each time', prefix: money.symbol),
        DropdownInput<(String, int)>(
          label: 'How often',
          value: _incomeFrequency,
          items: frequencies,
          onChanged: (v) => setState(() => _incomeFrequency = v ?? _incomeFrequency),
        ),
        DateInput(label: 'Next payment date', value: _incomeDate, firstDate: DateTime(2000), lastDate: DateTime(DateTime.now().year + 30), onChanged: (d) => setState(() => _incomeDate = d)),
        DropdownInput<String>(
          label: 'Paid into',
          value: _incomeAccount,
          items: {for (final a in _accounts) a['id'].toString(): a['name'].toString()},
          onChanged: (v) => setState(() => _incomeAccount = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Add to Money automatically'),
          subtitle: const Text('On each payment date, as income in the account above. Turn off to mark it received yourself.'),
          value: _autoAdd,
          onChanged: (v) => setState(() => _autoAdd = v),
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final money = context.read<AppState>().money;
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextInput(controller: _name, label: 'Name', required: true),
        DropdownInput<String>(label: 'Asset class', value: _class, items: assetClasses, onChanged: (v) => setState(() => _class = v)),
        if (_class == 'EQUITY')
          TextInput(controller: _ticker, label: 'Ticker symbol (optional, e.g. INFY) for live prices', keyboardType: TextInputType.text),
        AmountField(controller: _invested, label: 'Amount invested', prefix: money.symbol, allowZero: true),
        AmountField(controller: _current, label: 'Current value', prefix: money.symbol, allowZero: true),
        AmountField(controller: _quantity, label: 'Quantity / units (optional)', required: false),
        DateInput(label: 'Purchase date (optional)', value: _purchaseDate, required: false, lastDate: DateTime.now(), onChanged: (d) => setState(() => _purchaseDate = d)),
        TextInput(controller: _notes, label: 'Notes (optional)', maxLines: 2),
        if (_canEarn) ..._incomeFields(money),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Add asset'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete asset'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}
