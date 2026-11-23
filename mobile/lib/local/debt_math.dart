/// Debt payoff plans (avalanche / snowball), translated from
/// backend/app/services/debt_service.py. Checked against Python in
/// test/parity (debts.json).
library;

import 'dart:math' as math;

import '../services/services.dart' show Json;

double _num(Object? v) => v == null ? 0.0 : (v as num).toDouble();

/// Adds whole months, clamping the day (31 Jan + 1 month = 28/29 Feb).
DateTime addMonths(DateTime start, int months) {
  final index = start.month - 1 + months;
  final year = start.year + (index ~/ 12);
  final month = index % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, math.min(start.day, lastDay));
}

/// Simulates all minimum payments together; with [rollExtra], money freed by
/// paid-off debts goes to the next debt in [order].
({List<int> payoffMonths, List<double> interestPaid, int monthsToComplete}) _simulate(List<Json> debts, List<int> order, bool rollExtra) {
  if (debts.isEmpty) return (payoffMonths: <int>[], interestPaid: <double>[], monthsToComplete: 0);
  final balances = [for (final d in debts) math.max(0.0, _num(d['current_outstanding']))];
  final rates = [for (final d in debts) math.max(0.0, _num(d['interest_rate_pct']))];
  final payments = [for (final d in debts) math.max(0.0, _num(d['monthly_emi']))];
  var budget = 0.0;
  for (var i = 0; i < debts.length; i++) {
    if (balances[i] > 0) budget += payments[i];
  }
  final interest = List<double>.filled(debts.length, 0.0);
  final payoff = <int?>[for (final b in balances) b <= 0 ? 0 : null];
  const maxMonths = 600;

  for (var month = 1; month <= maxMonths; month++) {
    if (!balances.any((b) => b > 0)) break;
    final previous = [...balances];
    var remaining = budget;
    for (var i = 0; i < balances.length; i++) {
      final balance = balances[i];
      if (balance <= 0) continue;
      final monthInterest = balance * rates[i] / 1200;
      interest[i] += monthInterest;
      balances[i] = balance + monthInterest;
      final payment = math.min(payments[i], balances[i]);
      balances[i] -= payment;
      remaining -= payment;
    }
    if (rollExtra) {
      for (final i in order) {
        if (remaining <= 0) break;
        if (balances[i] <= 0) continue;
        final payment = math.min(remaining, balances[i]);
        balances[i] -= payment;
        remaining -= payment;
      }
    }
    for (var i = 0; i < balances.length; i++) {
      if (balances[i] <= 0.005) {
        balances[i] = 0.0;
        payoff[i] ??= month;
      }
    }
    var progress = false;
    for (var i = 0; i < balances.length; i++) {
      if (balances[i] > 0 && balances[i] < previous[i] - 0.005) progress = true;
    }
    if (!progress && balances.any((b) => b > 0)) break;
  }
  for (var i = 0; i < payoff.length; i++) {
    if (payoff[i] == null && balances[i] > 0) payoff[i] = maxMonths;
  }
  final months = [for (final m in payoff) m ?? 0];
  return (payoffMonths: months, interestPaid: interest, monthsToComplete: months.fold(0, math.max));
}

/// The `/debts/strategy/{avalanche|snowball}` response for [debts] (those
/// with something outstanding). [today] dates the payoff months.
Json debtPayoffPlan(List<Json> debts, String strategy, DateTime today) {
  int compareText(Object? a, Object? b) => (a?.toString() ?? '').compareTo(b?.toString() ?? '');
  final order = List<int>.generate(debts.length, (i) => i);
  if (strategy == 'avalanche') {
    order.sort((a, b) {
      final byRate = _num(debts[b]['interest_rate_pct']).compareTo(_num(debts[a]['interest_rate_pct']));
      if (byRate != 0) return byRate;
      final byStart = compareText(debts[a]['start_date'], debts[b]['start_date']);
      return byStart != 0 ? byStart : compareText(debts[a]['debt_name'], debts[b]['debt_name']);
    });
  } else if (strategy == 'snowball') {
    order.sort((a, b) {
      final byBalance = _num(debts[a]['current_outstanding']).compareTo(_num(debts[b]['current_outstanding']));
      if (byBalance != 0) return byBalance;
      final byStart = compareText(debts[a]['start_date'], debts[b]['start_date']);
      return byStart != 0 ? byStart : compareText(debts[a]['debt_name'], debts[b]['debt_name']);
    });
  } else {
    throw ArgumentError('Unknown debt payoff strategy: $strategy');
  }

  final baseline = _simulate(debts, order, false);
  final plan = _simulate(debts, order, true);
  final baselineInterest = baseline.interestPaid.fold(0.0, (a, b) => a + b);
  final planInterest = plan.interestPaid.fold(0.0, (a, b) => a + b);
  String date(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  final rows = [
    for (final i in order)
      {
        'debt_id': debts[i]['id'],
        'debt_name': debts[i]['debt_name'],
        'current_outstanding': _num(debts[i]['current_outstanding']),
        'interest_rate_pct': _num(debts[i]['interest_rate_pct']),
        'monthly_payment': _num(debts[i]['monthly_emi']),
        'total_interest_if_minimum': baseline.interestPaid[i],
        'months_to_payoff': plan.payoffMonths[i],
        'payoff_date': plan.payoffMonths[i] == 0 ? null : date(addMonths(today, plan.payoffMonths[i])),
      },
  ];
  return {
    'recommended_order': rows,
    if (strategy == 'avalanche') 'total_interest_saved': math.max(0.0, baselineInterest - planInterest),
    if (strategy == 'snowball') 'motivation_wins': rows.length,
    'months_to_complete': plan.monthsToComplete,
  };
}
