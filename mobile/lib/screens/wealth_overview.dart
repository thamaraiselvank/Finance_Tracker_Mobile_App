import 'package:fl_chart/fl_chart.dart';
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

/// Net worth over the last year, with the change over a month, three
/// months and since the first reading.
class NetWorthTrendCard extends StatelessWidget {
  const NetWorthTrendCard({super.key, required this.overview});
  final Json overview;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final history = (overview['history'] as List).cast<Json>();
    final changes = overview['changes'] as Json;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    String c(dynamic v) => state.money.compact(v, hidden: state.hideAmounts);

    Widget chip(String label, Json? change) {
      if (change == null) return const SizedBox.shrink();
      final diff = toDouble(change['to']) - toDouble(change['from']);
      final base = toDouble(change['from']).abs();
      final color = diff >= 0 ? AppColors.income : AppColors.expense;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(
            '${diff >= 0 ? '+' : '−'}${c(diff.abs())}${base > 0 ? ' · ${(diff / base * 100).abs().toStringAsFixed(1)}%' : ''}',
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ]),
      );
    }

    final chips = [
      chip('1 month', changes['month'] as Json?),
      chip('3 months', changes['quarter'] as Json?),
      if (changes['start'] != null) chip('Since ${shortDate(toDate((changes['start'] as Json)['date']))}', changes['start'] as Json?),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (history.length >= 2) ...[
            SizedBox(height: 150, child: _chart(context, history)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ] else
            Text(
              'Finverse notes your net worth each day you open the app. After a few days, a chart of how it grows shows up here.',
              style: muted,
            ),
        ]),
      ),
    );
  }

  Widget _chart(BuildContext context, List<Json> history) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final first = toDate(history.first['date'])!;
    final spots = [
      for (final h in history) FlSpot(toDate(h['date'])!.difference(first).inDays.toDouble(), toDouble(h['net_worth'])),
    ];
    var minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    var maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() < 1 ? (maxY.abs() * 0.05 + 1) : (maxY - minY) * 0.1;
    minY -= pad;
    maxY += pad;
    final up = spots.last.y >= spots.first.y;
    final color = up ? AppColors.income : AppColors.expense;
    return LineChart(LineChartData(
      minY: minY,
      maxY: maxY,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 20,
            interval: (spots.last.x / 3).clamp(1, double.infinity),
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(shortDate(first.add(Duration(days: value.round()))),
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ),
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => theme.colorScheme.inverseSurface,
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem(
                '${shortDate(first.add(Duration(days: s.x.round())))}\n${state.money.compact(s.y, hidden: state.hideAmounts)}',
                TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
              ),
          ],
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          preventCurveOverShooting: true,
          color: color,
          barWidth: 2.5,
          dotData: FlDotData(show: spots.length < 3),
          belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.12)),
        ),
      ],
    ));
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
