import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';
import '../widgets/transaction_tile.dart' show parseHexColor;
import 'insights_screen.dart' show maskAmounts;

/// "▲ 12%" / "▼ 8%" between two amounts, coloured by whether the change is
/// good (for spending, going down is good). Null when there is nothing to
/// compare with.
({String text, Color color})? changeOf(double now, double before, {bool lowerIsGood = false}) {
  if (before <= 0 || (now - before).abs() < 0.5) return null;
  final pct = (now - before) / before * 100;
  final up = pct > 0;
  final good = up != lowerIsGood;
  return (
    text: '${up ? '▲' : '▼'} ${pct.abs() >= 100 ? pct.abs().toStringAsFixed(0) : pct.abs().toStringAsFixed(pct.abs() < 10 ? 1 : 0)}%',
    color: good ? AppColors.income : AppColors.expense,
  );
}

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  bool _fullLastMonth = false;

  @override
  Widget build(BuildContext context) {
    final service = context.services.insights!;
    return Scaffold(
      appBar: AppBar(title: const Text('Trends & comparisons')),
      body: AsyncView<Json>(
        load: service.trends,
        builder: (context, t, reload) {
          final since = t['since'] as Json?;
          if (since == null) {
            return const EmptyState(
              icon: Icons.query_stats,
              title: 'Nothing to compare yet',
              message: 'Once payments are in Money, this page compares months, categories and your wealth over time.',
            );
          }
          final highlights = (t['highlights'] as List).cast<Json>();
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              SectionHeader('${t['this_label']} so far vs ${t['last_label']}'),
              MonthCompareCard(trends: t),
              const SectionHeader('Month by month'),
              _MonthsCard(months: (t['months'] as List).cast<Json>()),
              const SectionHeader('Where the money went'),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, label: Text('Same days of ${(t['last_label'] as String).substring(0, 3)}')),
                    ButtonSegment(value: true, label: Text('All of ${(t['last_label'] as String).substring(0, 3)}')),
                  ],
                  selected: {_fullLastMonth},
                  onSelectionChanged: (s) => setState(() => _fullLastMonth = s.first),
                ),
              ),
              _CategorySplitCard(trends: t, fullLastMonth: _fullLastMonth),
              if (highlights.isNotEmpty) ...[
                SectionHeader('${t['this_label']} at a glance'),
                StatGrid(children: [
                  for (final h in highlights)
                    StatTile(
                      label: h['title'] as String,
                      value: maskAmounts(context, h['value'] as String),
                      subtitle: h['note'] == null ? null : maskAmounts(context, h['note'] as String),
                    ),
                ]),
              ],
              const SectionHeader('Your wealth'),
              WealthGrowthCard(wealth: t['wealth'] as Json),
              const SectionHeader('Since you started'),
              _SinceCard(since: since),
            ]),
          );
        },
      ),
    );
  }
}

/// Earned, spent and saved this month so far against the same days of last
/// month, with all of last month for reference.
class MonthCompareCard extends StatelessWidget {
  const MonthCompareCard({super.key, required this.trends});
  final Json trends;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final c = trends['compare'] as Json;
    final now = c['this'] as Json, before = c['last'] as Json, full = c['last_full'] as Json;
    final sameDay = shortDate(toDate(trends['same_day_last_month']));
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);

    Widget row(String label, String key, IconData icon, Color color, {bool lowerIsGood = false}) {
      final change = changeOf(toDouble(now[key]), toDouble(before[key]), lowerIsGood: lowerIsGood);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          CircleAvatar(radius: 16, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
              Text(m(now[key]), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${(trends['last_label'] as String).substring(0, 3)}: ${m(before[key])}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            if (change != null) Text(change.text, style: TextStyle(color: change.color, fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ]),
      );
    }

    final savedNow = toDouble(now['saved']), savedBefore = toDouble(before['saved']);
    final diff = savedNow - savedBefore;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row('Earned', 'income', Icons.south_west, AppColors.income),
          row('Spent', 'expense', Icons.north_east, AppColors.expense, lowerIsGood: true),
          row('Saved', 'saved', Icons.savings_outlined, theme.colorScheme.primary),
          const Divider(),
          Text(
            [
              'Compared with ${trends['last_label']} up to $sameDay.',
              if (toDouble(before['income']) > 0 || toDouble(before['expense']) > 0)
                diff >= 0 ? 'You have saved ${m(diff)} more so far.' : 'You have saved ${m(-diff)} less so far.',
              'All of ${trends['last_label']}: earned ${m(full['income'])}, spent ${m(full['expense'])}, saved ${m(full['saved'])}.',
            ].join(' '),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ]),
      ),
    );
  }
}

