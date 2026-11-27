import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../services/services.dart';

/// Charts under a calculator's result, so the numbers are easy to feel:
///  * SIP / lumpsum: what you put in vs what it earns, and growth year by year
///  * EMI: principal vs interest, and how each year's payments split
///  * CAGR: the value growing at that rate each year
///  * FIRE: your projected savings vs the amount you need, by age
List<Widget> calculatorCharts(CalculatorKind kind, Json result, Json input) {
  switch (kind) {
    case CalculatorKind.sip:
    case CalculatorKind.lumpsum:
      final invested = toDouble(result['total_invested']);
      final returns = toDouble(result['estimated_returns']);
      final schedule = _rows(result['yearly_schedule']);
      return [
        if (invested > 0)
          _Split(
            title: 'Where the final amount comes from',
            parts: [('You put in', invested, AppColors.info), ('Growth', math.max(0, returns), AppColors.income)],
          ),
        if (schedule.length >= 2)
          _StackedBars(
            title: 'Year by year',
            note: 'Blue is what you put in, green is the growth on it.',
            labels: [for (final r in schedule) 'Y${toInt(r['year'])}'],
            bottom: [for (final r in schedule) toDouble(r['total_invested'])],
            top: [for (final r in schedule) math.max(0, toDouble(r['future_value']) - toDouble(r['total_invested']))],
            bottomLabel: 'Put in',
            topLabel: 'Growth',
            bottomColor: AppColors.info,
            topColor: AppColors.income,
          ),
      ];
    case CalculatorKind.emi:
      final principal = toDouble(result['total_payment']) - toDouble(result['total_interest']);
      final interest = toDouble(result['total_interest']);
      final months = _rows(result['amortization_schedule']);
      final years = <(double, double, double)>[]; // principal, interest, balance at year end
      for (var i = 0; i < months.length; i += 12) {
        final year = months.sublist(i, math.min(i + 12, months.length));
        years.add((
          year.fold(0.0, (s, m) => s + toDouble(m['principal_paid'])),
          year.fold(0.0, (s, m) => s + toDouble(m['interest_paid'])),
          toDouble(year.last['remaining_balance']),
        ));
      }
      return [
        if (principal > 0)
          _Split(
            title: 'What you pay back',
            parts: [('Loan amount', principal, AppColors.info), ('Interest', interest, AppColors.expense)],
          ),
        if (years.length >= 2) ...[
          _StackedBars(
            title: 'Each year\'s payments',
            note: 'Early years go mostly to interest (red). Later, most of the EMI pays off the loan (blue).',
            labels: [for (var i = 0; i < years.length; i++) 'Y${i + 1}'],
            bottom: [for (final y in years) y.$1],
            top: [for (final y in years) y.$2],
            bottomLabel: 'Loan paid off',
            topLabel: 'Interest',
            bottomColor: AppColors.info,
            topColor: AppColors.expense,
          ),
          _Lines(
            title: 'Loan left to pay',
            labels: [for (var i = 0; i <= years.length; i++) 'Y$i'],
            series: [
              ('Loan left', AppColors.expense, [toDouble(input['loan_amount']), for (final y in years) y.$3]),
            ],
          ),
        ],
      ];
    case CalculatorKind.cagr:
      final start = toDouble(input['initial_value']);
      final years = toDouble(input['duration_years']);
      final rate = toDouble(result['cagr_percentage']) / 100;
      final whole = years.ceil().clamp(1, 60);
      if (start <= 0 || years <= 0) return const [];
      return [
        _Lines(
          title: 'Growing at ${toDouble(result['cagr_percentage']).toStringAsFixed(2)}% a year',
          labels: [for (var y = 0; y <= whole; y++) 'Y$y'],
          series: [
            ('Value', AppColors.income, [for (var y = 0; y <= whole; y++) start * math.pow(1 + rate, math.min(y.toDouble(), years))]),
            ('Started with', AppColors.info, [for (var y = 0; y <= whole; y++) start]),
          ],
        ),
      ];
    case CalculatorKind.fire:
      final rows = _rows(result['yearly_progression']);
      if (rows.length < 2) return const [];
      final reachedAt = rows.where((r) => r['is_fire_reached'] == true).map((r) => toInt(r['age'])).firstOrNull;
      return [
        _Lines(
          title: 'Your savings vs what you need',
          note: reachedAt == null
              ? 'The green line stays below the target in this plan. Investing more each month lifts it.'
              : 'The lines cross at age $reachedAt: from then on your savings can pay for your life.',
          labels: [for (final r in rows) '${toInt(r['age'])}'],
          series: [
            ('Your savings', AppColors.income, [for (final r in rows) toDouble(r['projected_portfolio'])]),
            ('Amount needed', AppColors.warning, [for (final r in rows) toDouble(r['target_fire_corpus'])]),
          ],
        ),
      ];
  }
}

