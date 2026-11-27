import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';
import 'wealth_screen.dart' show assetClasses;

const _accountTypes = {
  'SAVINGS': 'Savings',
  'CURRENT': 'Current',
  'CREDIT_CARD': 'Credit card',
  'WALLET': 'Wallet',
  'FIXED_DEPOSIT': 'Fixed deposit',
  'INVESTMENT': 'Investment',
  'OTHER': 'Other',
};

/// Net worth over time, with a choice of time frame (1M, 3M, 6M, 1Y, All),
/// the change over that time, and an optional assets / debts view.
class NetWorthTrendCard extends StatefulWidget {
  const NetWorthTrendCard({super.key, required this.overview});
  final Json overview;

  @override
  State<NetWorthTrendCard> createState() => _NetWorthTrendCardState();
}

/// Time frames: label -> days back (null = everything).
const _ranges = {'1M': 30, '3M': 91, '6M': 182, '1Y': 365, 'All': null};

class _NetWorthTrendCardState extends State<NetWorthTrendCard> {
  String _range = '3M';
  bool _split = false;

  List<Json> get _history => (widget.overview['history'] as List).cast<Json>();

  List<Json> _inRange(List<Json> history) {
    final days = _ranges[_range];
    if (days == null || history.isEmpty) return history;
    final last = toDate(history.last['date'])!;
    final from = last.subtract(Duration(days: days));
    return history.where((h) => !toDate(h['date'])!.isBefore(from)).toList();
  }

  @override
  void initState() {
    super.initState();
    // Start on the shortest range that has a few readings.
    final h = _history;
    for (final r in _ranges.keys) {
      _range = r;
      if (_inRange(h).length >= 5) break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final history = _history;
    final shown = _inRange(history);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    String c(dynamic v) => state.money.compact(v, hidden: state.hideAmounts);

    if (history.length < 2) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Finverse notes your net worth each day you open the app. After a few days, a chart of how it grows shows up here.',
            style: muted,
          ),
        ),
      );
    }

    final first = shown.isEmpty ? null : shown.first;
    final last = shown.isEmpty ? null : shown.last;
    final diff = first == null ? 0.0 : toDouble(last!['net_worth']) - toDouble(first['net_worth']);
    final base = first == null ? 0.0 : toDouble(first['net_worth']).abs();
    final color = diff >= 0 ? AppColors.income : AppColors.expense;
    final span = first == null ? 0 : toDate(last!['date'])!.difference(toDate(first['date'])!).inDays;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c(last?['net_worth'] ?? history.last['net_worth']), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                if (shown.length >= 2)
                  Row(children: [
                    Icon(diff >= 0 ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: color),
                    Flexible(
                      child: Text(
                        ' ${c(diff.abs())}${base > 0 ? ' (${(diff / base * 100).abs().toStringAsFixed(1)}%)' : ''} · ${_spanLabel(span)}',
                        style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ]),
              ]),
            ),
            IconButton(
              tooltip: _split ? 'Show net worth only' : 'Show assets and debts',
              onPressed: () => setState(() => _split = !_split),
              icon: Icon(_split ? Icons.show_chart : Icons.stacked_line_chart),
            ),
          ]),
          const SizedBox(height: 10),
          SizedBox(
            height: 190,
            child: shown.length < 2
                ? Center(child: Text('Not enough readings in this time frame yet', style: muted))
                : _chart(context, shown, color),
          ),
          if (_split && shown.length >= 2) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 14, children: [
              _legend(theme.colorScheme.primary, 'Net worth'),
              _legend(AppColors.income, 'Assets'),
              _legend(AppColors.expense, 'Debts'),
            ]),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              segments: [for (final r in _ranges.keys) ButtonSegment(value: r, label: Text(r))],
              selected: {_range},
              onSelectionChanged: (v) => setState(() => _range = v.first),
            ),
          ),
        ]),
      ),
    );
  }

  static String _spanLabel(int days) {
    if (days < 1) return 'today';
    if (days < 45) return 'in $days day${days == 1 ? '' : 's'}';
    if (days < 340) return 'in ${(days / 30.4).round()} months';
    final years = days / 365;
    return years < 1.5 ? 'in a year' : 'in ${years.toStringAsFixed(1)} years';
  }

  Widget _legend(Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 3, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);

  Widget _chart(BuildContext context, List<Json> history, Color color) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final first = toDate(history.first['date'])!;
    double x(Json h) => toDate(h['date'])!.difference(first).inDays.toDouble();
    List<FlSpot> line(String key, {double sign = 1}) => [for (final h in history) FlSpot(x(h), sign * toDouble(h[key]))];

    final net = line('net_worth');
    final assets = _split ? line('assets') : const <FlSpot>[];
    final debts = _split ? line('liabilities') : const <FlSpot>[];
    final all = [...net, ...assets, ...debts];
    var minY = all.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    var maxY = all.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() < 1 ? (maxY.abs() * 0.05 + 1) : (maxY - minY) * 0.12;
    minY -= pad;
    maxY += pad;
    if (_split && minY > 0) minY = 0;
    final lastX = net.last.x;
    final netColor = _split ? theme.colorScheme.primary : color;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline, fontSize: 10);

    LineChartBarData bar(List<FlSpot> spots, Color c, {bool fill = false, double width = 2.5, bool dashed = false}) => LineChartBarData(
          spots: spots,
          isCurved: true,
          preventCurveOverShooting: true,
          color: c,
          barWidth: width,
          dashArray: dashed ? [5, 4] : null,
          dotData: FlDotData(show: spots.length < 3),
          belowBarData: BarAreaData(
            show: fill,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [c.withValues(alpha: 0.28), c.withValues(alpha: 0.0)],
            ),
          ),
        );

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        minX: 0,
        maxX: lastX <= 0 ? 1 : lastX,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: (maxY - minY) / 4 <= 0 ? 1 : (maxY - minY) / 4,
          getDrawingHorizontalLine: (_) => FlLine(color: theme.dividerColor.withValues(alpha: 0.25), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: !state.hideAmounts,
              reservedSize: 46,
              interval: (maxY - minY) / 4 <= 0 ? 1 : (maxY - minY) / 4,
              getTitlesWidget: (value, meta) => value == meta.max || value == meta.min
                  ? const SizedBox.shrink()
                  : Text(state.money.compact(value), style: labelStyle, maxLines: 1),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: lastX <= 0 ? 1 : (lastX / 3).clamp(1, double.infinity),
              getTitlesWidget: (value, meta) {
                final d = first.add(Duration(days: value.round()));
                final long = lastX > 300;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(long ? DateFormat("MMM ''yy").format(d) : shortDate(d), style: labelStyle),
                );
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
                  '${i == 0 ? '${shortDate(first.add(Duration(days: spots[i].x.round())))}\n' : ''}'
                  '${_split ? '${switch (spots[i].barIndex) { 0 => 'Net worth', 1 => 'Assets', _ => 'Debts' }}: ' : ''}'
                  '${state.money.compact(spots[i].y, hidden: state.hideAmounts)}',
                  TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                ),
            ],
          ),
        ),
        lineBarsData: [
          bar(net, netColor, fill: true, width: 3),
          if (_split) bar(assets, AppColors.income, width: 2, dashed: true),
          if (_split) bar(debts, AppColors.expense, width: 2, dashed: true),
        ],
      ),
      duration: const Duration(milliseconds: 350),
    );
  }
}

