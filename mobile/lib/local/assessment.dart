/// Financial check-up: score, pillar scores and rule-based next steps,
/// translated from backend/app/services/financial_assessment.py (the
/// non-AI parts). Checked against Python in test/parity (assessment.json).
library;

import 'dart:math' as math;

import '../services/errors.dart';
import '../services/services.dart' show Json;
import 'validate.dart';

const assessmentDisclaimer =
    'Based on your answers, not verified records. Use this as a planning guide, not a guarantee or a substitute for professional advice.';

/// Like JavaScript Math.round on 0..100 (what the backend uses for pillars).
int _bounded(num value) => (math.max(0, math.min(100, value)) + 0.5).floor();

String _oneOf(Json a, String field, List<String> options, {bool required = true}) {
  final value = a[field];
  if (value == null) {
    if (required) throw ValidationException(field, 'Field required');
    return '';
  }
  if (value is! String || !options.contains(value)) {
    final quoted = options.map((o) => "'$o'").toList();
    final text = quoted.length == 1 ? quoted.single : '${quoted.sublist(0, quoted.length - 1).join(', ')} or ${quoted.last}';
    throw ValidationException(field, 'Input should be $text');
  }
  return value;
}

List<String> _listOf(Json a, String field, List<String> options, {int min = 0, required int max}) {
  final raw = a[field] ?? (min == 0 ? const [] : null);
  if (raw == null) throw ValidationException(field, 'Field required');
  if (raw is! List) throw ValidationException(field, 'Input should be a valid list');
  for (final item in raw) {
    _oneOf({field: item}, field, options);
  }
  if (raw.length < min) throw ValidationException(field, 'List should have at least $min item after validation, not ${raw.length}');
  if (raw.length > max) throw ValidationException(field, 'List should have at most $max items after validation, not ${raw.length}');
  return raw.cast<String>();
}

/// Validated answers (FinancialAssessmentAnswers), checked in field order.
class AssessmentAnswers {
  AssessmentAnswers.parse(Json a)
      : incomeSources = _listOf(a, 'income_sources',
            const ['salary', 'self_employed', 'business', 'freelance', 'investment', 'rental', 'pension', 'other'], min: 1, max: 8),
        monthlyNetIncome = readNumber(a, 'monthly_net_income', required: true, ge: 0, le: 1000000000)!,
        incomeStability = _oneOf(a, 'income_stability', const ['regular', 'mostly_regular', 'variable', 'seasonal']),
        essentialSpending = readNumber(a, 'essential_monthly_spending', required: true, gt: 0, le: 1000000000)!,
        monthEndPattern = _oneOf(a, 'month_end_pattern', const ['save_regularly', 'save_sometimes', 'break_even', 'withdraw_or_borrow']),
        liquidSavings = readNumber(a, 'liquid_savings', required: true, ge: 0, le: 1000000000)!,
        debtStatus = _oneOf(a, 'debt_status', const ['yes', 'no', 'not_sure']),
        debtOutstanding = readNumber(a, 'debt_outstanding', ge: 0, le: 1000000000),
        monthlyDebtPayment = readNumber(a, 'monthly_debt_payment', ge: 0, le: 1000000000),
        debtPaymentPattern = _nullable(a, 'debt_payment_pattern', const ['on_time', 'sometimes_late', 'missed_recently']),
        upcomingLargeExpense = _nullable(a, 'upcoming_large_expense', const ['yes', 'no', 'not_sure']),
        unexpectedExpensePlan = _nullable(a, 'unexpected_expense_plan', const ['savings', 'monthly_cashflow', 'borrow', 'not_sure']),
        healthCover = _oneOf(a, 'health_cover', const ['personal', 'employer', 'both', 'none', 'not_sure']),
        hasDependents = _bool(a, 'has_dependents'),
        termCover = _oneOf(a, 'term_cover', const ['adequate', 'some', 'none', 'not_sure', 'not_applicable']),
        planningConfidence = _oneOf(a, 'planning_confidence', const ['confident', 'somewhat', 'need_help', 'not_sure']),
        investmentTypes = _listOf(a, 'investment_types',
            const ['cash_deposit', 'stocks', 'mutual_funds', 'bonds', 'gold', 'property', 'retirement', 'crypto', 'other'], max: 9),
        goldShare = _oneOf(a, 'gold_share', const ['none', 'under_10', '10_to_25', '26_to_50', 'over_50', 'not_sure', 'not_applicable']),
        marketReaction = _oneOf(a, 'market_reaction', const ['sell', 'wait', 'invest_more', 'not_sure']),
        goalPriority = _oneOf(a, 'goal_priority',
            const ['emergency_fund', 'debt_repayment', 'home', 'education', 'retirement', 'wealth_building', 'family', 'other']),
        goalHorizon = _oneOf(a, 'goal_horizon', const ['under_1_year', '1_to_3_years', '3_to_10_years', 'over_10_years', 'not_sure']) {
    if (debtStatus == 'yes' && (debtOutstanding == null || monthlyDebtPayment == null || debtPaymentPattern == null)) {
      throw const ServiceException('For existing debt, provide the approximate balance, monthly payment, and payment pattern.');
    }
    if (debtStatus == 'no' && (upcomingLargeExpense == null || unexpectedExpensePlan == null)) {
      throw const ServiceException('If you have no debt, answer the upcoming and unexpected expense questions instead.');
    }
    if (hasDependents && termCover == 'not_applicable') {
      throw const ServiceException('Choose a term-cover status when someone depends on your income.');
    }
    if (!hasDependents && termCover != 'not_applicable') {
      throw const ServiceException('Term cover should be marked not applicable when nobody depends on your income.');
    }
    if (!investmentTypes.contains('gold') && !const {'none', 'not_sure', 'not_applicable'}.contains(goldShare)) {
      throw const ServiceException('Choose gold in your investment types before selecting a gold allocation.');
    }
  }

