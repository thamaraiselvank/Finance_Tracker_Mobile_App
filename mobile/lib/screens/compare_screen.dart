import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';
import '../widgets/transaction_tile.dart' show parseHexColor;
import 'trends_screen.dart' show changeOf;

/// Any two months side by side: totals, then each category with its
/// subcategories and the places paid most.
class CompareMonthsScreen extends StatefulWidget {
  const CompareMonthsScreen({super.key});

  @override
  State<CompareMonthsScreen> createState() => _CompareMonthsScreenState();
}

class _CompareMonthsScreenState extends State<CompareMonthsScreen> {
  String? _a, _b;
  String _type = 'EXPENSE';
  bool _sameDays = true;
  Json? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await context.services.insights!.compareMonths(monthA: _a, monthB: _b, type: _type, sameDays: _sameDays);
      if (!mounted) return;
      setState(() {
        _data = data;
        _a = (data['a'] as Json)['month'] as String;
        _b = (data['b'] as Json)['month'] as String;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _set({String? a, String? b, String? type, bool? sameDays}) {
    _a = a ?? _a;
    _b = b ?? _b;
    _type = type ?? _type;
    _sameDays = sameDays ?? _sameDays;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('Compare months')),
      body: d == null
          ? (_error != null
              ? EmptyState(icon: Icons.error_outline, title: 'Could not compare', message: _error.toString())
              : const Center(child: CircularProgressIndicator()))
          : Stack(children: [
              ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                _Controls(data: d, type: _type, sameDays: _sameDays, onChanged: _set),
                const SectionHeader('Totals'),
                _TotalsCard(data: d),
                SectionHeader(_type == 'EXPENSE' ? 'Spending by category' : 'Income by category'),
                if ((d['categories'] as List).isEmpty)
                  const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Nothing recorded in these two months.')))
                else ...[
                  _ChangesCard(data: d),
                  const SizedBox(height: 8),
                  for (final c in (d['categories'] as List).cast<Json>()) _CategoryTile(category: c, data: d),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Tap a category to see its subcategories and the places paid most. Own-money moves (transfers, card bills, cash) are not counted.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                ],
              ]),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
            ]),
    );
  }
}

String _sideLabel(Json side) {
  final label = side['label'] as String;
  if (side['partial'] != true) return label;
  return '$label (to ${shortDate(toDate(side['to']))})';
}

class _Controls extends StatelessWidget {
  const _Controls({required this.data, required this.type, required this.sameDays, required this.onChanged});
  final Json data;
  final String type;
  final bool sameDays;
  final void Function({String? a, String? b, String? type, bool? sameDays}) onChanged;

  @override
  Widget build(BuildContext context) {
    final months = {for (final m in (data['available'] as List).cast<Json>()) m['month'] as String: m['label'] as String};
    final a = (data['a'] as Json)['month'] as String, b = (data['b'] as Json)['month'] as String;
    months.putIfAbsent(a, () => (data['a'] as Json)['label'] as String);
    months.putIfAbsent(b, () => (data['b'] as Json)['label'] as String);
    final current = (data['available'] as List).isEmpty ? null : ((data['available'] as List).first as Json)['month'];
    final involvesCurrent = a == current || b == current;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Column(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: DropdownInput<String>(key: ValueKey('a$a'), label: 'Month', value: a, items: months, onChanged: (v) => onChanged(a: v))),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton(tooltip: 'Swap', onPressed: () => onChanged(a: b, b: a), icon: const Icon(Icons.swap_horiz)),
            ),
            Expanded(child: DropdownInput<String>(key: ValueKey('b$b'), label: 'Compared with', value: b, items: months, onChanged: (v) => onChanged(b: v))),
            const SizedBox(width: 8),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'EXPENSE', label: Text('Spending'), icon: Icon(Icons.north_east, size: 16)),
                  ButtonSegment(value: 'INCOME', label: Text('Income'), icon: Icon(Icons.south_west, size: 16)),
                ],
                selected: {type},
                onSelectionChanged: (s) => onChanged(type: s.first),
              ),
            ),
          ),
          if (involvesCurrent)
            SwitchListTile(
              contentPadding: const EdgeInsets.only(right: 8),
              value: sameDays,
              onChanged: (v) => onChanged(sameDays: v),
              title: const Text('Same days only'),
              subtitle: Text(sameDays
                  ? 'Both months up to day ${DateTime.now().day}, so this month so far is fair against the other'
                  : 'This month so far against the whole of the other month'),
            )
          else
            const SizedBox(height: 12),
        ]),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.data});
  final Json data;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final a = data['a'] as Json, b = data['b'] as Json;
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

    Widget row(String label, String key, Color color, {bool lowerIsGood = false}) {
      final change = changeOf(toDouble(a[key]), toDouble(b[key]), lowerIsGood: lowerIsGood);
      final diff = toDouble(a[key]) - toDouble(b[key]);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Expanded(flex: 3, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(flex: 4, child: Text(m(a[key]), textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, color: color))),
          Expanded(flex: 4, child: Text(m(b[key]), textAlign: TextAlign.right, style: muted)),
          SizedBox(
            width: 70,
            child: Text(
              change?.text ?? (diff.abs() < 0.5 ? '—' : ''),
              textAlign: TextAlign.right,
              style: TextStyle(color: change?.color, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ]),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(children: [
          Row(children: [
            const Expanded(flex: 3, child: SizedBox()),
            Expanded(flex: 4, child: Text(_sideLabel(a), textAlign: TextAlign.right, style: theme.textTheme.labelMedium)),
            Expanded(flex: 4, child: Text(_sideLabel(b), textAlign: TextAlign.right, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline))),
            const SizedBox(width: 70),
          ]),
          const Divider(),
          row('Earned', 'income', AppColors.income),
          row('Spent', 'expense', AppColors.expense, lowerIsGood: true),
          row('Saved', 'saved', toDouble(a['saved']) >= 0 ? AppColors.income : AppColors.expense),
        ]),
      ),
    );
  }
}