class _MonthsCard extends StatelessWidget {
  const _MonthsCard({required this.months});
  final List<Json> months;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final maxY = months.fold<double>(0, (m, e) => [m, toDouble(e['income']), toDouble(e['expense'])].reduce((a, b) => a > b ? a : b));
    String c(dynamic v) => state.money.compact(v, hidden: state.hideAmounts);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(children: [
          SizedBox(
            height: 160,
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
                    getTitlesWidget: (value, meta) => Padding(padding: const EdgeInsets.only(top: 6), child: Text(months[value.toInt()]['label'] as String, style: muted)),
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                  getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
                    '${months[group.x]['label']}\n${rodIndex == 0 ? 'Earned' : 'Spent'}: ${c(rod.toY)}',
                    TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < months.length; i++)
                  BarChartGroupData(x: i, barsSpace: 3, barRods: [
                    BarChartRodData(toY: toDouble(months[i]['income']), color: AppColors.income, width: 9, borderRadius: BorderRadius.circular(2)),
                    BarChartRodData(toY: toDouble(months[i]['expense']), color: AppColors.expense, width: 9, borderRadius: BorderRadius.circular(2)),
                  ]),
              ],
            )),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(children: [
              Expanded(flex: 3, child: Text('Month', style: muted)),
              Expanded(flex: 3, child: Text('Earned', style: muted, textAlign: TextAlign.right)),
              Expanded(flex: 3, child: Text('Spent', style: muted, textAlign: TextAlign.right)),
              Expanded(flex: 4, child: Text('Saved', style: muted, textAlign: TextAlign.right)),
            ]),
          ),
          for (final m in months.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(children: [
                Expanded(flex: 3, child: Text(m['partial'] == true ? '${m['label']} (so far)' : m['label'] as String, style: theme.textTheme.bodySmall)),
                Expanded(flex: 3, child: Text(c(m['income']), textAlign: TextAlign.right, style: theme.textTheme.bodySmall)),
                Expanded(flex: 3, child: Text(c(m['expense']), textAlign: TextAlign.right, style: theme.textTheme.bodySmall)),
                Expanded(
                  flex: 4,
                  child: Text(
                    toDouble(m['income']) > 0
                        ? '${c(m['saved'])} · ${(toDouble(m['saved']) / toDouble(m['income']) * 100).round()}%'
                        : c(m['saved']),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: toDouble(m['saved']) >= 0 ? AppColors.income : AppColors.expense,
                    ),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Each category's share this month against last month.
class _CategorySplitCard extends StatelessWidget {
  const _CategorySplitCard({required this.trends, required this.fullLastMonth});
  final Json trends;
  final bool fullLastMonth;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final lastKey = fullLastMonth ? 'last_full' : 'last_same';
    final rows = (trends['categories'] as List).cast<Json>().where((c) => toDouble(c['this']) > 0 || toDouble(c[lastKey]) > 0).toList();
    if (rows.isEmpty) {
      return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No spending in these two months yet.')));
    }
    final totalNow = rows.fold<double>(0, (s, c) => s + toDouble(c['this']));
    final totalLast = rows.fold<double>(0, (s, c) => s + toDouble(c[lastKey]));
    final maxV = rows.fold<double>(0, (m, c) => [m, toDouble(c['this']), toDouble(c[lastKey])].reduce((a, b) => a > b ? a : b));
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
    final lastName = fullLastMonth ? 'All of ${trends['last_label']}' : '${trends['last_label']} to ${shortDate(toDate(trends['same_day_last_month']))}';
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

    Widget bar(double value, Color color) => ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: maxV > 0 ? value / maxV : 0, minHeight: 6, color: color, backgroundColor: theme.colorScheme.surfaceContainerHighest),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 16, runSpacing: 4, children: [
            _legend(theme.colorScheme.primary, '${trends['this_label']} so far · ${m(totalNow)}'),
            _legend(theme.colorScheme.outline, '$lastName · ${m(totalLast)}'),
          ]),
          const SizedBox(height: 8),
          for (final c in rows.take(10)) ...[
            const SizedBox(height: 10),
            Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: parseHexColor(c['color'] as String?, theme.colorScheme.primary), shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(c['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (changeOf(toDouble(c['this']), toDouble(c[lastKey]), lowerIsGood: true) case final change?)
                Text(change.text, style: TextStyle(color: change.color, fontWeight: FontWeight.w700, fontSize: 12)),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: bar(toDouble(c['this']), theme.colorScheme.primary)),
              SizedBox(
                width: 132,
                child: Text(
                  '${m(c['this'])} · ${totalNow > 0 ? (toDouble(c['this']) / totalNow * 100).round() : 0}%',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              Expanded(child: bar(toDouble(c[lastKey]), theme.colorScheme.outline)),
              SizedBox(
                width: 132,
                child: Text(
                  '${m(c[lastKey])} · ${totalLast > 0 ? (toDouble(c[lastKey]) / totalLast * 100).round() : 0}%',
                  textAlign: TextAlign.right,
                  style: muted,
                ),
              ),
            ]),
          ],
          if (rows.length > 10) ...[
            const SizedBox(height: 10),
            Text('and ${rows.length - 10} more categories', style: muted),
          ],
        ]),
      ),
    );
  }

  Widget _legend(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: const TextStyle(fontSize: 12))),
      ]);
}

