/// Calculators and income-tax services on the phone
/// (backend/app/routers/calculators.py and tax.py).
library;

import 'dart:math' as math;

import '../services/errors.dart';
import '../services/services.dart';
import 'finance_math.dart';
import 'local_db.dart';
import 'py_round.dart';
import 'tax_estimator.dart';
import 'validate.dart';

class LocalCalculatorsService implements CalculatorsService {
  const LocalCalculatorsService();

  /// Validates like the backend's input models, then runs the calculator.
  @override
  Future<Json> calculate(CalculatorKind kind, Json input) async => runCalculator(kind, input);
}

Json runCalculator(CalculatorKind kind, Json i) {
  switch (kind) {
    case CalculatorKind.sip:
      return calculateSip(
        readNumber(i, 'monthly_investment', required: true, gt: 0)!,
        readNumber(i, 'expected_return_rate_pct', required: true, gt: 0, le: 100)!,
        readInt(i, 'time_period_years', required: true, gt: 0, le: 60)!,
        readNumber(i, 'annual_step_up_pct', ge: 0, le: 100) ?? 0.0,
      );
    case CalculatorKind.lumpsum:
      return calculateLumpsum(
        readNumber(i, 'total_investment', required: true, gt: 0)!,
        readNumber(i, 'expected_return_rate_pct', required: true, gt: 0, le: 100)!,
        readInt(i, 'time_period_years', required: true, gt: 0, le: 60)!,
      );
    case CalculatorKind.cagr:
      return calculateCagr(
        readNumber(i, 'initial_value', required: true, gt: 0)!,
        readNumber(i, 'final_value', required: true, gt: 0)!,
        readNumber(i, 'duration_years', required: true, gt: 0)!,
      );
    case CalculatorKind.emi:
      return calculateEmi(
        readNumber(i, 'loan_amount', required: true, gt: 0)!,
        readNumber(i, 'interest_rate_pct', required: true, gt: 0)!,
        readInt(i, 'tenure_months', required: true, gt: 0)!,
      );
    case CalculatorKind.fire:
      final current = readInt(i, 'current_age', required: true, ge: 18, le: 80)!;
      final target = readInt(i, 'target_retirement_age', required: true, ge: 18, le: 80)!;
      final life = readInt(i, 'life_expectancy', ge: 50, le: 100);
      final expense = readNumber(i, 'monthly_expense', required: true, gt: 0)!;
      final portfolio = readNumber(i, 'current_portfolio_value', ge: 0);
      final monthly = readNumber(i, 'existing_monthly_investment', ge: 0);
      final pre = readNumber(i, 'expected_pre_retire_return_pct', gt: 0);
      final post = readNumber(i, 'expected_post_retire_return_pct', gt: 0);
      final inflation = readNumber(i, 'expected_inflation_pct', ge: 0);
      if (target <= current) throw const ServiceException('Target retirement age must be greater than current age.');
      if (life != null && life <= target) throw const ServiceException('Life expectancy must be later than target retirement age.');
      return calculateFire(
        currentAge: current,
        targetRetirementAge: target,
        lifeExpectancy: life ?? 85,
        monthlyExpense: expense,
        currentPortfolio: portfolio ?? 0.0,
        existingMonthlyInvestment: monthly ?? 0.0,
        expectedPreRetireReturnPct: pre ?? 12.0,
        expectedPostRetireReturnPct: post ?? 8.0,
        expectedInflationPct: inflation ?? 6.0,
      );
  }
}

