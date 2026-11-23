/// Financial health check (five pillars, score out of 10), translated from
/// backend/app/services/health_engine.py. Checked against Python in
/// test/parity (health.json).
library;

import 'dart:convert';
import 'dart:math' as math;

import '../services/errors.dart';
import '../services/services.dart';
import 'local_db.dart';
import 'py_round.dart';
import 'validate.dart';

double _d(Object? v) => v == null ? 0.0 : (v as num).toDouble();

double timeToFiFromSavingsRate(double savingsRatePct, {double returnRate = 0.08, double swr = 0.04}) {
  if (savingsRatePct <= 0) return 99.0;
  if (savingsRatePct >= 95) return 2.0;
  final s = savingsRatePct / 100.0;
  final years = math.log(((1 - s) / s) * (returnRate / swr) + 1.0) / math.log(1.0 + returnRate);
  return pyRound(math.max(1.0, math.min(75.0, years)), 1);
}

String _insuranceKind(Object? value) {
  if (value == null) return 'OTHER';
  final n = value.toString().trim().toUpperCase().replaceAll(' ', '_');
  if (const {'TERM', 'TERM_LIFE', 'LIFE', 'TERM_INSURANCE'}.contains(n)) return 'TERM';
  if (const {'HEALTH', 'HEALTH_INSURANCE'}.contains(n)) return 'HEALTH';
  if (const {'CRITICAL_ILLNESS', 'CRITICAL_ILLNESS_INSURANCE'}.contains(n)) return 'CRITICAL_ILLNESS';
  return n;
}