/// Safety cushion, debt load, and how much of the wealth is ready money.
class WealthHealthCard extends StatelessWidget {
  const WealthHealthCard({super.key, required this.overview});
  final Json overview;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    String m(dynamic v) => state.money.compact(v, hidden: state.hideAmounts);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    final emergency = overview['emergency'] as Json?;
    final debt = overview['debt'] as Json;
    final split = overview['split'] as Json;

    Widget meter(String title, String value, String note, double fraction, Color color) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 6,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 4),
            Text(note, style: muted),
          ]),
        );

    final rows = <Widget>[];
    if (emergency != null) {
      final months = toDouble(emergency['months']);
      final color = months >= 6 ? AppColors.income : (months >= 3 ? theme.colorScheme.primary : AppColors.expense);
      rows.add(meter(
        'Safety cushion',
        '${months.toStringAsFixed(months < 10 ? 1 : 0)} months',
        'Bank balances and cash-like savings (${m(emergency['cash'])}) against your usual spending of ${m(emergency['monthly_spend'])} a month. '
            '${months >= 6 ? 'Comfortable.' : (months >= 3 ? 'Good; 6 months is even safer.' : 'Aim for 3 to 6 months.')}',
        months / 6,
        color,
      ));
    }
    final debtPct = debt['debt_to_assets'] == null ? null : toDouble(debt['debt_to_assets']);
    if (debtPct != null && toDouble(debt['liabilities']) > 0) {
      final color = debtPct <= 30 ? AppColors.income : (debtPct <= 50 ? theme.colorScheme.primary : AppColors.expense);
      rows.add(meter(
        'Debt compared with what you own',
        '${debtPct.toStringAsFixed(0)}%',
        'You owe ${m(debt['liabilities'])} against ${m(debt['assets'])} of assets. ${debtPct <= 30 ? 'Low.' : (debtPct <= 50 ? 'Moderate.' : 'High: paying down debt would help.')}',
        debtPct / 100,
        color,
      ));
    }
    final emiPct = debt['emi_to_income'] == null ? null : toDouble(debt['emi_to_income']);
    if (emiPct != null && toDouble(debt['emi']) > 0) {
      final color = emiPct <= 30 ? AppColors.income : (emiPct <= 40 ? theme.colorScheme.primary : AppColors.expense);
      rows.add(meter(
        'EMIs out of income',
        '${emiPct.toStringAsFixed(0)}%',
        '${m(debt['emi'])} a month in EMIs against about ${m(debt['monthly_income'])} coming in. Under 30–40% is healthy.',
        emiPct / 100,
        color,
      ));
    }
    if (toDouble(debt['cards_owed']) > 0) {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('Credit cards: ${m(debt['cards_owed'])} to pay.', style: const TextStyle(fontWeight: FontWeight.w600)),
      ));
    }

    final bank = toDouble(split['bank']), ready = toDouble(split['ready']), locked = toDouble(split['locked']);
    final total = bank + ready + locked;
    if (total > 0) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Where your money sits', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 10,
              child: Row(children: [
                if (bank > 0) Expanded(flex: (bank / total * 1000).round().clamp(1, 1000), child: Container(color: const Color(0xFF0EA5E9))),
                if (ready > 0) Expanded(flex: (ready / total * 1000).round().clamp(1, 1000), child: Container(color: AppColors.income)),
                if (locked > 0) Expanded(flex: (locked / total * 1000).round().clamp(1, 1000), child: Container(color: const Color(0xFFF59E0B))),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          _legend(const Color(0xFF0EA5E9), 'In bank accounts', m(bank), bank / total),
          _legend(AppColors.income, 'Investments you can sell quickly', m(ready), ready / total),
          _legend(const Color(0xFFF59E0B), 'Locked in (property, FDs, PPF…)', m(locked), locked / total),
        ]),
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows)));
  }

  Widget _legend(Color color, String label, String value, double share) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          Text('$value · ${(share * 100).round()}%', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Best and worst holdings, and a note when one holding is a big share.
class PerformersCard extends StatelessWidget {
  const PerformersCard({super.key, required this.overview});
  final Json overview;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final gainers = (overview['gainers'] as List).cast<Json>();
    final losers = (overview['losers'] as List).cast<Json>();
    final concentration = overview['concentration'] as Json?;
    final showConcentration = concentration != null && toDouble(concentration['share']) >= 25;
    if (gainers.isEmpty && losers.isEmpty && !showConcentration) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

    Widget row(Json h) {
      final up = toDouble(h['pnl']) >= 0;
      final color = up ? AppColors.income : AppColors.expense;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(up ? Icons.trending_up : Icons.trending_down, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(assetClasses[h['asset_class']] ?? '', style: muted),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${up ? '+' : ''}${toDouble(h['pnl_pct']).toStringAsFixed(1)}%', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
            Text('${up ? '+' : '−'}${state.money.compact(toDouble(h['pnl']).abs(), hidden: state.hideAmounts)}', style: muted),
          ]),
        ]),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (gainers.isNotEmpty) ...[
            Text('Doing best', style: theme.textTheme.labelMedium?.copyWith(color: AppColors.income)),
            for (final h in gainers) row(h),
          ],
          if (losers.isNotEmpty) ...[
            if (gainers.isNotEmpty) const Divider(),
            Text('Down so far', style: theme.textTheme.labelMedium?.copyWith(color: AppColors.expense)),
            for (final h in losers) row(h),
          ],
          if (showConcentration) ...[
            if (gainers.isNotEmpty || losers.isNotEmpty) const Divider(),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.pie_chart_outline, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${concentration['name']} is ${toDouble(concentration['share']).round()}% of your investments. '
                  'Spreading money across more holdings lowers the risk if one of them falls.',
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Every active account and its balance.
class AccountBalancesCard extends StatelessWidget {
  const AccountBalancesCard({super.key, required this.overview});
  final Json overview;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final accounts = (overview['accounts'] as List).cast<Json>();
    if (accounts.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(children: [
        for (final a in accounts)
          ListTile(
            dense: true,
            leading: Icon(
              a['type'] == 'CREDIT_CARD' ? Icons.credit_card : (a['type'] == 'WALLET' ? Icons.account_balance_wallet_outlined : Icons.account_balance_outlined),
              color: theme.colorScheme.primary,
            ),
            title: Text(a['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_accountTypes[a['type']] ?? ''),
            trailing: Text(
              state.money.format(a['balance'], hidden: state.hideAmounts),
              style: TextStyle(fontWeight: FontWeight.w700, color: toDouble(a['balance']) < 0 ? AppColors.expense : null),
            ),
          ),
      ]),
    );
  }
}

/// The extra Wealth sections, in order. Empty when there is nothing to show.
List<Widget> wealthOverviewSections(Json? overview) {
  if (overview == null) return const [];
  return [
    const SectionHeader('Net worth over time'),
    NetWorthTrendCard(overview: overview),
    const SectionHeader('How healthy is it?'),
    WealthHealthCard(overview: overview),
    if ((overview['gainers'] as List).isNotEmpty ||
        (overview['losers'] as List).isNotEmpty ||
        toDouble((overview['concentration'] as Json?)?['share']) >= 25) ...[
      const SectionHeader('Best and worst holdings'),
      PerformersCard(overview: overview),
    ],
    if ((overview['accounts'] as List).isNotEmpty) ...[
      const SectionHeader('Accounts'),
      AccountBalancesCard(overview: overview),
    ],
  ];
}