List<Json> _rows(Object? list) => (list as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

TextStyle? _axis(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline, fontSize: 10);

/// Shows only a few labels along the bottom so they never overlap.
bool _showLabel(int i, int n) {
  if (n <= 8) return true;
  final step = (n / 6).ceil();
  return i % step == 0 || i == n - 1;
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, this.note, required this.child, this.legend = const []});
  final String title;
  final String? note;
  final Widget child;
  final List<(String, Color)> legend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          child,
          if (legend.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 4, children: [
              for (final (label, color) in legend)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 4),
                  Text(label, style: const TextStyle(fontSize: 12)),
                ]),
            ]),
          ],
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ]),
      ),
    );
  }
}

/// A donut of two (or more) parts with their amounts and shares.
class _Split extends StatelessWidget {
  const _Split({required this.title, required this.parts});
  final String title;
  final List<(String, double, Color)> parts;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final total = parts.fold<double>(0, (s, p) => s + p.$2);
    if (total <= 0) return const SizedBox.shrink();
    return _ChartCard(
      title: title,
      child: Row(children: [
        SizedBox(
          width: 130,
          height: 130,
          child: Stack(alignment: Alignment.center, children: [
            PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 40,
                startDegreeOffset: -90,
                sections: [
                  for (final (_, value, color) in parts)
                    PieChartSectionData(value: math.max(value, total * 0.001), color: color, radius: 22, showTitle: false),
                ],
              ),
              duration: const Duration(milliseconds: 400),
            ),
            Text(state.money.compact(total), style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (label, value, color) in parts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: theme.textTheme.bodySmall),
                      Text(state.money.compact(value), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ),
                  Text('${(value / total * 100).toStringAsFixed(0)}%', style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w800)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Bars made of two stacked parts, one per year.
class _StackedBars extends StatelessWidget {
  const _StackedBars({
    required this.title,
    this.note,
    required this.labels,
    required this.bottom,
    required this.top,
    required this.bottomLabel,
    required this.topLabel,
    required this.bottomColor,
    required this.topColor,
  });
  final String title;
  final String? note;
  final List<String> labels;
  final List<double> bottom, top;
  final String bottomLabel, topLabel;
  final Color bottomColor, topColor;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final n = labels.length;
    final maxY = [for (var i = 0; i < n; i++) bottom[i] + top[i]].fold<double>(0, math.max);
    final width = (220 / n).clamp(3.0, 18.0);
    return _ChartCard(
      title: title,
      note: note,
      legend: [(bottomLabel, bottomColor), (topLabel, topColor)],
      child: SizedBox(
        height: 190,
        child: BarChart(
          BarChartData(
            maxY: maxY <= 0 ? 1 : maxY * 1.08,
            alignment: BarChartAlignment.spaceAround,
            borderData: FlBorderData(show: false),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: maxY <= 0 ? 1 : maxY / 4,
              getDrawingHorizontalLine: (_) => FlLine(color: theme.dividerColor.withValues(alpha: 0.25), strokeWidth: 1),
            ),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: maxY <= 0 ? 1 : maxY / 4,
                  getTitlesWidget: (v, meta) => v == meta.max ? const SizedBox.shrink() : Text(state.money.compact(v), style: _axis(context)),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 20,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= n || !_showLabel(i, n)) return const SizedBox.shrink();
                    return Padding(padding: const EdgeInsets.only(top: 4), child: Text(labels[i], style: _axis(context)));
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                fitInsideHorizontally: true,
                fitInsideVertically: true,
                getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                  '${labels[group.x]}\n$bottomLabel: ${state.money.compact(bottom[group.x])}\n$topLabel: ${state.money.compact(top[group.x])}',
                  TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < n; i++)
                BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                    toY: bottom[i] + top[i],
                    width: width,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                    rodStackItems: [
                      BarChartRodStackItem(0, bottom[i], bottomColor),
                      BarChartRodStackItem(bottom[i], bottom[i] + top[i], topColor),
                    ],
                  ),
                ]),
            ],
          ),
          duration: const Duration(milliseconds: 400),
        ),
      ),
    );
  }
}

