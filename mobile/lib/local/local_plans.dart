/// Goals, debts and insurance policies on the phone, translated from
/// backend/app/routers/{goals,debts,insurance_policies}.py.
library;

import 'dart:math' as math;

import '../services/errors.dart';
import '../services/services.dart';
import 'debt_math.dart';
import 'local_db.dart';
import 'local_money.dart' show localUserId;
import 'py_round.dart' show toMinor, fromMinor;
import 'validate.dart';

/// Pydantic `Field(min_length=1, max_length=255)` for names.
String _name(Json input, String field, {bool required = true}) {
  final value = readString(input, field, required: required)!;
  if (value.isEmpty) throw ValidationException(field, 'String should have at least 1 character');
  if (value.length > 255) throw ValidationException(field, 'String should have at most 255 characters');
  return value;
}

String _choice(Json input, String field, Set<String> allowed, String what) {
  final value = readString(input, field, required: true)!;
  if (!allowed.contains(value)) throw ValidationException(field, 'Choose a valid $what');
  return value;
}

/// NUMERIC(…, 2) columns keep two decimals.
double _dec2(double x) => (x * 100).round() / 100;

double? _money(Object? minor) => minor == null ? null : fromMinor(minor as int);

// ---------------------------------------------------------------------------
// Goals  (routers/goals.py)
// ---------------------------------------------------------------------------

const goalTypes = {'RETIREMENT', 'DOWN_PAYMENT', 'DEBT_PAYOFF', 'WEALTH_BUILD', 'EDUCATION', 'VACATION', 'BUSINESS', 'EMERGENCY_FUND', 'OTHER'};
const goalStatuses = {'ACTIVE', 'PAUSED', 'COMPLETED', 'ABANDONED'};

/// Phone-only goal kinds for things to buy. Stored as goal_type 'OTHER' with
/// goal_kind set (see schema v7), and reported back as the goal type.
const goalKinds = {'CAR', 'BIKE', 'HOME', 'GADGET', 'WEDDING', 'GOLD'};

/// (goal_type, goal_kind) columns for a chosen type.
(String, String?) _goalTypeColumns(Json input) {
  final value = _choice(input, 'goal_type', {...goalTypes, ...goalKinds}, 'goal type');
  return goalKinds.contains(value) ? ('OTHER', value) : (value, null);
}

/// How many months of saving history each goal reports.
const goalHistoryMonths = 6;

