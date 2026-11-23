import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import 'money_screen.dart' show AppScaffoldBar;

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

  Future<Map<String, dynamic>> _load() => context.services.assets.summary();

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
      appBar: const AppScaffoldBar(title: 'Wealth'),
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
                        subtitle: Text('Invested ${state.money.compact(a['invested_amount'], hidden: state.hideAmounts)}'),
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

  bool get _isEdit => widget.existing != null;

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
  }

  @override
  void dispose() {
    for (final c in [_name, _invested, _current, _quantity, _ticker, _notes]) {
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
