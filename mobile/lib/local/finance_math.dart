/// Financial calculators, translated line by line from
/// backend/app/services/finance_math.py. Results are checked against the
/// Python output in test/parity (calculators.json).
library;

import 'dart:math' as math;

import '../services/services.dart' show Json;
import 'py_round.dart';

double _r2(double x) => pyRound(x, 2);
double _pow(double x, num y) => math.pow(x, y).toDouble();

/// SIP future value with an optional yearly step-up.
Json calculateSip(double monthlyInvestment, double expectedReturnRatePct, int timePeriodYears, [double annualStepUpPct = 0.0]) {
  final monthlyRate = (expectedReturnRatePct / 100.0) / 12.0;
  var currentSip = monthlyInvestment;
  var totalInvested = 0.0;
  var corpus = 0.0;
  final yearlySchedule = <Json>[];

  for (var year = 1; year <= timePeriodYears; year++) {
    var yearInvested = 0.0;
    for (var month = 1; month <= 12; month++) {
      corpus = (corpus + currentSip) * (1 + monthlyRate);
      totalInvested += currentSip;
      yearInvested += currentSip;
    }
    final returnsEarned = corpus - totalInvested;
    yearlySchedule.add({
      'year': year,
      'yearly_investment': _r2(yearInvested),
      'total_invested': _r2(totalInvested),
      'future_value': _r2(corpus),
      'returns_earned': _r2(returnsEarned),
    });
    if (annualStepUpPct > 0) currentSip = currentSip * (1 + (annualStepUpPct / 100.0));
  }
  return {
    'total_invested': _r2(totalInvested),
    'estimated_returns': _r2(corpus - totalInvested),
    'total_value': _r2(corpus),
    'yearly_schedule': yearlySchedule,
  };
}

/// One-time investment: A = P * (1 + r)^t.
Json calculateLumpsum(double totalInvestment, double expectedReturnRatePct, int timePeriodYears) {
  final r = expectedReturnRatePct / 100.0;
  final yearlySchedule = <Json>[];
  for (var year = 1; year <= timePeriodYears; year++) {
    final fv = totalInvestment * _pow(1 + r, year);
    yearlySchedule.add({
      'year': year,
      'total_invested': _r2(totalInvestment),
      'future_value': _r2(fv),
      'returns_earned': _r2(fv - totalInvestment),
    });
  }
  final finalVal = totalInvestment * _pow(1 + r, timePeriodYears);
  return {
    'total_invested': _r2(totalInvestment),
    'estimated_returns': _r2(finalVal - totalInvestment),
    'total_value': _r2(finalVal),
    'yearly_schedule': yearlySchedule,
  };
}

/// CAGR = (Final / Initial)^(1/t) - 1.
Json calculateCagr(double initialValue, double finalValue, double durationYears) {
  if (initialValue <= 0 || durationYears <= 0) {
    return {'cagr_percentage': 0.0, 'absolute_growth_percentage': 0.0, 'total_gain': 0.0};
  }
  final cagr = _pow(finalValue / initialValue, 1.0 / durationYears) - 1.0;
  final absGrowth = ((finalValue - initialValue) / initialValue) * 100.0;
  return {
    'cagr_percentage': _r2(cagr * 100.0),
    'absolute_growth_percentage': _r2(absGrowth),
    'total_gain': _r2(finalValue - initialValue),
  };
}