  final List<String> incomeSources;
  final double monthlyNetIncome;
  final String incomeStability;
  final double essentialSpending;
  final String monthEndPattern;
  final double liquidSavings;
  final String debtStatus;
  final double? debtOutstanding;
  final double? monthlyDebtPayment;
  final String? debtPaymentPattern;
  final String? upcomingLargeExpense;
  final String? unexpectedExpensePlan;
  final String healthCover;
  final bool hasDependents;
  final String termCover;
  final String planningConfidence;
  final List<String> investmentTypes;
  final String goldShare;
  final String marketReaction;
  final String goalPriority;
  final String goalHorizon;

  static String? _nullable(Json a, String field, List<String> options) => a[field] == null ? null : _oneOf(a, field, options);

  static bool _bool(Json a, String field) {
    if (a[field] == null) throw ValidationException(field, 'Field required');
    final value = readBool(a, field);
    return value!;
  }
}

/// Score, rating, data confidence and the six pillar scores.
Json scoreAssessment(AssessmentAnswers a) {
  final income = a.monthlyNetIncome;
  final expense = a.essentialSpending;
  final surplus = income > 0 ? (income - expense) / income : -1.0;
  num cashFlow = surplus < 0 ? 25 : surplus == 0 ? 45 : surplus < 0.10 ? 65 : surplus < 0.20 ? 82 : 95;
  cashFlow += const {'regular': 5, 'mostly_regular': 0, 'variable': -8, 'seasonal': -12}[a.incomeStability]!;
  cashFlow += const {'save_regularly': 8, 'save_sometimes': 0, 'break_even': -10, 'withdraw_or_borrow': -20}[a.monthEndPattern]!;

  final runway = expense > 0 ? a.liquidSavings / expense : 0.0;
  final liquidity = runway < 1 ? 25 : runway < 3 ? 45 : runway < 6 ? 70 : runway < 9 ? 90 : 100;

  num debt;
  if (a.debtStatus == 'no') {
    debt = a.unexpectedExpensePlan == 'savings' ? 95 : a.unexpectedExpensePlan == 'monthly_cashflow' ? 85 : 65;
    if (a.upcomingLargeExpense == 'yes') debt -= 5;
  } else if (a.debtStatus == 'not_sure') {
    debt = 45;
  } else {
    final ratio = income > 0 ? (a.monthlyDebtPayment ?? 0) / income : 1.0;
    final burden = ratio <= 0.20 ? 90 : ratio <= 0.35 ? 70 : ratio <= 0.50 ? 45 : 25;
    final reliability = const {'on_time': 100, 'sometimes_late': 60, 'missed_recently': 20}[a.debtPaymentPattern]!;
    debt = (burden + reliability) / 2;
  }

  final health = const {'both': 100, 'personal': 90, 'employer': 68, 'none': 25, 'not_sure': 45}[a.healthCover]!;
  final num protection = a.hasDependents
      ? (health + const {'adequate': 100, 'some': 65, 'none': 20, 'not_sure': 45, 'not_applicable': 45}[a.termCover]!) / 2
      : health;

  final kinds = a.investmentTypes.toSet().length;
  var investing = kinds == 0 ? 55 : kinds == 1 ? 65 : kinds <= 3 ? 78 : 88;
  if (a.goldShare == 'over_50') {
    investing -= 20;
  } else if (a.goldShare == '26_to_50') {
    investing -= 10;
  }

  var goal = a.goalHorizon != 'not_sure' ? 75 : 55;
  goal += const {'confident': 10, 'somewhat': 0, 'need_help': -5, 'not_sure': -5}[a.planningConfidence]!;

  final pillars = {
    'Cash flow': _bounded(cashFlow),
    'Emergency savings': _bounded(liquidity),
    'Debt & commitments': _bounded(debt),
    'Protection': _bounded(protection),
    'Investments': _bounded(investing),
    'Goals & planning': _bounded(goal),
  };
  const weights = {
    'Cash flow': 0.20, 'Emergency savings': 0.20, 'Debt & commitments': 0.15, 'Protection': 0.15, 'Investments': 0.15, 'Goals & planning': 0.15,
  };
  var weighted = 0.0;
  for (final e in weights.entries) {
    weighted += pillars[e.key]! * e.value;
  }
  final score = _bounded(weighted);

  final uncertainties = [
    a.incomeStability == 'variable',
    a.debtStatus == 'not_sure',
    a.healthCover == 'not_sure',
    a.termCover == 'not_sure',
    a.goldShare == 'not_sure',
    a.marketReaction == 'not_sure',
    a.goalHorizon == 'not_sure',
  ].where((x) => x).length;
  return {
    'score': score,
    'rating': score >= 75 ? 'Strong foundation' : score >= 55 ? 'Building' : 'Needs attention',
    'data_confidence': uncertainties >= 4 ? 'low' : uncertainties >= 2 ? 'medium' : 'high',
    'pillar_scores': pillars,
  };
}

