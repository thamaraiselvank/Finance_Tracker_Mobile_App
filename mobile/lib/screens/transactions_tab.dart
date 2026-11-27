import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../export/export_data.dart' show ExportSection;
import '../widgets/common.dart';
import '../widgets/transaction_tile.dart';
import 'export_screen.dart' show ExportScreen;
import 'money_screen.dart' show TransactionForm;

enum _Period { month, year }

const _palette = [
  Color(0xFF10B981), Color(0xFF0EA5E9), Color(0xFFF59E0B), Color(0xFF8B5CF6),
  Color(0xFFEC4899), Color(0xFF14B8A6), Color(0xFFF97316), Color(0xFF64748B),
];

/// Totals for one category inside the selected period.
class CategorySlice {
  final String key;
  final String name;
  final double amount;
  final int count;
  final Color color;
  CategorySlice(this.key, this.name, this.amount, this.count, this.color);
}

/// Totals for one subcategory of the selected category.
class SubSlice {
  final String key;
  final String name;
  final double amount;
  final int count;
  SubSlice(this.key, this.name, this.amount, this.count);
}

class _PeriodData {
  final List<Map<String, dynamic>> all;
  final Map<String, dynamic> previous;
  _PeriodData(this.all, this.previous);
}

/// Money → Transactions: month/year view with category breakdown,
/// month-by-month chart, and a grouped, filterable list.
class TransactionsTab extends StatefulWidget {
  const TransactionsTab({super.key});

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> with AutomaticKeepAliveClientMixin {
  _Period _period = _Period.month;
  DateTime _anchor = DateTime(DateTime.now().year, DateTime.now().month);
  String _type = 'ALL';
  String _search = '';
  String _breakdownType = 'EXPENSE';
  CategorySlice? _categoryFilter;
  SubSlice? _subFilter;
  Timer? _debounce;
  final _searchController = TextEditingController();
  final _viewKey = GlobalKey<AsyncViewState<_PeriodData>>();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  (DateTime, DateTime) _range(DateTime anchor) => _period == _Period.month
      ? (DateTime(anchor.year, anchor.month, 1), DateTime(anchor.year, anchor.month + 1, 0))
      : (DateTime(anchor.year, 1, 1), DateTime(anchor.year, 12, 31));

  DateTime _shifted(int delta) =>
      _period == _Period.month ? DateTime(_anchor.year, _anchor.month + delta) : DateTime(_anchor.year + delta, 1);

  Future<_PeriodData> _load() async {
    final transactions = context.services.transactions;
    final (start, end) = _range(_anchor);
    final (prevStart, prevEnd) = _range(_shifted(-1));
    // Load the whole period once; filtering and totals happen on the phone.
    final items = transactions.list(start: start, end: end, limit: 10000);
    final previous = transactions.summary(start: prevStart, end: prevEnd).catchError((_) => <String, dynamic>{});
    return _PeriodData(await items, await previous);
  }

  void _reload() => _viewKey.currentState?.reload();

  void _setAnchor(DateTime value, {_Period? period}) {
    setState(() {
      if (period != null) _period = period;
      _anchor = value;
      _categoryFilter = null;
      _subFilter = null;
    });
    _reload();
  }

  Future<void> _openForm([Map<String, dynamic>? tx]) async {
    final saved = await showFormSheet<bool>(context, title: tx == null ? 'Add transaction' : 'Edit transaction', child: TransactionForm(existing: tx));
    if (saved == true) _reload();
  }

  bool get _hasFilters => _type != 'ALL' || _search.isNotEmpty || _categoryFilter != null;

  void _selectCategory(CategorySlice s) => setState(() {
        _categoryFilter = _categoryFilter?.key == s.key ? null : s;
        _subFilter = null;
      });

  String get _periodLabel => _period == _Period.month ? DateFormat('MMMM yyyy').format(_anchor) : '${_anchor.year}';

  bool get _isLatest {
    final now = DateTime.now();
    return _period == _Period.month ? (_anchor.year == now.year && _anchor.month == now.month) : _anchor.year == now.year;
  }

  // ---- calculations -------------------------------------------------------

  static String _typeOf(Map<String, dynamic> t) => (t['type'] as String? ?? '').toUpperCase();

  double _sum(List<Map<String, dynamic>> txs, String type) =>
      txs.where((t) => _typeOf(t) == type).fold(0.0, (s, t) => s + toDouble(t['amount']));

  List<CategorySlice> _breakdown(List<Map<String, dynamic>> txs, String type) {
    final totals = <String, (String, double, int, String?)>{};
    for (final t in txs.where((t) => _typeOf(t) == type)) {
      final key = t['category_id']?.toString() ?? 'none';
      final name = t['category_name']?.toString() ?? 'Uncategorised';
      final prev = totals[key];
      totals[key] = (name, (prev?.$2 ?? 0) + toDouble(t['amount']), (prev?.$3 ?? 0) + 1, t['category_color'] as String?);
    }
    final sorted = totals.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    final used = <int>{};
    return [
      for (var i = 0; i < sorted.length; i++)
        CategorySlice(sorted[i].key, sorted[i].value.$1, sorted[i].value.$2, sorted[i].value.$3, _sliceColor(sorted[i].value.$4, i, used)),
    ];
  }

  /// The selected category split by subcategory (largest first).
  List<SubSlice> _subBreakdown(List<Map<String, dynamic>> txs, String type, String categoryKey) {
    final totals = <String, (String, double, int)>{};
    for (final t in txs) {
      if (_typeOf(t) != type || (t['category_id']?.toString() ?? 'none') != categoryKey) continue;
      final key = t['subcategory_id']?.toString() ?? 'none';
      final name = t['subcategory_name']?.toString() ?? 'No subcategory';
      final prev = totals[key];
      totals[key] = (name, (prev?.$2 ?? 0) + toDouble(t['amount']), (prev?.$3 ?? 0) + 1);
    }
    final list = [for (final e in totals.entries) SubSlice(e.key, e.value.$1, e.value.$2, e.value.$3)]
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return list;
  }

  /// Use the category's own colour unless another slice already took it.
  Color _sliceColor(String? hex, int index, Set<int> used) {
    var color = parseHexColor(hex, _palette[index % _palette.length]);
    if (used.contains(color.toARGB32())) color = _palette[index % _palette.length];
    used.add(color.toARGB32());
    return color;
  }

  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> txs) {
    final q = _search.toLowerCase();
    return txs.where((t) {
      if (_type != 'ALL' && _typeOf(t) != _type) return false;
      if (_categoryFilter != null) {
        if ((t['category_id']?.toString() ?? 'none') != _categoryFilter!.key) return false;
        if (_typeOf(t) != _breakdownType) return false;
        if (_subFilter != null && (t['subcategory_id']?.toString() ?? 'none') != _subFilter!.key) return false;
      }
      if (q.isNotEmpty) {
        final hay = '${t['description'] ?? ''} ${t['notes'] ?? ''} ${t['tags'] ?? ''} ${t['category_name'] ?? ''} ${t['account_name'] ?? ''}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Add')),
      body: Column(children: [
        _PeriodBar(
          period: _period,
          label: _periodLabel,
          canGoForward: !_isLatest,
          onPeriodChanged: (p) {
            final now = DateTime.now();
            _setAnchor(
              p == _Period.month
                  ? (_anchor.year == now.year ? DateTime(now.year, now.month) : DateTime(_anchor.year, 12))
                  : DateTime(_anchor.year, 1),
              period: p,
            );
          },
          onPrev: () => _setAnchor(_shifted(-1)),
          onNext: () => _setAnchor(_shifted(1)),
        ),
        Expanded(
          child: AsyncView<_PeriodData>(
            key: _viewKey,
            load: _load,
            builder: (context, data, reload) => _buildBody(context, data),
          ),
        ),
      ]),
    );
  }

