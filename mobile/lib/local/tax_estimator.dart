/// Indian individual income-tax estimate (old vs new regime), translated from
/// backend/app/services/tax_estimator.py. The slabs, rebates, surcharge and
/// cess come from the same rules file (assets/tax/india_tax_rules.json, a
/// copy of backend/app/data/india_tax_rules.json). Checked against Python in
/// test/parity (tax.json).
library;

import 'dart:math' as math;

import '../services/errors.dart';
import '../services/services.dart' show Json;
import 'py_round.dart';
import 'validate.dart';

/// All rule files by tax year ("2026-27" -> rules).
class TaxRules {
  TaxRules(List<Json> files) {
    for (final rules in files) {
      final year = rules['tax_year']?.toString() ?? '';
      if (year.isEmpty || _byYear.containsKey(year)) throw StateError('Tax rules file has a missing or duplicate tax year');
      final individual = rules['individual'];
      if (individual is! Map || individual['regimes'] is! Map) throw StateError('Tax rules file is missing individual regime data');
      if (individual['common'] is! Map && rules['common'] is Map) individual['common'] = rules['common'];
      final regimes = individual['regimes'] as Map;
      if (!regimes.containsKey('new') || !regimes.containsKey('old')) throw StateError('Tax rules must define both old and new regimes');
      _byYear[year] = rules;
    }
    if (_byYear.isEmpty) throw StateError('No India tax rulesets are configured.');
  }

  final _byYear = <String, Json>{};

  /// Newest first, like the backend.
  List<String> get availableYears => _byYear.keys.toList()..sort((a, b) => b.compareTo(a));

  Json forYear(String? taxYear) {
    final year = taxYear ?? availableYears.first;
    final rules = _byYear[year];
    if (rules == null) throw ServiceException('No India tax rules are available for Tax Year $year.');
    return rules;
  }

  /// The `/tax/rules` response.
  Json describe(String? taxYear) {
    final rules = forYear(taxYear);
    final individual = rules['individual'] as Map;
    return {
      'country': rules['country'],
      'currency': rules['currency'],
      'tax_year': rules['tax_year'],
      'legislation': rules['legislation'],
      'version': rules['version'],
      'available_tax_years': availableYears,
      'sources': rules['sources'],
      'regimes': individual['regimes'],
      'common': individual['common'],
    };
  }
}

/// Validated estimator input (IndiaTaxEstimateInput).
class TaxInput {
  TaxInput._(this.values, this.taxYear, this.age, this.residentialStatus);
  final Map<String, double> values;
  final String taxYear;
  final int age;
  final String residentialStatus;

  static const amountFields = [
    'salary_income', 'interest_income', 'dividend_income', 'rental_taxable_income', 'business_taxable_income',
    'other_regular_income', 'section_80c', 'employee_pf_contribution', 'section_80d', 'home_loan_interest_self_occupied',
    'other_old_regime_deductions', 'employer_nps_deduction_new', 'tax_already_paid',
  ];

  /// Same rules and messages as the Pydantic model, checked in field order.
  factory TaxInput.parse(Json input) {
    final taxYear = readString(input, 'tax_year') ?? '2026-27';
    if (taxYear.length < 7) throw ValidationException('tax_year', 'String should have at least 7 characters');
    if (taxYear.length > 10) throw ValidationException('tax_year', 'String should have at most 10 characters');
    final age = readInt(input, 'age', ge: 18, le: 120) ?? 30;
    final status = readString(input, 'residential_status') ?? 'resident';
    if (status != 'resident' && status != 'non_resident') {
      throw ValidationException('residential_status', "Input should be 'resident' or 'non_resident'");
    }
    final values = {for (final f in amountFields) f: readNumber(input, f, ge: 0, le: 1000000000) ?? 0.0};
    const incomeOrPaid = [
      'salary_income', 'interest_income', 'dividend_income', 'rental_taxable_income', 'business_taxable_income',
      'other_regular_income', 'tax_already_paid',
    ];
    if (!incomeOrPaid.any((f) => values[f] != 0)) {
      throw const ServiceException('Enter at least one income amount or tax already paid.');
    }
    return TaxInput._(values, taxYear, age, status);
  }