/// The health check for already-loaded data. Inputs use the backend's
/// field names: [user] (profile), [tx] (`total_income`, `total_expense`,
/// `active_months` over the last 90 days), [assets], [accounts], [debts],
/// [policies].
Json computeFinancialHealth({
  required Map<String, dynamic> user,
  required Map<String, dynamic> tx,
  required List<Map<String, dynamic>> assets,
  required List<Map<String, dynamic>> accounts,
  required List<Map<String, dynamic>> debts,
  required List<Map<String, dynamic>> policies,
}) {
  final profileIncome = _d(user['monthly_income']);
  final profileExpense = _d(user['monthly_expense']);
  final emergencyFund = _d(user['emergency_fund_amount']);
  final targetSavingsRate = _d(user['target_savings_rate']);
  final dependents = (user['dependents_count'] as num?)?.toInt() ?? 0;

  final activeMonths = math.max(1, (tx['active_months'] as num?)?.toInt() ?? 1);
  final avgIncome = _d(tx['total_income']) / activeMonths;
  final avgExpense = _d(tx['total_expense']) / activeMonths;
  final monthlyIncome = avgIncome > 0 ? avgIncome : profileIncome;
  final monthlyExpense = avgExpense > 0 ? avgExpense : profileExpense;
  final annualExpense = monthlyExpense * 12.0;

  var totalAssets = 0.0;
  var liquidAssets = 0.0;
  for (final a in assets) {
    final value = _d(a['current_value']);
    totalAssets += value;
    final liquid = const {'CASH_EQUIVALENT', 'FIXED_INCOME'}.contains(a['asset_class']) ||
        (a['sub_type'] as String? ?? '').toLowerCase().contains('liquid') ||
        (a['name'] as String? ?? '').toLowerCase().contains('savings');
    if (liquid) liquidAssets += value;
  }
  var bank = 0.0;
  for (final a in accounts) {
    bank += _d(a['balance']);
  }
  totalAssets += bank;
  final totalLiquid = emergencyFund > 0 ? emergencyFund : liquidAssets + bank;

  var totalLiabilities = 0.0;
  for (final d in debts) {
    totalLiabilities += _d(d['current_outstanding']);
  }

  final active = policies.where((p) => const {'ACTIVE', 'RENEWED', 'PENDING', 'PAID'}.contains((p['status'] ?? 'ACTIVE').toString().toUpperCase()));
  var termCover = 0.0;
  var healthCover = 0.0;
  for (final p in active) {
    final kind = _insuranceKind(p['insurance_type'] ?? p['policy_type']);
    if (kind == 'TERM') termCover += _d(p['sum_insured']);
    if (kind == 'HEALTH' || kind == 'CRITICAL_ILLNESS') healthCover += _d(p['sum_insured']);
  }

  final hasData = monthlyIncome > 0 || monthlyExpense > 0 || totalAssets > 0 || totalLiabilities > 0 || termCover > 0 || healthCover > 0 || dependents > 0;
  if (!hasData) {
    return {
      'overall_health_score': 0.0, 'health_score_status': 'No Data', 'liquid_assets': 0.0, 'monthly_expense': 0.0,
      'emergency_runway_months': 0.0, 'emergency_fund_status': 'No Data', 'savings_rate_pct': 0.0,
      'intended_savings_rate_pct': targetSavingsRate, 'savings_rate_status': 'No Data', 'monthly_income': 0.0,
      'actual_monthly_expense': 0.0, 'time_to_fi_years': 0.0, 'term_cover': 0.0, 'ideal_term_cover': 0.0,
      'term_cover_status': 'No Data', 'term_cover_formula': '25 * Annual Expense', 'health_cover': 0.0,
      'recommended_health_cover': 0.0, 'health_cover_status': 'No Data', 'dependents_count': 0, 'debt_ratio_pct': 0.0,
      'total_assets': 0.0, 'total_liabilities': 0.0, 'debt_ratio_status': 'No Data',
    };
  }

  // 1. Emergency fund runway.
  final runway = monthlyExpense > 0 ? pyRound(totalLiquid / monthlyExpense, 1) : 0.0;
  final (double efScore, String efStatus) = runway >= 6.0 ? (10.0, 'Good') : runway >= 3.0 ? (6.0, 'Moderate') : (math.max(1.0, runway * 1.5), 'Risky');

  // 2. Savings rate.
  final saved = math.max(0.0, monthlyIncome - monthlyExpense);
  final savingsRate = monthlyIncome > 0 ? pyRound(saved / monthlyIncome * 100.0, 1) : 0.0;
  final timeToFi = monthlyIncome > 0 && monthlyExpense > 0 ? timeToFiFromSavingsRate(savingsRate) : 0.0;
  final (double srScore, String srStatus) = savingsRate >= 40.0
      ? (10.0, 'Excellent')
      : savingsRate >= 20.0
          ? (7.0, 'Good')
          : savingsRate >= 10.0
              ? (4.0, 'Getting There')
              : (2.0, 'Risky');

  // 3. Term cover vs 25 × annual expense.
  final idealTerm = math.max(0.0, pyRound(25.0 * annualExpense, 2));
  final (double termScore, String termStatus) = idealTerm == 0 && monthlyExpense == 0
      ? (0.0, 'No Data')
      : idealTerm == 0 || termCover >= idealTerm
          ? (10.0, 'Good')
          : termCover >= idealTerm * 0.6
              ? (6.0, 'Moderate')
              : (2.0, 'Risky');

  // 4. Health cover (5 lakh single, 10 lakh with dependents, or the covers listed).
  var details = user['health_dependents'] ?? const [];
  if (details is String) {
    try {
      details = jsonDecode(details);
    } catch (_) {
      details = const [];
    }
  }
  final list = details is List ? details : const [];
  final double recommendedHealth;
  if (list.isNotEmpty) {
    var sum = 0.0;
    for (final item in list) {
      sum += _d((item as Map)['cover']);
    }
    recommendedHealth = math.max(500000.0, sum);
  } else {
    recommendedHealth = dependents > 0 ? 1000000.0 : 500000.0;
  }
  final (double healthScore, String healthStatus) = recommendedHealth <= 0
      ? (0.0, 'No Data')
      : healthCover >= recommendedHealth
          ? (10.0, 'Good')
          : healthCover >= 500000.0
              ? (6.0, 'Moderate')
              : (2.0, 'Risky');

  // 5. Debt ratio (% of assets funded by debt).
  final debtRatio = totalAssets > 0 ? pyRound(totalLiabilities / totalAssets * 100.0, 1) : (totalLiabilities > 0 ? 100.0 : 0.0);
  final (double debtScore, String debtStatus) = totalAssets == 0 && totalLiabilities == 0
      ? (0.0, 'No Data')
      : debtRatio <= 20.0
          ? (10.0, 'Good')
          : debtRatio <= 45.0
              ? (6.0, 'Moderate')
              : (2.0, 'Risky');

  final overall = pyRound(efScore * 0.25 + srScore * 0.25 + termScore * 0.15 + healthScore * 0.15 + debtScore * 0.20, 1);
  final overallStatus = overall >= 8.0 ? 'Excellent' : overall >= 6.0 ? 'Good' : overall >= 4.0 ? 'Getting There' : 'Risky';

  return {
    'overall_health_score': overall,
    'health_score_status': overallStatus,
    'liquid_assets': pyRound(totalLiquid, 2),
    'monthly_expense': pyRound(monthlyExpense, 2),
    'emergency_runway_months': runway,
    'emergency_fund_status': efStatus,
    'savings_rate_pct': savingsRate,
    'intended_savings_rate_pct': targetSavingsRate,
    'savings_rate_status': srStatus,
    'monthly_income': pyRound(monthlyIncome, 2),
    'actual_monthly_expense': pyRound(monthlyExpense, 2),
    'time_to_fi_years': timeToFi,
    'term_cover': pyRound(termCover, 2),
    'ideal_term_cover': pyRound(idealTerm, 2),
    'term_cover_status': termStatus,
    'term_cover_formula': '25 * Annual Expense',
    'health_cover': pyRound(healthCover, 2),
    'recommended_health_cover': recommendedHealth,
    'health_cover_status': healthStatus,
    'dependents_count': dependents,
    'debt_ratio_pct': debtRatio,
    'total_assets': pyRound(totalAssets, 2),
    'total_liabilities': pyRound(totalLiabilities, 2),
    'debt_ratio_status': debtStatus,
  };
}

