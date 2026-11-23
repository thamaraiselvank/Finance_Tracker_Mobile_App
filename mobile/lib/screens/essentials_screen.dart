import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

Color statusColor(String? status) {
  final s = (status ?? '').toLowerCase();
  if (s.contains('excellent') || s.contains('good') || s.contains('adequate') || s.contains('healthy')) return AppColors.income;
  if (s.contains('getting') || s.contains('moderate') || s.contains('partial') || s.contains('fair')) return AppColors.warning;
  return AppColors.expense;
}

/// Financial essentials: emergency fund, savings rate, insurance cover, debt ratio.
class EssentialsScreen extends StatelessWidget {
  const EssentialsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Financial health')),
      body: AsyncView<Map<String, dynamic>>(
        load: () async => Map<String, dynamic>.from(await context.api.get('/essentials/health-check')),
        builder: (context, h, reload) {
          final state = context.watch<AppState>();
          final theme = Theme.of(context);
          String m(dynamic v) => state.money.format(v, hidden: state.hideAmounts);
          final score = toDouble(h['overall_health_score']);
          final runway = toDouble(h['emergency_runway_months']);
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(children: [
                  SizedBox(
                    width: 86,
                    height: 86,
                    child: Stack(alignment: Alignment.center, children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: (score / 10).clamp(0, 1).toDouble(),
                          strokeWidth: 9,
                          color: statusColor(h['health_score_status']),
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                      Text(score.toStringAsFixed(1), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Overall score (out of 10)', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
                      const SizedBox(height: 4),
                      Text(h['health_score_status']?.toString() ?? '—', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: statusColor(h['health_score_status']))),
                      const SizedBox(height: 4),
                      Text('Based on your profile, accounts, insurance and debts.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                    ]),
                  ),
                ]),
              ),
            ),
            _Check(
              icon: Icons.savings_outlined,
              title: 'Emergency fund',
              status: h['emergency_fund_status'],
              headline: '${runway.toStringAsFixed(1)} months of expenses',
              progress: runway / 6,
              lines: [
                'Liquid savings: ${m(h['liquid_assets'])}',
                'Monthly expenses: ${m(h['monthly_expense'])}',
                'Aim for at least 6 months of expenses in easy-to-access savings.',
              ],
            ),
            _Check(
              icon: Icons.trending_up,
              title: 'Savings rate',
              status: h['savings_rate_status'],
              headline: '${percent(h['savings_rate_pct'], digits: 0)} saved (target ${percent(h['intended_savings_rate_pct'], digits: 0)})',
              progress: toDouble(h['intended_savings_rate_pct']) > 0 ? toDouble(h['savings_rate_pct']) / toDouble(h['intended_savings_rate_pct']) : 0,
              lines: [
                'Monthly income: ${m(h['monthly_income'])}',
                'Actual monthly spending: ${m(h['actual_monthly_expense'])}',
                if (toDouble(h['time_to_fi_years']) > 0) 'At this rate, financial independence in about ${toDouble(h['time_to_fi_years']).toStringAsFixed(0)} years.',
              ],
            ),
            _Check(
              icon: Icons.favorite_outline,
              title: 'Term life cover',
              status: h['term_cover_status'],
              headline: '${m(h['term_cover'])} of ${m(h['ideal_term_cover'])}',
              progress: toDouble(h['ideal_term_cover']) > 0 ? toDouble(h['term_cover']) / toDouble(h['ideal_term_cover']) : 0,
              lines: ['Suggested cover: ${h['term_cover_formula'] ?? '25 × annual expenses'}.'],
            ),
            _Check(
              icon: Icons.local_hospital_outlined,
              title: 'Health insurance',
              status: h['health_cover_status'],
              headline: '${m(h['health_cover'])} of ${m(h['recommended_health_cover'])}',
              progress: toDouble(h['recommended_health_cover']) > 0 ? toDouble(h['health_cover']) / toDouble(h['recommended_health_cover']) : 0,
              lines: ['Dependents: ${toInt(h['dependents_count'])}'],
            ),
            _Check(
              icon: Icons.balance,
              title: 'Debt ratio',
              status: h['debt_ratio_status'],
              headline: '${percent(h['debt_ratio_pct'], digits: 0)} of assets',
              progress: null,
              lines: ['Assets: ${m(h['total_assets'])}', 'Liabilities: ${m(h['total_liabilities'])}', 'Keeping debts under 30–40% of assets is generally healthier.'],
            ),
            const SizedBox(height: 8),
            Text(
              'These are general estimates from the information you have entered, not financial advice. Keep your profile up to date for better results.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ]);
        },
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.icon, required this.title, required this.status, required this.headline, required this.progress, required this.lines});
  final IconData icon;
  final String title;
  final dynamic status;
  final String headline;
  final double? progress;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = statusColor(status?.toString());
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(status?.toString() ?? '—', style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(headline, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (progress != null) ...[const SizedBox(height: 8), ProgressBar(value: progress!, color: color)],
          const SizedBox(height: 8),
          for (final l in lines)
            Padding(padding: const EdgeInsets.only(top: 2), child: Text(l, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline))),
        ]),
      ),
    );
  }
}