/// Income-tax rules, estimate, and suggestions from the user's own records.
class LocalTaxService implements TaxService {
  LocalTaxService(this._db, this._rules, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final TaxRules _rules;
  final DateTime Function() _today;

  @override
  Future<Json> rules() async => _rules.describe(null);

  @override
  Future<Json> estimate(Json input) async => estimateIndiaTax(_rules, TaxInput.parse(input));

  /// Editable, traceable tax-input suggestions (routers/tax.py /profile).
  @override
  Future<Json> profile(String taxYear) async {
    final rules = _rules.forYear(taxYear);
    final startYear = int.parse((rules['tax_year'] as String).split('-').first);
    final periodStart = DateTime(startYear, 4, 1);
    final periodEnd = DateTime(startYear + 1, 3, 31);
    final now = _today();
    final today = DateTime(now.year, now.month, now.day);
    final asOf = today.isBefore(periodEnd) ? today : periodEnd;

    final user = _db.queryOne('SELECT monthly_income_minor, currency FROM profile LIMIT 1') ?? {};
    final currency = (user['currency'] as String? ?? 'INR').toUpperCase();
    final inr = currency == 'INR';

    final transactions = _db.query('''
      SELECT t.amount_minor, t.type, t.description, t.date,
             COALESCE(c.name, '') AS category_name, COALESCE(sc.name, '') AS subcategory_name, COALESCE(t.notes, '') AS notes
      FROM transactions t
      LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN subcategories sc ON sc.id = t.subcategory_id
      WHERE t.status = 'CONFIRMED' AND t.date >= ? AND t.date <= ? AND t.type IN ('INCOME', 'EXPENSE')
      ORDER BY t.date DESC''', [dateOnly(periodStart), dateOnly(asOf)]);

    final totals = {
      for (final k in const ['salary', 'interest', 'dividends', 'rental_gross', 'business_gross', 'other_income',
        'capital_gains_records', 'deduction_80c', 'deduction_80d']) k: 0.0,
    };
    final groups = {
      for (final k in const ['salary', 'interest', 'dividends', 'other_income', 'deduction_80c', 'deduction_80d']) k: <String, Json>{},
    };
    bool any(String label, List<String> terms) => terms.any(label.contains);

    for (final row in transactions) {
      if (!inr) continue;
      final category = (row['category_name'] as String).toLowerCase();
      final label = [category, (row['subcategory_name'] as String).toLowerCase(), (row['description'] as String).toLowerCase(),
        (row['notes'] as String).toLowerCase()].join(' ');
      final amount = fromMinor(row['amount_minor'] as int);
      String key;
      if (row['type'] == 'INCOME') {
        if (label.contains('dividend')) {
          key = 'dividends';
        } else if (any(label, const ['interest', 'fixed deposit', 'fd/savings', 'fd '])) {
          key = 'interest';
        } else if (any(label, const ['salary', 'payroll', 'monthly salary'])) {
          key = 'salary';
        } else if (any(label, const ['rental', 'rent income'])) {
          key = 'rental_gross';
        } else if (any(label, const ['business', 'freelance'])) {
          key = 'business_gross';
        } else if (any(label, const ['capital gain', 'stock gain', 'mutual fund gain'])) {
          key = 'capital_gains_records';
        } else {
          key = 'other_income';
        }
      } else if (label.contains('health insurance') || (category.contains('insurance') && label.contains('health'))) {
        key = 'deduction_80d';
      } else if (any(label, const ['ppf', 'elss', 'provident fund', 'life insurance', 'tuition fee', 'section 80c'])) {
        key = 'deduction_80c';
      } else {
        continue;
      }
      totals[key] = totals[key]! + amount;
      final bucket = groups[key];
      if (bucket != null) {
        final categoryName = (row['category_name'] as String).isEmpty ? 'Uncategorised' : row['category_name'] as String;
        final sub = row['subcategory_name'] as String;
        final g = bucket.putIfAbsent('$categoryName|$sub', () => {'category': categoryName, 'subcategory': sub, 'amount': 0.0, 'count': 0});
        g['amount'] = (g['amount'] as double) + amount;
        g['count'] = (g['count'] as int) + 1;
      }
    }

    final healthPolicies = inr ? _healthPolicies(periodStart, periodEnd) : <Json>[];
    final healthPremium = healthPolicies.fold<double>(0, (s, p) => s + (p['annual_premium'] as double));
    final profileSalary = inr ? fromMinor(user['monthly_income_minor'] as int? ?? 0) * 12 : 0.0;
    final salaryCandidate = profileSalary != 0 ? profileSalary : totals['salary']!;
    final healthCandidate = totals['deduction_80d'] != 0 ? totals['deduction_80d']! : healthPremium;

    Json suggestion(double value, String source, String note, [String period = 'tax-year-to-date']) =>
        {'value': pyRound(value, 2), 'source': source, 'note': note, 'period': period};

    return {
      'tax_year': rules['tax_year'],
      'stored_profile_currency': currency,
      'currency_warning': inr
          ? null
          : 'Your profile currency is $currency; Finverse skipped monetary auto-suggestions to avoid treating those amounts as INR. Enter verified INR tax-year amounts manually.',
      'period_start': dateOnly(periodStart),
      'period_end': dateOnly(periodEnd),
      'as_of': dateOnly(asOf),
      'suggestions': {
        'salary_income': suggestion(
          salaryCandidate,
          profileSalary != 0 ? 'Monthly profile income × 12' : 'Recorded salary transactions',
          'Profile amount is an annualized estimate. Compare it with gross salary in your payslips / Form 16. Recorded salary transactions are only year-to-date.',
          profileSalary != 0 ? 'annualized-profile' : 'tax-year-to-date',
        ),
        'interest_income': suggestion(totals['interest']!, 'Money: interest-category income transactions',
            'Only recorded income transactions from this tax year; add any missing bank / FD interest and confirm the annual total.'),
        'dividend_income': suggestion(totals['dividends']!, 'Money: dividend-category income transactions',
            'Only dividends entered in Money. Stock holdings do not contain dividend events or historical share quantities.'),
        'other_regular_income': suggestion(totals['other_income']!, 'Money: other income transactions',
            'Recorded other income only; check whether each item is taxable at ordinary slab rates.'),
        'section_80c': suggestion(totals['deduction_80c']!, 'Money: tagged 80C / PPF / ELSS / EPF / life-insurance / tuition expenses',
            'Category and description matches are suggestions only; verify each amount is eligible and paid in this tax year.'),
        'section_80d': suggestion(
          healthCandidate,
          totals['deduction_80d'] != 0 ? 'Money: health premium transactions' : 'Insurance: active health-policy annual premiums',
          'Confirm the premium was paid in this tax year and check age / covered-person limits. Policy premiums are not proof of payment.',
        ),
      },
      'unclassified_tax_sources': {
        'rental_gross_received': pyRound(totals['rental_gross']!, 2),
        'business_gross_receipts': pyRound(totals['business_gross']!, 2),
        'capital_gain_related_transactions': pyRound(totals['capital_gains_records']!, 2),
        'note': 'Rental receipts, business receipts, and capital-gain-tagged transactions are shown for review but are not inserted into taxable-income fields because expenses, holding periods, cost basis, and special tax rates are not derived here.',
      },
      'health_policies': [
        for (final p in healthPolicies) {'name': p['policy_name'], 'annual_premium': p['annual_premium'], 'payment_status': p['payment_status']},
      ],
      'transaction_breakdown': {
        for (final e in groups.entries)
          e.key: (e.value.values.map((g) => {...g, 'amount': pyRound(g['amount'] as double, 2)}).toList()
            ..sort((a, b) => (b['amount'] as double).compareTo(a['amount'] as double))),
      },
      'salary_recorded_ytd': pyRound(totals['salary']!, 2),
      'home_loans': _homeLoans(),
      'investment_holdings': _holdings(),
      'data_gaps': const [
        'Bank and FD interest is suggested only when it has been recorded as an income transaction.',
        'Dividend totals include recorded dividend transactions only; no dividend history is stored for holdings.',
        "Home-loan EMI and rate do not reveal interest paid during the year; use the lender's annual interest certificate.",
        'Income from rentals and business is not inserted automatically because taxable income needs expense / allowance calculations.',
      ],
    };
  }

  // Insurance, holdings and loans move to the phone in later parts of step 4;
  // these read them once their tables exist.
  bool _hasTable(String name) => _db.queryOne("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) != null;

  List<Json> _healthPolicies(DateTime start, DateTime end) {
    if (!_hasTable('insurance_policies')) return [];
    return [
      for (final r in _db.query('''
        SELECT policy_name, annual_premium_minor, payment_status FROM insurance_policies
        WHERE policy_type = 'HEALTH' AND status = 'ACTIVE'
          AND (start_date IS NULL OR start_date <= ?) AND (renewal_date IS NULL OR renewal_date >= ?)
        ORDER BY policy_name''', [dateOnly(end), dateOnly(start)]))
        {'policy_name': r['policy_name'], 'annual_premium': fromMinor(r['annual_premium_minor'] as int), 'payment_status': r['payment_status']},
    ];
  }

  List<Json> _homeLoans() {
    if (!_hasTable('debts')) return [];
    return [
      for (final r in _db.query("SELECT debt_name, monthly_emi_minor, interest_rate_pct FROM debts WHERE debt_type = 'HOME_LOAN' ORDER BY debt_name"))
        {'name': r['debt_name'], 'emi': fromMinor(r['monthly_emi_minor'] as int? ?? 0), 'interest_rate': (r['interest_rate_pct'] as num?)?.toDouble() ?? 0.0},
    ];
  }

  List<Json> _holdings() {
    if (!_hasTable('assets')) return [];
    return [
      for (final r in _db.query("SELECT name, quantity, purchase_date, meta_data FROM assets WHERE asset_class IN ('EQUITY', 'MUTUAL_FUND') ORDER BY name"))
        {
          'name': r['name'],
          'symbol': _symbol(r['meta_data'] as String?),
          'quantity': math.max(0.0, (r['quantity'] as num?)?.toDouble() ?? 0.0),
          'purchase_date': r['purchase_date'],
        },
    ];
  }

  static String? _symbol(String? meta) {
    if (meta == null) return null;
    final m = RegExp(r'"(?:symbol|ticker)"\s*:\s*"([^"]+)"').firstMatch(meta);
    return m?.group(1);
  }
}