/// Loads the phone's data and runs [computeFinancialHealth].
class LocalEssentialsService implements EssentialsService {
  LocalEssentialsService(this._db, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final DateTime Function() _today;

  @override
  Future<Json> healthCheck() async {
    final p = _db.queryOne('SELECT * FROM profile LIMIT 1');
    if (p == null) throw const NotFoundException('Profile not found.');
    final now = _today();
    final since = dateOnly(DateTime(now.year, now.month, now.day - 90));
    final tx = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN type = 'INCOME' THEN amount_minor ELSE 0 END), 0) AS income,
             COALESCE(SUM(CASE WHEN type = 'EXPENSE' THEN amount_minor ELSE 0 END), 0) AS expense,
             COUNT(DISTINCT substr(date, 1, 7)) AS active_months
      FROM transactions WHERE status = 'CONFIRMED' AND date >= ?''', [since])!;
    return computeFinancialHealth(
      user: {
        'monthly_income': fromMinor(p['monthly_income_minor'] as int),
        'monthly_expense': fromMinor(p['monthly_expense_minor'] as int),
        'emergency_fund_amount': fromMinor(p['emergency_fund_minor'] as int),
        'target_savings_rate': (p['target_savings_rate'] as num).toDouble(),
        'dependents_count': p['dependents_count'],
        'health_dependents': p['health_dependents'],
      },
      tx: {'total_income': fromMinor(tx['income'] as int), 'total_expense': fromMinor(tx['expense'] as int), 'active_months': tx['active_months']},
      assets: [
        for (final a in _db.query('SELECT name, asset_class, sub_type, current_value_minor FROM assets'))
          {'name': a['name'], 'asset_class': a['asset_class'], 'sub_type': a['sub_type'], 'current_value': fromMinor(a['current_value_minor'] as int)},
      ],
      accounts: [for (final a in _db.query('SELECT balance_minor FROM accounts WHERE is_active = 1')) {'balance': fromMinor(a['balance_minor'] as int)}],
      debts: [for (final d in _db.query('SELECT current_outstanding_minor FROM debts')) {'current_outstanding': fromMinor(d['current_outstanding_minor'] as int)}],
      policies: [
        for (final r in _db.query('SELECT policy_type, status, sum_insured_minor FROM insurance_policies'))
          {'policy_type': r['policy_type'], 'status': r['status'], 'sum_insured': fromMinor(r['sum_insured_minor'] as int)},
      ],
    );
  }
}