  Widget _buildBody(BuildContext context, _PeriodData data) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final all = data.all;
    final income = _sum(all, 'INCOME');
    final expense = _sum(all, 'EXPENSE');
    final net = income - expense;
    final rate = income > 0 ? net / income * 100 : 0.0;
    final prevExpense = toDouble(data.previous['total_expense']);
    final (start, end) = _range(_anchor);
    final today = DateTime.now();
    final daysElapsed = (_isLatest ? today.difference(start).inDays + 1 : end.difference(start).inDays + 1).clamp(1, 366);
    final slices = _breakdown(all, _breakdownType);
    final items = _filtered(all);

    // Header widgets, then a lazily-built grouped list.
    final header = <Widget>[
      StatGrid(children: [
        StatTile(label: 'Income', value: state.money.compact(income, hidden: state.hideAmounts), color: AppColors.income, icon: Icons.south_west),
        StatTile(
          label: 'Expenses',
          value: state.money.compact(expense, hidden: state.hideAmounts),
          color: AppColors.expense,
          icon: Icons.north_east,
          subtitle: _changeText(expense, prevExpense),
        ),
        StatTile(label: 'Net savings', value: state.money.compact(net, hidden: state.hideAmounts), color: net >= 0 ? AppColors.income : AppColors.expense, subtitle: 'Savings rate ${percent(rate, digits: 0)}'),
        StatTile(
          label: _period == _Period.month ? 'Avg. spend / day' : 'Avg. spend / month',
          value: state.money.compact(_period == _Period.month ? expense / daysElapsed : expense / (_isLatest ? today.month : 12), hidden: state.hideAmounts),
          icon: Icons.speed,
          subtitle: '${all.length} transactions',
        ),
      ]),
      if (_period == _Period.year && all.isNotEmpty) ...[
        const SectionHeader('Month by month'),
        _MonthlyChart(
          transactions: all,
          year: _anchor.year,
          hidden: state.hideAmounts,
          money: state.money,
          onMonthTap: (m) => _setAnchor(DateTime(_anchor.year, m), period: _Period.month),
        ),
      ],
      if (all.isNotEmpty) ...[
        SectionHeader(
          'Where the money ${_breakdownType == 'EXPENSE' ? 'went' : 'came from'}',
          trailing: SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [ButtonSegment(value: 'EXPENSE', label: Text('Spent')), ButtonSegment(value: 'INCOME', label: Text('Earned'))],
            selected: {_breakdownType},
            onSelectionChanged: (s) => setState(() {
              _breakdownType = s.first;
              _categoryFilter = null;
              _subFilter = null;
            }),
          ),
        ),
        _BreakdownCard(
          slices: slices,
          total: _breakdownType == 'EXPENSE' ? expense : income,
          selected: _categoryFilter,
          onSelect: _selectCategory,
          subSlices: _categoryFilter == null ? const [] : _subBreakdown(all, _breakdownType, _categoryFilter!.key),
          selectedSub: _subFilter,
          onSelectSub: (sub) => setState(() => _subFilter = _subFilter?.key == sub.key ? null : sub),
        ),
      ],
      SectionHeader(
        'Transactions',
        trailing: items.isEmpty
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton.icon(
                  // Exports what is shown: this period, type and category.
                  onPressed: () {
                    final (start, end) = _range(_anchor);
                    final category = _categoryFilter?.key;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExportScreen(
                          sections: const {ExportSection.transactions},
                          start: start,
                          end: end,
                          type: _categoryFilter != null ? _breakdownType : _type,
                          categoryId: category == 'none' ? null : category,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Export'),
                ),
                TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: () => deleteAllFlow<Map<String, dynamic>>(
                  context,
                  items: items,
                  what: _hasFilters ? 'shown transactions in $_periodLabel' : 'transactions in $_periodLabel',
                  deleteItem: (t) => context.services.transactions.delete(t['id'].toString()),
                  extraWarning: 'Account balances will be adjusted to reverse these transactions.'
                      '${_hasFilters ? ' Only the transactions matching your current filters will be deleted.' : ''}',
                  onDone: _reload,
                ),
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: Text(_hasFilters ? 'Delete shown' : 'Delete all'),
              ),
              ]),
      ),
      TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search description, category, account',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          suffixIcon: _search.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () {
            _searchController.clear();
            setState(() => _search = '');
          }),
        ),
        onChanged: (v) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _search = v.trim()));
        },
      ),
      SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(vertical: 8), children: [
          if (_categoryFilter != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                avatar: CircleAvatar(backgroundColor: _categoryFilter!.color, radius: 6),
                label: Text(_subFilter == null ? _categoryFilter!.name : '${_categoryFilter!.name} · ${_subFilter!.name}'),
                onDeleted: () => setState(() {
                  _categoryFilter = null;
                  _subFilter = null;
                }),
              ),
            ),
          for (final t in const {'ALL': 'All', 'EXPENSE': 'Expenses', 'INCOME': 'Income', 'TRANSFER': 'Transfers'}.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(t.value), selected: _type == t.key, onSelected: (_) => setState(() => _type = t.key)),
            ),
        ]),
      ),
    ];

    // Group: by day in month view, by month in year view.
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final t in items) {
      final d = toDate(t['date']);
      final key = d == null ? '—' : (_period == _Period.month ? _dayLabel(d) : DateFormat('MMMM yyyy').format(d));
      groups.putIfAbsent(key, () => []).add(t);
    }
    final rows = <Widget Function()>[];
    groups.forEach((label, txs) {
      final dayNet = txs.fold<double>(0, (s, t) => s + (_typeOf(t) == 'INCOME' ? 1 : (_typeOf(t) == 'EXPENSE' ? -1 : 0)) * toDouble(t['amount']));
      rows.add(() => Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
            child: Row(children: [
              Expanded(child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline))),
              Text(
                '${dayNet >= 0 ? '+' : '−'}${state.money.format(dayNet.abs(), hidden: state.hideAmounts)}',
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline),
              ),
            ]),
          ));
      for (final t in txs) {
        rows.add(() => TransactionTile(tx: t, onTap: () => _openForm(t)));
      }
    });
    if (items.isEmpty) {
      rows.add(() => EmptyState(
            icon: Icons.receipt_long_outlined,
            title: all.isEmpty ? 'No transactions in $_periodLabel' : 'No matching transactions',
            action: all.isEmpty ? FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Add transaction')) : null,
          ));
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: header.length + rows.length,
      itemBuilder: (context, i) => i < header.length ? header[i] : rows[i - header.length](),
    );
  }

  String? _changeText(double current, double previous) {
    if (previous <= 0) return null;
    final change = (current - previous) / previous * 100;
    final label = _period == _Period.month ? 'last month' : 'last year';
    if (change.abs() < 0.5) return 'Same as $label';
    return '${change > 0 ? '▲' : '▼'} ${change.abs().toStringAsFixed(0)}% vs $label';
  }

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('EEE, d MMM').format(d);
  }
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({required this.period, required this.label, required this.canGoForward, required this.onPeriodChanged, required this.onPrev, required this.onNext});
  final _Period period;
  final String label;
  final bool canGoForward;
  final ValueChanged<_Period> onPeriodChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Row(children: [
        SegmentedButton<_Period>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [ButtonSegment(value: _Period.month, label: Text('Month')), ButtonSegment(value: _Period.year, label: Text('Year'))],
          selected: {period},
          onSelectionChanged: (s) => onPeriodChanged(s.first),
        ),
        const Spacer(),
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
        Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        IconButton(onPressed: canGoForward ? onNext : null, icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }
}