/// The biggest rise, the biggest fall and anything new, in words.
class _ChangesCard extends StatelessWidget {
  const _ChangesCard({required this.data});
  final Json data;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final spending = data['type'] == 'EXPENSE';
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
    final a = (data['a'] as Json)['label'], b = (data['b'] as Json)['label'];

    // Look at categories and their subcategories together: the most telling change wins.
    final lines = <Json>[];
    for (final c in (data['categories'] as List).cast<Json>()) {
      lines.add({'name': c['name'], 'a': toDouble(c['a']), 'b': toDouble(c['b'])});
      for (final s in (c['subcategories'] as List).cast<Json>()) {
        if (s['id'] != null) lines.add({'name': '${s['name']} (${c['name']})', 'a': toDouble(s['a']), 'b': toDouble(s['b']), 'sub': true});
      }
    }
    double diff(Json l) => (l['a'] as double) - (l['b'] as double);
    final cats = lines.where((l) => l['sub'] != true).toList();
    final up = [...cats]..sort((x, y) => diff(y).compareTo(diff(x)));
    final subsUp = lines.where((l) => l['sub'] == true).toList()..sort((x, y) => diff(y).compareTo(diff(x)));
    final newOnes = cats.where((l) => (l['b'] as double) == 0 && (l['a'] as double) > 0).toList();
    final gone = cats.where((l) => (l['a'] as double) == 0 && (l['b'] as double) > 0).toList();

    final notes = <(IconData, Color, String)>[];
    final rise = spending ? AppColors.expense : AppColors.income, fall = spending ? AppColors.income : AppColors.expense;
    if (up.isNotEmpty && diff(up.first) >= 1 && (up.first['b'] as double) > 0) {
      notes.add((Icons.arrow_upward, rise, 'Biggest rise: ${up.first['name']}, ${m(diff(up.first))} more than in $b.'));
    }
    if (subsUp.isNotEmpty && diff(subsUp.first) >= 1 && (subsUp.first['b'] as double) > 0) {
      notes.add((Icons.subdirectory_arrow_right, rise, 'Within that detail: ${subsUp.first['name']} is up ${m(diff(subsUp.first))}.'));
    }
    if (up.isNotEmpty && diff(up.last) <= -1) {
      notes.add((Icons.arrow_downward, fall, 'Biggest fall: ${up.last['name']}, ${m(-diff(up.last))} less than in $b.'));
    }
    if (newOnes.isNotEmpty) {
      notes.add((Icons.fiber_new_outlined, theme.colorScheme.primary,
          'New in $a: ${newOnes.take(3).map((l) => '${l['name']} (${m(l['a'])})').join(', ')}.'));
    }
    if (gone.isNotEmpty) {
      notes.add((Icons.remove_circle_outline, theme.colorScheme.outline, 'Nothing in $a for ${gone.take(3).map((l) => l['name']).join(', ')}.'));
    }
    if (notes.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (icon, color, text) in notes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(text)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.data});
  final Json category;
  final Json data;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final spending = data['type'] == 'EXPENSE';
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
    final aLabel = ((data['a'] as Json)['label'] as String).substring(0, 3);
    final bLabel = ((data['b'] as Json)['label'] as String).substring(0, 3);
    final c = category;
    final change = changeOf(toDouble(c['a']), toDouble(c['b']), lowerIsGood: spending);
    final subs = (c['subcategories'] as List).cast<Json>();
    final payees = (c['payees'] as List).cast<Json>();
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

    Widget line(Json r, {bool counts = false}) {
      final ch = changeOf(toDouble(r['a']), toDouble(r['b']), lowerIsGood: spending);
      String count(String k) => counts && toInt(r[k]) > 0 ? ' · ${toInt(r[k])}×' : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(flex: 5, child: Text(r['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 4, child: Text('${m(r['a'])}${count('count_a')}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(flex: 4, child: Text('${m(r['b'])}${count('count_b')}', textAlign: TextAlign.right, style: muted)),
          SizedBox(
            width: 58,
            child: Text(
              ch?.text ?? (toDouble(r['b']) == 0 && toDouble(r['a']) > 0 ? 'new' : ''),
              textAlign: TextAlign.right,
              style: TextStyle(color: ch?.color ?? theme.colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 11),
            ),
          ),
        ]),
      );
    }

    Widget header(String title) => Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Row(children: [
            Expanded(flex: 5, child: Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary))),
            Expanded(flex: 4, child: Text(aLabel, textAlign: TextAlign.right, style: theme.textTheme.labelSmall)),
            Expanded(flex: 4, child: Text(bLabel, textAlign: TextAlign.right, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline))),
            const SizedBox(width: 58),
          ]),
        );

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: CircleAvatar(radius: 6, backgroundColor: parseHexColor(c['color'] as String?, theme.colorScheme.outline)),
        title: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('$aLabel ${m(c['a'])} · $bLabel ${m(c['b'])}', style: muted),
        trailing: Text(
          change?.text ?? (toDouble(c['b']) == 0 ? 'new' : '—'),
          style: TextStyle(color: change?.color ?? theme.colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (subs.length > 1 || (subs.length == 1 && subs.first['id'] != null)) ...[
            header('Subcategories'),
            for (final s in subs) line(s),
          ],
          if (payees.isNotEmpty) ...[
            header(spending ? 'Paid to' : 'Received from'),
            for (final p in payees) line(p, counts: true),
          ],
        ],
      ),
    );
  }
}