  double operator [](String field) => values[field]!;
}

double _slabTax(double income, List slabs) {
  var tax = 0.0;
  for (final slab in slabs.cast<Map>()) {
    final lower = (slab['from'] as num).toDouble();
    final upper = slab['to'] as num?;
    var band = math.max(0.0, income - lower);
    if (upper != null) band = math.min(band, upper.toDouble() - lower);
    tax += band * (slab['rate'] as num).toDouble();
    if (upper == null || income <= upper) break;
  }
  return tax;
}

List _oldRegimeSlabs(Json rules, int age, bool resident) {
  final bands = rules['individual']['regimes']['old']['slabs_by_age'] as Map;
  if (resident && age >= 80) return bands['age_80_plus'] as List;
  if (resident && age >= 60) return bands['age_60_to_79'] as List;
  return bands['under_60'] as List;
}

Map _common(Json rules) => (rules['individual'] as Map)['common'] as Map;

(double, double, double) _taxAfterSurcharge(double taxableIncome, double slabTax, Json rules, String regime, List slabs) {
  final common = _common(rules);
  final thresholds = [for (final t in common['surcharge_thresholds'] as List) (t as num).toDouble()];
  final rates = common['surcharge_rates_$regime'] as List;
  final rateIndex = thresholds.where((t) => taxableIncome > t).length;
  final surchargeRate = (rates[math.min(rateIndex, rates.length - 1)] as num).toDouble();
  var taxWithSurcharge = slabTax * (1 + surchargeRate);
  // Marginal relief at each surcharge threshold.
  for (var i = 0; i < thresholds.length; i++) {
    final threshold = thresholds[i];
    if (taxableIncome <= threshold) break;
    final priorRate = (rates[math.min(i, rates.length - 1)] as num).toDouble();
    final reliefCap = _slabTax(threshold, slabs) * (1 + priorRate) + taxableIncome - threshold;
    taxWithSurcharge = math.min(taxWithSurcharge, reliefCap);
  }
  return (taxWithSurcharge, surchargeRate, math.max(0.0, taxWithSurcharge - slabTax));
}