/// XIRR (Newton-Raphson) for irregular cash flows, as a percentage.
double calculateXirr(List<(DateTime, double)> cashFlows, [double guess = 0.1]) {
  if (cashFlows.length < 2) return 0.0;
  final sorted = [...cashFlows]..sort((a, b) => a.$1.compareTo(b.$1));
  final start = sorted.first.$1;
  final dated = [for (final (d, amount) in sorted) (_daysBetween(start, d) / 365.0, amount)];
  final amounts = dated.map((e) => e.$2);
  if (!(amounts.any((a) => a < 0) && amounts.any((a) => a > 0))) return 0.0;

  var rate = guess;
  for (var i = 0; i < 100; i++) {
    var f = 0.0;
    var df = 0.0;
    for (final (t, amount) in dated) {
      final denom = _pow(1.0 + rate, t);
      if (denom == 0 || denom.isInfinite || denom.isNaN) return 0.0;
      f += amount / denom;
      if (t > 0) df -= (t * amount) / (denom * (1.0 + rate));
    }
    if (f.abs() < 1e-6) return pyRound(rate * 100.0, 2);
    if (df.abs() < 1e-9) break;
    final next = rate - (f / df);
    rate = next <= -1.0 ? (rate - 1.0) / 2.0 : next;
  }
  return pyRound(rate * 100.0, 2);
}

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// EMI with the month-by-month reducing balance schedule.
Json calculateEmi(double loanAmount, double annualInterestRatePct, int tenureMonths) {
  if (tenureMonths <= 0 || loanAmount <= 0) {
    return {
      'monthly_emi': 0.0, 'total_interest': 0.0, 'total_payment': 0.0,
      'principal_percentage': 0.0, 'interest_percentage': 0.0, 'amortization_schedule': <Json>[],
    };
  }
  final monthlyRate = (annualInterestRatePct / 100.0) / 12.0;
  double emi;
  if (monthlyRate == 0) {
    emi = loanAmount / tenureMonths;
  } else {
    final powFactor = _pow(1 + monthlyRate, tenureMonths);
    emi = (loanAmount * monthlyRate * powFactor) / (powFactor - 1);
  }

  final schedule = <Json>[];
  var remaining = loanAmount;
  var totalInterest = 0.0;
  for (var month = 1; month <= tenureMonths; month++) {
    final interestPart = remaining * monthlyRate;
    var principalPart = emi - interestPart;
    if (month == tenureMonths || remaining < principalPart) {
      principalPart = remaining;
      emi = principalPart + interestPart;
      remaining = 0.0;
    } else {
      remaining -= principalPart;
    }
    totalInterest += interestPart;
    schedule.add({
      'month': month,
      'emi': _r2(emi),
      'principal_paid': _r2(principalPart),
      'interest_paid': _r2(interestPart),
      'remaining_balance': _r2(math.max(0.0, remaining)),
    });
  }
  final totalPayment = loanAmount + totalInterest;
  final principalPct = totalPayment > 0 ? (loanAmount / totalPayment) * 100.0 : 100.0;
  final interestPct = totalPayment > 0 ? (totalInterest / totalPayment) * 100.0 : 0.0;
  return {
    'monthly_emi': _r2(emi),
    'total_interest': _r2(totalInterest),
    'total_payment': _r2(totalPayment),
    'principal_percentage': pyRound(principalPct, 1),
    'interest_percentage': pyRound(interestPct, 1),
    'amortization_schedule': schedule,
  };
}

/// Systematic withdrawal plan with optional inflation-linked withdrawals.
Json calculateSwp(double totalInvestment, double monthlyWithdrawal, double expectedReturnRatePct,
    [double annualInflationPct = 0.0, int timePeriodYears = 20]) {
  final monthlyReturn = (expectedReturnRatePct / 100.0) / 12.0;
  var balance = totalInvestment;
  var currentWithdrawal = monthlyWithdrawal;
  var totalWithdrawn = 0.0;
  double? depletedInYears;
  final schedule = <Json>[];
  for (var year = 1; year <= timePeriodYears; year++) {
    var yearWithdrawn = 0.0;
    for (var month = 1; month <= 12; month++) {
      if (balance <= 0) {
        depletedInYears ??= pyRound((year - 1) + (month / 12.0), 1);
        break;
      }
      final actual = math.min(balance, currentWithdrawal);
      balance = (balance - actual) * (1 + monthlyReturn);
      totalWithdrawn += actual;
      yearWithdrawn += actual;
    }
    schedule.add({
      'year': year,
      'yearly_withdrawal': _r2(yearWithdrawn),
      'total_withdrawn': _r2(totalWithdrawn),
      'remaining_balance': _r2(math.max(0.0, balance)),
    });
    if (annualInflationPct > 0) currentWithdrawal = currentWithdrawal * (1 + (annualInflationPct / 100.0));
  }
  return {
    'total_withdrawn': _r2(totalWithdrawn),
    'final_balance': _r2(math.max(0.0, balance)),
    'depleted_in_years': depletedInYears,
    'schedule': schedule,
  };
}