class LocalGoalsService implements GoalsService {
  LocalGoalsService(this._db, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final DateTime Function() _today;

  @override
  Future<List<Json>> list() async {
    final now = _today();
    final monthStart = DateTime(now.year, now.month).toUtc().toIso8601String();
    final monthEnd = DateTime(now.year, now.month + 1).toUtc().toIso8601String();
    final goals = _db.query('''
      SELECT g.*, COALESCE((SELECT SUM(c.amount_minor) FROM goal_contributions c
                            WHERE c.goal_id = g.id AND c.contributed_at >= ? AND c.contributed_at < ?), 0) AS month_minor
      FROM goals g ORDER BY g.priority ASC, g.target_date ASC''', [monthStart, monthEnd]).map(_goalOut).toList();
    if (goals.isEmpty) return goals;

    // Saved per month (local calendar months), for "saved / missed" tracking.
    final firstMonth = DateTime(now.year, now.month - (goalHistoryMonths - 1));
    final byGoal = <String, Map<String, int>>{};
    for (final c in _db.query('SELECT goal_id, amount_minor, contributed_at FROM goal_contributions WHERE contributed_at >= ?',
        [firstMonth.toUtc().toIso8601String()])) {
      final at = DateTime.parse(c['contributed_at'] as String).toLocal();
      final key = _monthKey(DateTime(at.year, at.month));
      final months = byGoal.putIfAbsent(c['goal_id'] as String, () => {});
      months[key] = (months[key] ?? 0) + (c['amount_minor'] as int);
    }
    for (final g in goals) {
      g['saving_history'] = goalSavingHistory(
        g,
        byGoal[g['id']] ?? const {},
        today: DateTime(now.year, now.month, now.day),
        months: goalHistoryMonths,
      );
    }
    return goals;
  }

  @override
  Future<Json> progressSummary() async {
    final r = _db.queryOne('''
      SELECT COUNT(*) AS total_goals,
             COALESCE(SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END), 0) AS completed_goals,
             COALESCE(SUM(CASE WHEN status = 'ACTIVE' THEN 1 ELSE 0 END), 0) AS active_goals,
             COALESCE(SUM(target_amount_minor), 0) AS target, COALESCE(SUM(current_amount_minor), 0) AS current,
             COALESCE(SUM(allocated_monthly_minor), 0) AS allocated
      FROM goals''')!;
    return {
      'total_goals': r['total_goals'],
      'completed_goals': r['completed_goals'],
      'active_goals': r['active_goals'],
      'total_target_amount': fromMinor(r['target'] as int),
      'total_current_amount': fromMinor(r['current'] as int),
      'total_monthly_allocation': fromMinor(r['allocated'] as int),
    };
  }

  @override
  Future<void> create(Json goal) async {
    final name = _name(goal, 'goal_name');
    final (type, kind) = _goalTypeColumns(goal);
    final target = readNumber(goal, 'target_amount', required: true, gt: 0)!;
    final current = readNumber(goal, 'current_amount', ge: 0) ?? 0.0;
    final targetDate = readDate(goal, 'target_date', required: true)!;
    final priority = readInt(goal, 'priority', ge: 1, le: 5) ?? 3;
    final description = readString(goal, 'description');
    final allocated = readNumber(goal, 'allocated_monthly_savings', ge: 0) ?? 0.0;
    if (current > target) throw const ServiceException('Already saved amount cannot exceed the target amount.');

    // Suggested monthly saving: what's left, spread over the months remaining.
    final now = _today();
    final days = DateTime.parse(targetDate).difference(DateTime(now.year, now.month, now.day)).inDays;
    final months = math.max((days / 30).ceil(), 1);
    final suggested = (target - current) / months;
    final progress = target > 0 ? math.min(current / target * 100, 100.0) : 0.0;
    final ts = nowTimestamp();
    _db.execute('''
      INSERT INTO goals (id, goal_name, goal_type, goal_kind, target_amount_minor, current_amount_minor, target_date, priority, description,
                         suggested_monthly_minor, allocated_monthly_minor, progress_percentage, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', [
      newId(), name, type, kind, toMinor(target), toMinor(current), targetDate, priority, description,
      toMinor(suggested), toMinor(allocated), _dec2(progress), ts, ts,
    ]);
  }

  /// Fields given (and not null) are changed; progress is recalculated.
  @override
  Future<void> update(String id, Json changes) async {
    final existing = _db.queryOne('SELECT * FROM goals WHERE id = ?', [id]);
    if (existing == null) throw const NotFoundException('Goal not found');
    final columns = <String, Object?>{};
    bool given(String f) => changes[f] != null;
    if (given('goal_name')) columns['goal_name'] = readString(changes, 'goal_name');
    if (given('goal_type')) {
      final (type, kind) = _goalTypeColumns(changes);
      columns['goal_type'] = type;
      columns['goal_kind'] = kind;
    }
    if (given('target_amount')) columns['target_amount_minor'] = toMinor(readNumber(changes, 'target_amount', gt: 0)!);
    if (given('target_date')) columns['target_date'] = readDate(changes, 'target_date');
    if (given('priority')) columns['priority'] = readInt(changes, 'priority', ge: 1, le: 5);
    if (given('description')) columns['description'] = readString(changes, 'description');
    if (given('status')) columns['status'] = _choice(changes, 'status', goalStatuses, 'status');
    if (given('allocated_monthly_savings')) columns['allocated_monthly_minor'] = toMinor(readNumber(changes, 'allocated_monthly_savings', ge: 0)!);
    if (given('current_amount')) columns['current_amount_minor'] = toMinor(readNumber(changes, 'current_amount', ge: 0)!);

    final target = fromMinor((columns['target_amount_minor'] ?? existing['target_amount_minor']) as int);
    final current = fromMinor((columns['current_amount_minor'] ?? existing['current_amount_minor']) as int);
    columns['progress_percentage'] = _dec2(target > 0 ? math.min(current / target * 100, 100.0) : 0.0);
    columns['updated_at'] = nowTimestamp();
    _db.execute('UPDATE goals SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, id]);
  }

  @override
  Future<void> delete(String id) async {
    _db.execute('DELETE FROM goals WHERE id = ?', [id]);
    if (_db.changes == 0) throw const NotFoundException('Goal not found');
  }

  /// Adds money to the goal; reaching the target completes it.
  @override
  Future<void> addContribution(String goalId, double amount) async {
    readNumber({'amount': amount}, 'amount', required: true, gt: 0);
    _db.transaction(() {
      final goal = _db.queryOne('SELECT * FROM goals WHERE id = ?', [goalId]);
      if (goal == null) throw const NotFoundException('Goal not found');
      if (goal['status'] != 'ACTIVE') throw const ServiceException('Only active goals can receive contributions.');
      final amountMinor = toMinor(amount);
      final current = (goal['current_amount_minor'] as int) + amountMinor;
      final target = goal['target_amount_minor'] as int;
      _db.execute('INSERT INTO goal_contributions (id, goal_id, amount_minor, contributed_at) VALUES (?, ?, ?, ?)',
          [newId(), goalId, amountMinor, nowTimestamp()]);
      _db.execute('''UPDATE goals SET current_amount_minor = ?, progress_percentage = ?, status = ?, updated_at = ? WHERE id = ?''', [
        current,
        target == 0 ? 0.0 : _dec2(math.min(current / target * 100, 100.0)),
        current >= target ? 'COMPLETED' : goal['status'],
        nowTimestamp(),
        goalId,
      ]);
    });
  }

  Json _goalOut(Row r) => {
        'id': r['id'],
        'user_id': localUserId,
        'goal_name': r['goal_name'],
        'goal_type': r['goal_kind'] ?? r['goal_type'],
        'target_amount': fromMinor(r['target_amount_minor'] as int),
        'current_amount': fromMinor(r['current_amount_minor'] as int),
        'target_date': r['target_date'],
        'priority': r['priority'],
        'description': r['description'],
        'status': r['status'],
        'suggested_monthly_savings': fromMinor(r['suggested_monthly_minor'] as int),
        'allocated_monthly_savings': fromMinor(r['allocated_monthly_minor'] as int),
        'progress_percentage': (r['progress_percentage'] as num?)?.toDouble() ?? 0.0,
        'month_contributed': fromMinor(r['month_minor'] as int? ?? 0),
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };
}

String _monthKey(DateTime m) => '${m.year}-${m.month.toString().padLeft(2, '0')}';

/// The goal's last [months] calendar months, oldest first, each with how
/// much was saved and whether that met the monthly plan:
///   status 'met' (saved at least the plan), 'partial', 'missed', 'open'
///   (this month, not met yet) or 'before' (before the goal was created,
///   or the month it was created in when nothing was saved then).
/// The plan is the allocated monthly saving, else the suggested one.
/// Also gives `streak`: months in a row that met the plan, counting back
/// from this month if it is already met, else from last month.
Json goalSavingHistory(Json goal, Map<String, int> savedByMonth, {required DateTime today, int months = goalHistoryMonths}) {
  final allocated = toMinor((goal['allocated_monthly_savings'] as num?)?.toDouble() ?? 0);
  final suggested = toMinor((goal['suggested_monthly_savings'] as num?)?.toDouble() ?? 0);
  final plan = allocated > 0 ? allocated : suggested;
  final created = DateTime.tryParse(goal['created_at']?.toString() ?? '')?.toLocal();
  final createdMonth = created == null ? null : DateTime(created.year, created.month);
  final thisMonth = DateTime(today.year, today.month);
  final out = <Json>[];
  for (var i = months - 1; i >= 0; i--) {
    final m = DateTime(today.year, today.month - i);
    final saved = savedByMonth[_monthKey(m)] ?? 0;
    final String status;
    if (plan > 0 && saved >= plan) {
      status = 'met';
    } else if (m == thisMonth) {
      status = saved > 0 && plan == 0 ? 'met' : 'open';
    } else if (createdMonth != null && !m.isAfter(createdMonth) && saved == 0) {
      status = 'before'; // the goal didn't exist yet (or was made late that month)
    } else if (saved > 0) {
      status = plan == 0 ? 'met' : 'partial';
    } else {
      status = 'missed';
    }
    out.add({'month': _monthKey(m), 'saved': fromMinor(saved), 'status': status});
  }
  var streak = 0;
  var i = out.length - 1;
  if (out[i]['status'] != 'met') i--;
  for (; i >= 0 && out[i]['status'] == 'met'; i--) {
    streak++;
  }
  final current = out.last;
  return {
    'plan': fromMinor(plan),
    'this_month': current['saved'],
    'left_this_month': plan > 0 ? fromMinor(math.max(0, plan - toMinor(current['saved'] as double))) : 0.0,
    'streak': streak,
    'months': out,
  };
}

// ---------------------------------------------------------------------------
// Debts  (routers/debts.py)
// ---------------------------------------------------------------------------

const debtTypes = {'CREDIT_CARD', 'PERSONAL_LOAN', 'HOME_LOAN', 'CAR_LOAN', 'EDUCATION_LOAN', 'GOLD_LOAN', 'BUSINESS_LOAN', 'OTHER'};
const payoffStrategies = {'SNOWBALL', 'AVALANCHE', 'STANDARD'};

class LocalDebtsService implements DebtsService {
  LocalDebtsService(this._db, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final DateTime Function() _today;

  @override
  Future<List<Json>> list() async =>
      _db.query('SELECT * FROM debts ORDER BY priority_payoff DESC, interest_rate_pct DESC').map(_debtOut).toList();

  /// Totals for the Debts screen. Note: the backend averaged the debts'
  /// interest rate with the (empty) liabilities table, halving it; on the
  /// phone there is one debts table, so this is the plain average.
  @override
  Future<Json> summary() async {
    final d = _db.queryOne('''
      SELECT COALESCE(SUM(current_outstanding_minor), 0) AS outstanding, COALESCE(SUM(monthly_emi_minor), 0) AS emi,
             COALESCE(AVG(interest_rate_pct), 0) AS avg_rate, COUNT(*) AS n,
             COALESCE(SUM(CASE WHEN priority_payoff = 1 THEN 1 ELSE 0 END), 0) AS high_priority
      FROM debts''')!;
    final income = fromMinor(_db.queryOne('SELECT monthly_income_minor FROM profile LIMIT 1')?['monthly_income_minor'] as int? ?? 0);
    final emi = fromMinor(d['emi'] as int);
    return {
      'total_outstanding': fromMinor(d['outstanding'] as int),
      'total_monthly_emi': emi,
      'total_interest_rate_avg': (d['avg_rate'] as num).toDouble(),
      'debt_to_income_ratio': income > 0 ? emi / income * 100 : 0.0,
      'number_of_debts': d['n'],
      'high_priority_debts': d['high_priority'],
      'estimated_debt_free_date': null,
    };
  }

  @override
  Future<Json> payoffPlan(String strategy) async {
    if (strategy != 'avalanche' && strategy != 'snowball') throw const NotFoundException('Not found');
    final debts = [
      for (final r in _db.query('SELECT * FROM debts WHERE current_outstanding_minor > 0'))
        {
          'id': r['id'],
          'debt_name': r['debt_name'],
          'current_outstanding': fromMinor(r['current_outstanding_minor'] as int),
          'interest_rate_pct': (r['interest_rate_pct'] as num).toDouble(),
          'monthly_emi': _money(r['monthly_emi_minor']),
          'start_date': r['start_date'],
        },
    ];
    final now = _today();
    return debtPayoffPlan(debts, strategy, DateTime(now.year, now.month, now.day));
  }

  @override
  Future<void> create(Json debt) async {
    final name = _name(debt, 'debt_name');
    final type = _choice(debt, 'debt_type', debtTypes, 'debt type');
    final principal = readNumber(debt, 'principal_amount', required: true, gt: 0)!;
    final outstanding = readNumber(debt, 'current_outstanding', required: true, ge: 0)!;
    final rate = readNumber(debt, 'interest_rate_pct', required: true, ge: 0)!;
    final tenure = readInt(debt, 'tenure_months', gt: 0);
    final emi = readNumber(debt, 'monthly_emi', ge: 0);
    final start = readDate(debt, 'start_date');
    var end = readDate(debt, 'end_date');
    final interestPaid = readNumber(debt, 'total_interest_paid', ge: 0) ?? 0.0;
    if (start != null && tenure != null && end == null) end = dateOnly(addMonths(DateTime.parse(start), tenure));
    _checkDates(start, end);
    final ts = nowTimestamp();
    _db.execute('''
      INSERT INTO debts (id, debt_name, debt_type, principal_minor, current_outstanding_minor, interest_rate_pct, tenure_months,
                         monthly_emi_minor, start_date, end_date, total_interest_paid_minor, creditor_name, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', [
      newId(), name, type, toMinor(principal), toMinor(outstanding), _dec2(rate), tenure, emi == null ? null : toMinor(emi),
      start, end, toMinor(interestPaid), readString(debt, 'creditor_name'), ts, ts,
    ]);
  }

  /// Like the backend: changing the start date or tenure (without an end
  /// date) recalculates the end date.
  @override
  Future<void> update(String id, Json changes) async {
    final existing = _db.queryOne('SELECT * FROM debts WHERE id = ?', [id]);
    if (existing == null) throw const NotFoundException('Debt not found');
    final columns = <String, Object?>{};
    bool has(String f) => changes.containsKey(f);
    if (has('debt_name')) columns['debt_name'] = _name(changes, 'debt_name');
    if (has('debt_type')) columns['debt_type'] = _choice(changes, 'debt_type', debtTypes, 'debt type');
    if (has('principal_amount')) columns['principal_minor'] = toMinor(readNumber(changes, 'principal_amount', required: true, gt: 0)!);
    if (has('current_outstanding')) columns['current_outstanding_minor'] = toMinor(readNumber(changes, 'current_outstanding', required: true, ge: 0)!);
    if (has('interest_rate_pct')) columns['interest_rate_pct'] = _dec2(readNumber(changes, 'interest_rate_pct', required: true, ge: 0)!);
    if (has('tenure_months')) columns['tenure_months'] = readInt(changes, 'tenure_months', gt: 0);
    if (has('monthly_emi')) {
      final emi = readNumber(changes, 'monthly_emi', ge: 0);
      columns['monthly_emi_minor'] = emi == null ? null : toMinor(emi);
    }
    if (has('start_date')) columns['start_date'] = readDate(changes, 'start_date');
    if (has('end_date')) columns['end_date'] = readDate(changes, 'end_date');
    if (has('total_interest_paid')) columns['total_interest_paid_minor'] = toMinor(readNumber(changes, 'total_interest_paid', required: true, ge: 0)!);
    if (has('priority_payoff')) columns['priority_payoff'] = (readBool(changes, 'priority_payoff') ?? false) ? 1 : 0;
    if (has('payoff_strategy')) columns['payoff_strategy'] = _choice(changes, 'payoff_strategy', payoffStrategies, 'payoff strategy');

    final start = has('start_date') ? columns['start_date'] as String? : existing['start_date'] as String?;
    final tenure = has('tenure_months') ? columns['tenure_months'] as int? : existing['tenure_months'] as int?;
    var end = has('end_date') ? columns['end_date'] as String? : existing['end_date'] as String?;
    if (!has('end_date') && (has('start_date') || has('tenure_months'))) {
      end = start != null && tenure != null ? dateOnly(addMonths(DateTime.parse(start), tenure)) : null;
      columns['end_date'] = end;
    }
    _checkDates(start, end);
    if (columns.isEmpty) return;
    columns['updated_at'] = nowTimestamp();
    _db.execute('UPDATE debts SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, id]);
  }

  @override
  Future<void> delete(String id) async => _db.execute('DELETE FROM debts WHERE id = ?', [id]);

  void _checkDates(String? start, String? end) {
    if (start != null && end != null && end.compareTo(start) <= 0) throw const ServiceException('End date must be after the start date.');
  }

  Json _debtOut(Row r) => {
        'id': r['id'],
        'user_id': localUserId,
        'debt_name': r['debt_name'],
        'debt_type': r['debt_type'],
        'principal_amount': fromMinor(r['principal_minor'] as int),
        'current_outstanding': fromMinor(r['current_outstanding_minor'] as int),
        'interest_rate_pct': (r['interest_rate_pct'] as num).toDouble(),
        'tenure_months': r['tenure_months'],
        'monthly_emi': _money(r['monthly_emi_minor']),
        'start_date': r['start_date'],
        'end_date': r['end_date'],
        'total_interest_paid': fromMinor(r['total_interest_paid_minor'] as int),
        'creditor_name': r['creditor_name'],
        'priority_payoff': r['priority_payoff'] == 1,
        'payoff_strategy': r['payoff_strategy'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };
}

// ---------------------------------------------------------------------------
// Insurance policies  (routers/insurance_policies.py)
// ---------------------------------------------------------------------------

const policyTypes = {'HEALTH', 'TERM_LIFE', 'MOTOR', 'HOME', 'TRAVEL', 'CRITICAL_ILLNESS', 'OTHER'};
const policyStatuses = {'ACTIVE', 'EXPIRED', 'LAPSED', 'RENEWED'};

class LocalInsuranceService implements InsuranceService {
  LocalInsuranceService(this._db, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final DateTime Function() _today;

  @override
  Future<List<Json>> list() async => _db
      .query('SELECT * FROM insurance_policies ORDER BY policy_type ASC, renewal_date IS NULL, renewal_date ASC')
      .map(_policyOut)
      .toList();

  /// Cover totals, renewals and gaps (health cover at least 5 × monthly
  /// income, term life at least 10 ×, as in the backend).
  @override
  Future<Json> summary() async {
    final now = _today();
    final today = dateOnly(now);
    final in30 = dateOnly(DateTime(now.year, now.month, now.day + 30));
    final s = _db.queryOne('''
      SELECT COUNT(*) AS total_policies,
             COALESCE(SUM(CASE WHEN status = 'ACTIVE' THEN 1 ELSE 0 END), 0) AS active_policies,
             COALESCE(SUM(sum_insured_minor), 0) AS insured, COALESCE(SUM(annual_premium_minor), 0) AS premium,
             COUNT(CASE WHEN renewal_date <= ? AND renewal_date >= ? THEN 1 END) AS upcoming_renewals
      FROM insurance_policies''', [in30, today])!;
    final health = _db.queryOne("SELECT COALESCE(SUM(sum_insured_minor), 0) AS t FROM insurance_policies WHERE policy_type IN ('HEALTH', 'CRITICAL_ILLNESS')")!['t'] as int;
    final life = _db.queryOne("SELECT COALESCE(SUM(sum_insured_minor), 0) AS t FROM insurance_policies WHERE policy_type = 'TERM_LIFE'")!['t'] as int;
    final income = fromMinor(_db.queryOne('SELECT monthly_income_minor FROM profile LIMIT 1')?['monthly_income_minor'] as int? ?? 0);
    final healthOk = fromMinor(health) >= income * 5;
    final lifeOk = fromMinor(life) >= income * 10;
    final next = _db.queryOne("SELECT renewal_date FROM insurance_policies WHERE renewal_date IS NOT NULL AND status = 'ACTIVE' ORDER BY renewal_date ASC LIMIT 1");
    return {
      'total_policies': s['total_policies'],
      'active_policies': s['active_policies'],
      'total_sum_insured': fromMinor(s['insured'] as int),
      'total_annual_premium': fromMinor(s['premium'] as int),
      'upcoming_renewals': s['upcoming_renewals'],
      'health_coverage_adequate': healthOk,
      'life_coverage_adequate': lifeOk,
      'critical_gaps': [
        if (!healthOk) 'Health insurance coverage below recommended level',
        if (!lifeOk) 'No adequate term life insurance coverage',
      ],
      'next_renewal_date': next?['renewal_date'],
    };
  }

  @override
  Future<void> create(Json policy) async {
    final name = _name(policy, 'policy_name');
    final type = _choice(policy, 'policy_type', policyTypes, 'policy type');
    final insured = readNumber(policy, 'sum_insured', required: true, gt: 0)!;
    final premium = readNumber(policy, 'annual_premium', required: true, ge: 0)!;
    final ts = nowTimestamp();
    _db.execute('''
      INSERT INTO insurance_policies (id, policy_name, policy_type, sum_insured_minor, annual_premium_minor, policy_number, coverage_type,
        dependents_covered, insurer_name, start_date, renewal_date, payment_frequency, payment_status, next_payment_date, last_payment_date,
        created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', [
      newId(), name, type, toMinor(insured), toMinor(premium), readString(policy, 'policy_number'), readString(policy, 'coverage_type'),
      readInt(policy, 'dependents_covered', ge: 0) ?? 0, readString(policy, 'insurer_name'), readDate(policy, 'start_date'),
      readDate(policy, 'renewal_date'), readString(policy, 'payment_frequency') ?? 'YEARLY', readString(policy, 'payment_status') ?? 'PENDING',
      readDate(policy, 'next_payment_date'), readDate(policy, 'last_payment_date'), ts, ts,
    ]);
  }

  /// Fields given (and not null) are changed.
  @override
  Future<void> update(String id, Json changes) async {
    if (_db.queryOne('SELECT id FROM insurance_policies WHERE id = ?', [id]) == null) throw const NotFoundException('Policy not found');
    final columns = <String, Object?>{};
    bool given(String f) => changes[f] != null;
    if (given('policy_name')) columns['policy_name'] = readString(changes, 'policy_name');
    if (given('policy_type')) columns['policy_type'] = _choice(changes, 'policy_type', policyTypes, 'policy type');
    if (given('sum_insured')) columns['sum_insured_minor'] = toMinor(readNumber(changes, 'sum_insured')!);
    if (given('annual_premium')) columns['annual_premium_minor'] = toMinor(readNumber(changes, 'annual_premium')!);
    for (final f in const ['policy_number', 'coverage_type', 'insurer_name', 'payment_frequency', 'payment_status']) {
      if (given(f)) columns[f] = readString(changes, f);
    }
    if (given('dependents_covered')) columns['dependents_covered'] = readInt(changes, 'dependents_covered');
    for (final f in const ['next_payment_date', 'last_payment_date', 'renewal_date']) {
      if (given(f)) columns[f] = readDate(changes, f);
    }
    if (given('status')) columns['status'] = _choice(changes, 'status', policyStatuses, 'status');
    if (columns.isEmpty) return;
    columns['updated_at'] = nowTimestamp();
    _db.execute('UPDATE insurance_policies SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, id]);
  }

  @override
  Future<void> delete(String id) async {
    _db.execute('DELETE FROM insurance_policies WHERE id = ?', [id]);
    if (_db.changes == 0) throw const NotFoundException('Policy not found');
  }

  Json _policyOut(Row r) => {
        'id': r['id'],
        'user_id': localUserId,
        'policy_name': r['policy_name'],
        'policy_type': r['policy_type'],
        'sum_insured': fromMinor(r['sum_insured_minor'] as int),
        'annual_premium': fromMinor(r['annual_premium_minor'] as int),
        'policy_number': r['policy_number'],
        'start_date': r['start_date'],
        'maturity_date': r['maturity_date'],
        'renewal_date': r['renewal_date'],
        'coverage_type': r['coverage_type'],
        'dependents_covered': r['dependents_covered'],
        'insurer_name': r['insurer_name'],
        'payment_frequency': r['payment_frequency'],
        'payment_status': r['payment_status'],
        'next_payment_date': r['next_payment_date'],
        'last_payment_date': r['last_payment_date'],
        'agent_name': r['agent_name'],
        'status': r['status'],
        'document_url': r['document_url'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };
}