/// One or more lines over the same points (years or ages).
class _Lines extends StatelessWidget {
  const _Lines({required this.title, this.note, required this.labels, required this.series});
  final String title;
  final String? note;
  final List<String> labels;
  final List<(String, Color, List<double>)> series;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final n = labels.length;
    final values = [for (final s in series) ...s.$3];
    final maxY = values.fold<double>(0, math.max);
    return _ChartCard(
      title: title,
      note: note,
      legend: series.length > 1 ? [for (final s in series) (s.$1, s.$2)] : const [],
      child: SizedBox(
        height: 190,
        child: LineChart(
          LineChartData(
            minY: 0,
            maxY: maxY <= 0 ? 1 : maxY * 1.08,
            minX: 0,
            maxX: (n - 1).toDouble(),
            borderData: FlBorderData(show: false),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: maxY <= 0 ? 1 : maxY / 4,
              getDrawingHorizontalLine: (_) => FlLine(color: theme.dividerColor.withValues(alpha: 0.25), strokeWidth: 1),
            ),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: maxY <= 0 ? 1 : maxY / 4,
                  getTitlesWidget: (v, meta) => v == meta.max ? const SizedBox.shrink() : Text(state.money.compact(v), style: _axis(context)),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 20,
                  interval: 1,
                  getTitlesWidget: (v, meta) {
                    final i = v.round();
                    if (i < 0 || i >= n || v != i.toDouble() || !_showLabel(i, n)) return const SizedBox.shrink();
                    return Padding(padding: const EdgeInsets.only(top: 4), child: Text(labels[i], style: _axis(context)));
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                fitInsideHorizontally: true,
                fitInsideVertically: true,
                getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                getTooltipItems: (spots) => [
                  for (var i = 0; i < spots.length; i++)
                    LineTooltipItem(
                      '${i == 0 ? '${labels[spots[i].x.round()]}\n' : ''}${series[spots[i].barIndex].$1}: ${state.money.compact(spots[i].y)}',
                      TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              for (var s = 0; s < series.length; s++)
                LineChartBarData(
                  spots: [for (var i = 0; i < series[s].$3.length; i++) FlSpot(i.toDouble(), series[s].$3[i])],
                  isCurved: true,
                  preventCurveOverShooting: true,
                  color: series[s].$2,
                  barWidth: s == 0 ? 3 : 2,
                  dashArray: s == 0 ? null : [5, 4],
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: s == 0,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [series[s].$2.withValues(alpha: 0.25), series[s].$2.withValues(alpha: 0.0)],
                    ),
                  ),
                ),
            ],
          ),
          duration: const Duration(milliseconds: 400),
        ),
      ),
    );
  }
}