/// FIRE: corpus needed (standard / lean / fat), projection and required SIP.
Json calculateFire({
  required int currentAge,
  required int targetRetirementAge,
  required double monthlyExpense,
  double currentPortfolio = 0.0,
  double existingMonthlyInvestment = 0.0,
  double expectedPreRetireReturnPct = 12.0,
  double expectedPostRetireReturnPct = 8.0,
  double expectedInflationPct = 6.0,
  int lifeExpectancy = 85,
}) {
  final yearsToRetirement = math.max(0, targetRetirementAge - currentAge);
  final yearsInRetirement = math.max(1, lifeExpectancy - targetRetirementAge);
  final currentAnnualExpense = monthlyExpense * 12.0;

  final inflationMultiplier = _pow(1 + (expectedInflationPct / 100.0), yearsToRetirement);
  final futureAnnualExpense = currentAnnualExpense * inflationMultiplier;

  final postR = expectedPostRetireReturnPct / 100.0;
  final infR = expectedInflationPct / 100.0;
  final realRetireRate = (1 + infR) != 0 ? (postR - infR) / (1 + infR) : postR;

  double standardCorpus;
  if (realRetireRate.abs() < 0.001) {
    standardCorpus = futureAnnualExpense * yearsInRetirement;
  } else {
    standardCorpus = futureAnnualExpense * ((1 - _pow(1 + realRetireRate, -yearsInRetirement)) / realRetireRate);
  }
  standardCorpus = math.max(standardCorpus, futureAnnualExpense * 25.0);
  final leanCorpus = standardCorpus * 0.75;
  final fatCorpus = standardCorpus * 1.50;

  final preMonthlyRate = (expectedPreRetireReturnPct / 100.0) / 12.0;
  final totalMonths = yearsToRetirement * 12;
  final projectedLumpsum = currentPortfolio * _pow(1 + preMonthlyRate, totalMonths);
  final double projectedSip;
  if (preMonthlyRate > 0 && totalMonths > 0) {
    projectedSip = existingMonthlyInvestment * ((_pow(1 + preMonthlyRate, totalMonths) - 1) / preMonthlyRate) * (1 + preMonthlyRate);
  } else {
    projectedSip = existingMonthlyInvestment * totalMonths;
  }
  final totalProjected = projectedLumpsum + projectedSip;
  final shortfall = standardCorpus - totalProjected;

  double requiredMonthlySip;
  if (shortfall <= 0 || totalMonths <= 0) {
    requiredMonthlySip = 0.0;
  } else if (preMonthlyRate > 0) {
    requiredMonthlySip = shortfall / (((_pow(1 + preMonthlyRate, totalMonths) - 1) / preMonthlyRate) * (1 + preMonthlyRate));
  } else {
    requiredMonthlySip = shortfall / totalMonths;
  }

  final yearlyProgression = <Json>[];
  var simPortfolio = currentPortfolio;
  var estFireAge = targetRetirementAge;
  var foundFire = false;
  for (var y = 0; y <= math.max(0, lifeExpectancy - currentAge); y++) {
    final simAge = currentAge + y;
    final annualExpenseAtAge = currentAnnualExpense * _pow(1 + infR, y);
    final remainingYears = math.max(1, lifeExpectancy - simAge);
    double targetAtY;
    if (realRetireRate.abs() < 0.001) {
      targetAtY = annualExpenseAtAge * remainingYears;
    } else {
      targetAtY = annualExpenseAtAge * ((1 - _pow(1 + realRetireRate, -remainingYears)) / realRetireRate);
    }
    targetAtY = math.max(targetAtY, annualExpenseAtAge * 25.0);
    yearlyProgression.add({
      'age': simAge,
      'year': y,
      'projected_portfolio': _r2(simPortfolio),
      'target_fire_corpus': _r2(targetAtY),
      'is_fire_reached': simPortfolio >= targetAtY,
    });
    if (simPortfolio >= targetAtY && !foundFire) {
      estFireAge = simAge;
      foundFire = true;
    }
    for (var i = 0; i < 12; i++) {
      simPortfolio = (simPortfolio + existingMonthlyInvestment) * (1 + preMonthlyRate);
    }
  }
  if (!foundFire) estFireAge = lifeExpectancy;

  final num sipGrowthFactor = preMonthlyRate > 0 && totalMonths > 0
      ? ((_pow(1 + preMonthlyRate, totalMonths) - 1) / preMonthlyRate) * (1 + preMonthlyRate)
      : totalMonths;

  Json milestone(double target, String label) {
    final additional = sipGrowthFactor > 0 ? math.max(0.0, target - totalProjected) / sipGrowthFactor : 0.0;
    return {
      'type': label,
      'required_corpus': _r2(target),
      'years_to_reach': yearsToRetirement.toDouble(),
      'projected_age': targetRetirementAge,
      'additional_monthly_sip': _r2(additional),
    };
  }

  return {
    'current_annual_expense': _r2(currentAnnualExpense),
    'future_annual_expense_at_retirement': _r2(futureAnnualExpense),
    'standard_fire_corpus': _r2(standardCorpus),
    'lean_fire_corpus': _r2(leanCorpus),
    'fat_fire_corpus': _r2(fatCorpus),
    'projected_corpus_at_retire_age': _r2(totalProjected),
    'shortfall_or_surplus': _r2(totalProjected - standardCorpus),
    'required_monthly_sip': _r2(math.max(0.0, requiredMonthlySip)),
    'can_retire_at_target_age': totalProjected >= standardCorpus,
    'estimated_fire_age': estFireAge,
    'milestones': [
      milestone(leanCorpus, 'Lean FIRE (75% of standard)'),
      milestone(standardCorpus, 'Standard FIRE (25x annual expense)'),
      milestone(fatCorpus, 'Fat FIRE (150% of standard)'),
    ],
    'yearly_progression': yearlyProgression,
  };
}