/// Practical next steps worked out from the answers (no AI).
List<Json> ruleBasedRecommendations(AssessmentAnswers a) {
  final recs = <Json>[];
  Json rec(String priority, String area, String title, String why, List<String> actions, String tool, String check) => {
        'priority': priority, 'area': area, 'title': title, 'why': why, 'actions': actions, 'app_tool': tool, 'progress_check': check,
      };
  if (a.monthlyNetIncome <= a.essentialSpending) {
    recs.add(rec('first', 'Cash flow', 'Review one month of essential spending',
        'Your answers suggest essentials use most or all of your monthly take-home income.',
        ['Record essential spending in Money for one month.', 'Review the largest flexible cost before setting a new saving target.'],
        'Money', 'Compare essential spending with take-home income next month.'));
  }
  if (a.liquidSavings / a.essentialSpending < 3) {
    recs.add(rec(recs.isEmpty ? 'first' : 'next', 'Emergency savings', 'Build an accessible cash buffer',
        'Your reported liquid savings cover less than three months of essential spending.',
        ['Set a small recurring savings target that fits your cash flow.', 'Track the buffer separately from long-term investments.'],
        'Goals', 'Review how many months of essential costs your buffer covers each month.'));
  }
  if (a.debtStatus == 'yes' && a.monthlyNetIncome != 0 && a.monthlyDebtPayment! / a.monthlyNetIncome > 0.35) {
    recs.add(rec('next', 'Debt', 'Map repayments and due dates', 'Reported monthly debt payments take a substantial share of take-home income.',
        ['List each balance, interest rate and minimum payment.', 'Keep required payments current while you compare repayment priorities.'],
        'Debts', 'Review total monthly repayments and balances in 30 days.'));
  }
  if (a.healthCover == 'none' || (a.hasDependents && a.termCover == 'none')) {
    recs.add(rec('next', 'Protection', 'Review your protection needs', 'Your answers indicate a possible gap in health or dependent protection.',
        ['Check what employer cover includes and when it ends.', 'Estimate household needs before comparing suitable cover.'],
        'Insurance', 'Record the cover you have and the gaps you still need to assess.'));
  }
  if (recs.isEmpty) {
    recs.add(rec('next', 'Planning', 'Turn your next goal into a monthly plan', 'A clear target and regular review can help make progress visible.',
        ['Set a target amount and date for your next goal.', 'Choose a monthly contribution you can sustain.'],
        'Goals', 'Review the goal contribution and progress at month end.'));
  }
  return recs.take(4).toList();
}

/// The full check-up result, worked out on the phone.
Json offlineAssessment(Json answers) {
  final a = AssessmentAnswers.parse(answers);
  return {
    ...scoreAssessment(a),
    'summary': 'Your score is based on the answers you provided. These practical starting points are rule-based and were worked out on your phone; nothing was sent anywhere.',
    'strengths': <String>[],
    'recommendations': ruleBasedRecommendations(a),
    'disclaimer': assessmentDisclaimer,
  };
}