Json _estimateRegime(TaxInput v, Json rules, String regime, double grossIncome) {
  final regimeRules = rules['individual']['regimes'][regime] as Map;
  final resident = v.residentialStatus == 'resident';
  final List slabs;
  final double standardDeduction;
  final double eligibleDeductions;
  final Map<String, double> details;
  if (regime == 'new') {
    slabs = regimeRules['income_tax_slabs'] as List;
    standardDeduction = math.min(v['salary_income'], (regimeRules['standard_deduction']['amount'] as num).toDouble());
    eligibleDeductions = math.min(
      v['employer_nps_deduction_new'],
      v['salary_income'] * (regimeRules['employer_nps_deduction_max_pct_of_salary'] as num).toDouble(),
    );
    details = {'standard_deduction': standardDeduction, 'employer_nps': eligibleDeductions};
  } else {
    slabs = _oldRegimeSlabs(rules, v.age, resident);
    final d = regimeRules['deductions'] as Map;
    final limit80c = (d['section_80c_limit'] as num).toDouble();
    standardDeduction = math.min(v['salary_income'], (d['standard_deduction']['amount'] as num).toDouble());
    details = {
      'standard_deduction': standardDeduction,
      'section_80c_other': math.min(v['section_80c'], math.max(limit80c - v['employee_pf_contribution'], 0.0)),
      'employee_pf_contribution': math.min(v['employee_pf_contribution'], limit80c),
      'section_80d': math.min(v['section_80d'], (d['section_80d_limit'] as num).toDouble()),
      'home_loan_interest_self_occupied':
          math.min(v['home_loan_interest_self_occupied'], (d['home_loan_interest_self_occupied_limit'] as num).toDouble()),
      'other_old_regime_deductions': v['other_old_regime_deductions'],
    };
    // Python: sum(details.values()) - standard_deduction (same order).
    var sum = 0.0;
    for (final value in details.values) {
      sum += value;
    }
    eligibleDeductions = sum - standardDeduction;
  }

  final totalDeductions = standardDeduction + eligibleDeductions;
  final taxableIncome = math.max(0.0, grossIncome - totalDeductions);
  final slabTax = _slabTax(taxableIncome, slabs);
  var rebate = 0.0;
  String? reliefNote;
  final rebateRules = regimeRules['rebate_87a'] as Map;
  final rebateLimit = (rebateRules['taxable_income_limit'] as num).toDouble();
  if (resident && taxableIncome <= rebateLimit) rebate = math.min(slabTax, (rebateRules['maximum_amount'] as num).toDouble());
  var afterRebate = math.max(0.0, slabTax - rebate);
  if (regime == 'new' && resident && taxableIncome > rebateLimit && afterRebate > taxableIncome - rebateLimit) {
    afterRebate = math.max(0.0, taxableIncome - rebateLimit);
    reliefNote = 'Marginal relief applied at the section 87A threshold.';
  }

  final (taxWithSurcharge, surchargeRate, surchargeAmount) = _taxAfterSurcharge(taxableIncome, afterRebate, rules, regime, slabs);
  final cess = taxWithSurcharge * (_common(rules)['health_education_cess_rate'] as num).toDouble();
  final totalBeforeRounding = taxWithSurcharge + cess;
  // Python: int((x + 5) // 10) * 10, i.e. round to the nearest 10.
  final totalTax = ((totalBeforeRounding + 5) / 10).floor() * 10;
  final balance = pyRound(totalTax - v['tax_already_paid'], 2);

  return {
    'regime': regime,
    'taxable_income': pyRound(taxableIncome, 2),
    'deductions': {for (final e in details.entries) e.key: pyRound(e.value, 2)},
    'total_deductions': pyRound(totalDeductions, 2),
    'slab_tax_before_rebate': pyRound(slabTax, 2),
    'rebate_87a': pyRound(rebate, 2),
    'surcharge_rate': surchargeRate,
    'surcharge': pyRound(surchargeAmount, 2),
    'cess': pyRound(cess, 2),
    'estimated_tax': totalTax,
    'tax_already_paid': pyRound(v['tax_already_paid'], 2),
    'estimated_balance': balance,
    'estimated_refund': -balance > 0 ? -balance : 0.0,
    'effective_rate_pct': grossIncome != 0 ? pyRound(totalTax / grossIncome * 100, 2) : 0.0,
    'notes': [?reliefNote],
  };
}

/// The `/tax/estimate` response for already-validated input.
Json estimateIndiaTax(TaxRules allRules, TaxInput v) {
  final rules = allRules.forYear(v.taxYear);
  var gross = 0.0;
  for (final f in const ['salary_income', 'interest_income', 'dividend_income', 'rental_taxable_income', 'business_taxable_income', 'other_regular_income']) {
    gross += v[f];
  }
  final results = {for (final regime in const ['new', 'old']) regime: _estimateRegime(v, rules, regime, gross)};
  // min() keeps the first of equal values, so "new" wins a tie.
  final preferred = (results['old']!['estimated_tax'] as int) < (results['new']!['estimated_tax'] as int) ? results['old']! : results['new']!;
  return {
    'country': 'IN',
    'tax_year': v.taxYear,
    'legislation': rules['legislation'],
    'ruleset_version': rules['version'],
    'gross_regular_income': pyRound(gross, 2),
    'residential_status': v.residentialStatus,
    'age': v.age,
    'results': results,
    'lower_estimate_regime': preferred['regime'],
    'estimated_difference': pyRound(((results['new']!['estimated_tax'] as int) - (results['old']!['estimated_tax'] as int)).abs().toDouble(), 2),
    'sources': rules['sources'],
  };
}