/// Donut chart + legend of category totals. Tap a slice or a row to open
/// that category: its subcategories show underneath and the list is
/// filtered to it. Tap a subcategory to narrow the list further.
class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.slices,
    required this.total,
    required this.selected,
    required this.onSelect,
    required this.subSlices,
    required this.selectedSub,
    required this.onSelectSub,
  });
  final List<CategorySlice> slices;
  final double total;
  final CategorySlice? selected;
  final ValueChanged<CategorySlice> onSelect;
  final List<SubSlice> subSlices;
  final SubSlice? selectedSub;
  final ValueChanged<SubSlice> onSelectSub;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    if (slices.isEmpty || total <= 0) {
      return const Card(child: EmptyState(icon: Icons.donut_large, title: 'Nothing to show for this period'));
    }
    // Chart shows the top 6; the rest are grouped as "Other".
    final top = slices.take(6).toList();
    final otherTotal = slices.skip(6).fold<double>(0, (s, c) => s + c.amount);
    final chartSlices = [...top.map((s) => (s.color, s.amount, s.key)), if (otherTotal > 0) (const Color(0xFF94A3B8), otherTotal, '__other')];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          SizedBox(
            height: 180,
            child: Stack(alignment: Alignment.center, children: [
              PieChart(PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 58,
                pieTouchData: PieTouchData(
                  touchCallback: (event, response) {
                    if (event is! FlTapUpEvent) return;
                    final index = response?.touchedSection?.touchedSectionIndex ?? -1;
                    if (index >= 0 && index < top.length) onSelect(top[index]);
                  },
                ),
                sections: [
                  for (final (color, amount, key) in chartSlices)
                    PieChartSectionData(
                      value: amount,
                      color: selected == null || selected!.key == key ? color : color.withValues(alpha: 0.25),
                      radius: selected?.key == key ? 30 : 24,
                      showTitle: false,
                    ),
                ],
              )),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(selected?.name ?? 'Total', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
                Text(state.money.compact(selected?.amount ?? total, hidden: state.hideAmounts), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                if (selected != null) Text(percent(selected!.amount / total * 100, digits: 0), style: theme.textTheme.labelMedium),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
          for (final s in slices)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelect(s),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                decoration: BoxDecoration(
                  color: selected?.key == s.key ? s.color.withValues(alpha: 0.12) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(children: [
                  Row(children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${s.name}  ·  ${s.count}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text(state.money.format(s.amount, hidden: state.hideAmounts), style: const TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(width: 48, child: Text(percent(s.amount / total * 100, digits: 0), textAlign: TextAlign.right, style: TextStyle(color: theme.colorScheme.outline))),
                    Icon(selected?.key == s.key ? Icons.expand_less : Icons.expand_more, size: 18, color: theme.colorScheme.outline),
                  ]),
                  const SizedBox(height: 6),
                  ProgressBar(value: s.amount / total, color: s.color),
                  if (selected?.key == s.key)
                    _SubBreakdown(
                      color: s.color,
                      categoryTotal: s.amount,
                      subs: subSlices,
                      selected: selectedSub,
                      onSelect: onSelectSub,
                    ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Inside an open category: a bar for each subcategory, in shades of the
/// category colour. Tap one to show only its transactions below.
class _SubBreakdown extends StatelessWidget {
  const _SubBreakdown({required this.color, required this.categoryTotal, required this.subs, required this.selected, required this.onSelect});
  final Color color;
  final double categoryTotal;
  final List<SubSlice> subs;
  final SubSlice? selected;
  final ValueChanged<SubSlice> onSelect;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    if (subs.isEmpty || categoryTotal <= 0) return const SizedBox.shrink();
    final onlyNone = subs.length == 1 && subs.first.key == 'none';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 0, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (onlyNone)
          Text('No subcategories used here. Edit a transaction to pick one, and the split shows up here.', style: muted)
        else ...[
          // One stacked bar: how the category splits.
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(children: [
                for (var i = 0; i < subs.length; i++)
                  Expanded(
                    flex: math.max(1, (subs[i].amount / categoryTotal * 1000).round()),
                    child: Container(color: _shade(i, subs.length).withValues(alpha: selected == null || selected!.key == subs[i].key ? 1 : 0.3)),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < subs.length; i++)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => onSelect(subs[i]),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                decoration: BoxDecoration(
                  color: selected?.key == subs[i].key ? color.withValues(alpha: 0.12) : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: _shade(i, subs.length), borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${subs[i].name}  ·  ${subs[i].count}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: selected?.key == subs[i].key ? FontWeight.w700 : null)),
                  ),
                  Text(state.money.format(subs[i].amount, hidden: state.hideAmounts), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  SizedBox(width: 44, child: Text(percent(subs[i].amount / categoryTotal * 100, digits: 0), textAlign: TextAlign.right, style: muted)),
                ]),
              ),
            ),
        ],
      ]),
    );
  }

  /// From the full category colour to a lighter version of it.
  Color _shade(int i, int n) => n <= 1 ? color : Color.lerp(color, Colors.white, 0.55 * i / (n - 1))!;
}

/// Income vs expense bars for each month of a year. Tap a month to open it.
class _MonthlyChart extends StatelessWidget {
  const _MonthlyChart({required this.transactions, required this.year, required this.hidden, required this.money, required this.onMonthTap});
  final List<Map<String, dynamic>> transactions;
  final int year;
  final bool hidden;
  final Money money;
  final ValueChanged<int> onMonthTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final income = List<double>.filled(12, 0);
    final expense = List<double>.filled(12, 0);
    for (final t in transactions) {
      final d = toDate(t['date']);
      if (d == null || d.year != year) continue;
      final type = (t['type'] as String? ?? '').toUpperCase();
      if (type == 'INCOME') income[d.month - 1] += toDouble(t['amount']);
      if (type == 'EXPENSE') expense[d.month - 1] += toDouble(t['amount']);
    }
    final maxY = [...income, ...expense].fold<double>(0, math.max);
    const months = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(children: [
          SizedBox(
            height: 180,
            child: BarChart(BarChartData(
              maxY: maxY <= 0 ? 1 : maxY * 1.1,
              alignment: BarChartAlignment.spaceAround,
              gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: maxY <= 0 ? 1 : maxY / 4, getDrawingHorizontalLine: (_) => FlLine(color: theme.dividerColor.withValues(alpha: 0.3), strokeWidth: 1)),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(months[value.toInt()], style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
                    ),
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                  getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
                    '${DateFormat('MMM').format(DateTime(year, group.x + 1))}\n${rodIndex == 0 ? 'In' : 'Out'}: ${money.compact(rod.toY, hidden: hidden)}',
                    TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                  ),
                ),
                touchCallback: (event, response) {
                  if (event is FlTapUpEvent && response?.spot != null) onMonthTap(response!.spot!.touchedBarGroupIndex + 1);
                },
              ),
              barGroups: [
                for (var m = 0; m < 12; m++)
                  BarChartGroupData(x: m, barsSpace: 2, barRods: [
                    BarChartRodData(toY: income[m], color: AppColors.income, width: 7, borderRadius: BorderRadius.circular(2)),
                    BarChartRodData(toY: expense[m], color: AppColors.expense, width: 7, borderRadius: BorderRadius.circular(2)),
                  ]),
              ],
            )),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _legend(AppColors.income, 'Income'),
            const SizedBox(width: 16),
            _legend(AppColors.expense, 'Expenses'),
            const SizedBox(width: 16),
            Text('Tap a month to open it', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ]),
        ]),
      ),
    );
  }

  Widget _legend(Color c, String label) => Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);
}