/// Net worth then and now, and holdings' invested vs current value.
class WealthGrowthCard extends StatelessWidget {
  const WealthGrowthCard({super.key, required this.wealth});
  final Json wealth;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
    final now = wealth['now'] as Json?;
    final first = wealth['first'] as Json?;
    final monthAgo = wealth['month_ago'] as Json?;
    if (now == null) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

    Widget line(String title, String from, String fromLabel, String to, double change, double base) {
      final pct = base.abs() > 0 ? change / base.abs() * 100 : null;
      final color = change >= 0 ? AppColors.income : AppColors.expense;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 2),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
            Text(from, style: theme.textTheme.titleSmall),
            Icon(Icons.arrow_forward, size: 16, color: theme.colorScheme.outline),
            Text(to, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          Text(
            '$fromLabel · ${change >= 0 ? '+' : '−'}${m(change.abs())}${pct == null ? '' : ' (${change >= 0 ? '+' : '−'}${pct.abs().toStringAsFixed(1)}%)'}',
            style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ]),
      );
    }

    final nowWorth = toDouble(now['net_worth']);
    final rows = <Widget>[];
    if (first != null && first['date'] != now['date']) {
      final days = toDate(now['date'])!.difference(toDate(first['date'])!).inDays;
      final base = toDouble(first['net_worth']);
      rows.add(line('Net worth since ${displayDate(toDate(first['date']))}', m(base), '$days days', m(nowWorth), nowWorth - base, base));
    }
    if (monthAgo != null && first != null && monthAgo['date'] != first['date']) {
      final base = toDouble(monthAgo['net_worth']);
      rows.add(line('Net worth in the last month', m(base), 'since ${shortDate(toDate(monthAgo['date']))}', m(nowWorth), nowWorth - base, base));
    }
    final invested = toDouble(now['invested']), holdings = toDouble(now['holdings']);
    if (invested > 0) {
      rows.add(line('Investments: put in → worth now', m(invested), 'gain so far', m(holdings), holdings - invested, invested));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ...rows,
          if (rows.isEmpty || first == null || first['date'] == now['date'])
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Net worth today: ${m(nowWorth)}. Finverse notes it each day you open the app, so how it grows over time will show up here.',
                style: muted,
              ),
            ),
        ]),
      ),
    );
  }
}

class _SinceCard extends StatelessWidget {
  const _SinceCard({required this.since});
  final Json since;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
    final income = toDouble(since['income']), saved = toDouble(since['saved']);
    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(label)),
            Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'From ${displayDate(toDate(since['first_date']))} · ${since['days']} days recorded',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 6),
          row('Earned', m(income), color: AppColors.income),
          row('Spent', m(since['expense']), color: AppColors.expense),
          row('Saved', income > 0 ? '${m(saved)} · ${(saved / income * 100).round()}%' : m(saved), color: saved >= 0 ? AppColors.income : AppColors.expense),
          const Divider(),
          row('Average earned a month', m(since['avg_month_income'])),
          row('Average spent a month', m(since['avg_month_expense'])),
        ]),
      ),
    );
  }
}
