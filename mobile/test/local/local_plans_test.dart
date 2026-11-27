import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/local_plans.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Goals, debts and insurance on the phone, checked against the rules in
/// backend/app/routers/{goals,debts,insurance_policies}.py.
void main() {
  late LocalDb db;
  final today = DateTime(2026, 11, 23);
  setUp(() => db = LocalDb.inMemory());
  tearDown(() => db.close());

  Future<Object?> errorOf(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      return e;
    }
    return null;
  }

  group('goals', () {
    late LocalGoalsService goals;
    setUp(() => goals = LocalGoalsService(db, today: () => today));

    Map<String, dynamic> goal({double target = 120000, double current = 0, String date = '2027-11-23', int priority = 3}) => {
          'goal_name': 'Goa trip',
          'goal_type': 'VACATION',
          'target_amount': target,
          'current_amount': current,
          'target_date': date,
          'priority': priority,
          'allocated_monthly_savings': 5000,
        };

    test('create works out progress and a suggested monthly saving', () async {
      await goals.create(goal(current: 30000));
      final g = (await goals.list()).single;
      expect(g['progress_percentage'], 25.0);
      // 365 days ≈ ceil(365 / 30) = 13 months for the remaining 90,000.
      expect(g['suggested_monthly_savings'], 6923.08);
      expect(g['status'], 'ACTIVE');
      expect(g['month_contributed'], 0.0);
    });

    test('rules and messages match the backend', () async {
      expect((await errorOf(() => goals.create(goal(current: 200000)))).toString(), 'Already saved amount cannot exceed the target amount.');
      expect((await errorOf(() => goals.create(goal(target: 0)))).toString(), 'Target amount: Input should be greater than 0');
      expect((await errorOf(() => goals.create({...goal(), 'goal_name': ''}))).toString(), 'Goal name: String should have at least 1 character');
      expect((await errorOf(() => goals.create(goal(priority: 9)))).toString(), 'Priority: Input should be less than or equal to 5');
    });

    test('contributions add up and complete the goal at the target', () async {
      await goals.create(goal(target: 10000, current: 2000));
      final id = (await goals.list()).single['id'] as String;
      await goals.addContribution(id, 3000);
      var g = (await goals.list()).single;
      expect(g['current_amount'], 5000.0);
      expect(g['progress_percentage'], 50.0);
      expect(g['month_contributed'], 3000.0);

      await goals.addContribution(id, 6000);
      g = (await goals.list()).single;
      expect(g['status'], 'COMPLETED');
      expect(g['progress_percentage'], 100.0);
      expect((await errorOf(() => goals.addContribution(id, 1))).toString(), 'Only active goals can receive contributions.');
    });

    test('ordering, update and summary', () async {
      await goals.create({...goal(priority: 4), 'goal_name': 'Car'});
      await goals.create({...goal(priority: 1, date: '2030-01-01'), 'goal_name': 'House'});
      await goals.create({...goal(priority: 1, date: '2028-01-01'), 'goal_name': 'Emergency fund'});
      expect((await goals.list()).map((g) => g['goal_name']), ['Emergency fund', 'House', 'Car']);

      final car = (await goals.list()).last['id'] as String;
      await goals.update(car, {'status': 'COMPLETED', 'current_amount': 60000});
      final s = await goals.progressSummary();
      expect(s['total_goals'], 3);
      expect(s['completed_goals'], 1);
      expect(s['active_goals'], 2);
      expect(s['total_target_amount'], 360000.0);
      expect(s['total_current_amount'], 60000.0);
      expect(s['total_monthly_allocation'], 15000.0);

      await goals.delete(car);
      expect((await errorOf(() => goals.delete(car))).toString(), 'Goal not found');
    });
  });

  group('goal kinds and saving history', () {
    late LocalGoalsService goals;
    setUp(() => goals = LocalGoalsService(db, today: () => today));

    test('things to buy (car, bike…) are saved and come back as their own type', () async {
      await goals.create({'goal_name': 'New bike', 'goal_type': 'BIKE', 'target_amount': 90000, 'target_date': '2027-06-01'});
      var g = (await goals.list()).single;
      expect(g['goal_type'], 'BIKE');
      expect(db.queryOne('SELECT goal_type, goal_kind FROM goals')!.values, ['OTHER', 'BIKE']);

      await goals.update(g['id'] as String, {'goal_type': 'CAR'});
      expect((await goals.list()).single['goal_type'], 'CAR');
      await goals.update(g['id'] as String, {'goal_type': 'VACATION'});
      g = (await goals.list()).single;
      expect(g['goal_type'], 'VACATION');
      expect(db.queryOne('SELECT goal_kind FROM goals')!['goal_kind'], isNull);
      expect((await errorOf(() => goals.update(g['id'] as String, {'goal_type': 'YACHT'}))).toString(), 'Goal type: Choose a valid goal type');
    });

    test('each month is saved, short, missed or still open, with a streak', () {
      final goal = {'allocated_monthly_savings': 5000.0, 'suggested_monthly_savings': 0.0, 'created_at': '2026-06-10T00:00:00.000Z'};
      final h = goalSavingHistory(goal, {'2026-08': 500000, '2026-09': 600000, '2026-10': 500000, '2026-07': 100000},
          today: today, months: 6);
      expect([for (final m in h['months'] as List) m['status']], ['before', 'partial', 'met', 'met', 'met', 'open']);
      expect(h['streak'], 3); // Aug–Oct; November not met yet
      expect(h['plan'], 5000.0);
      expect(h['left_this_month'], 5000.0);

      final missed = goalSavingHistory(goal, {'2026-11': 500000}, today: today, months: 3);
      expect([for (final m in missed['months'] as List) m['status']], ['missed', 'missed', 'met']);
      expect(missed['streak'], 1);
      expect(missed['left_this_month'], 0.0);
    });

    test('goals report this month and the last six months from contributions', () async {
      await goals.create({'goal_name': 'Laptop', 'goal_type': 'GADGET', 'target_amount': 100000, 'target_date': '2027-11-23', 'allocated_monthly_savings': 4000});
      final id = (await goals.list()).single['id'] as String;
      db.execute('UPDATE goals SET created_at = ?', [DateTime(2026, 9, 1).toUtc().toIso8601String()]);
      for (final (date, minor) in [(DateTime(2026, 9, 15), 400000), (DateTime(2026, 10, 3), 150000), (DateTime(2026, 11, 2), 400000)]) {
        db.execute('INSERT INTO goal_contributions (id, goal_id, amount_minor, contributed_at) VALUES (?, ?, ?, ?)',
            [newId(), id, minor, date.toUtc().toIso8601String()]);
      }
      final h = (await goals.list()).single['saving_history'] as Map;
      expect([for (final m in h['months'] as List) m['month']], ['2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11']);
      expect([for (final m in h['months'] as List) m['status']], ['before', 'before', 'before', 'met', 'partial', 'met']);
      expect(h['this_month'], 4000.0);
      expect(h['streak'], 1);
    });
  });

  group('debts', () {
    late LocalDebtsService debts;
    setUp(() => debts = LocalDebtsService(db, today: () => today));

    Map<String, dynamic> debt(String name, {double outstanding = 100000, double rate = 12, double? emi = 5000, int? tenure, String? start}) => {
          'debt_name': name,
          'debt_type': 'PERSONAL_LOAN',
          'principal_amount': 200000,
          'current_outstanding': outstanding,
          'interest_rate_pct': rate,
          'monthly_emi': emi,
          'tenure_months': tenure,
          'start_date': start,
        };

    test('end date follows start date + tenure, and is checked', () async {
      await debts.create(debt('Loan', tenure: 24, start: '2025-01-31'));
      final d = (await debts.list()).single;
      expect(d['end_date'], '2027-01-31');
      await debts.update(d['id'] as String, {'tenure_months': 13});
      expect((await debts.list()).single['end_date'], '2026-02-28');
      expect((await errorOf(() => debts.create({...debt('Bad', start: '2025-05-01'), 'end_date': '2025-04-01'}))).toString(),
          'End date must be after the start date.');
    });

    test('list order, summary and debt-to-income', () async {
      await LocalProfileService(db).updateProfile({'monthly_income': 100000});
      await debts.create(debt('Card', rate: 36, emi: 6000, outstanding: 50000));
      await debts.create(debt('Car', rate: 9, emi: 12000, outstanding: 400000));
      expect((await debts.list()).map((d) => d['debt_name']), ['Card', 'Car']);
      final s = await debts.summary();
      expect(s['total_outstanding'], 450000.0);
      expect(s['total_monthly_emi'], 18000.0);
      expect(s['total_interest_rate_avg'], 22.5); // plain average (see LocalDebtsService.summary)
      expect(s['debt_to_income_ratio'], 18.0);
      expect(s['number_of_debts'], 2);
    });

    test('payoff plans use the debts on the phone', () async {
      await debts.create(debt('Card', rate: 36, emi: 6000, outstanding: 50000));
      await debts.create(debt('Car', rate: 9, emi: 12000, outstanding: 40000));
      await debts.create(debt('Paid off', outstanding: 0));
      final avalanche = await debts.payoffPlan('avalanche');
      expect((avalanche['recommended_order'] as List).map((r) => r['debt_name']), ['Card', 'Car']);
      final snowball = await debts.payoffPlan('snowball');
      expect((snowball['recommended_order'] as List).map((r) => r['debt_name']), ['Car', 'Card']);
      expect(snowball['motivation_wins'], 2);
    });

    test('net worth subtracts what you owe', () async {
      await LocalAccountsService(db).create({'name': 'Bank', 'account_type': 'SAVINGS', 'balance': 500000});
      await debts.create(debt('Car', outstanding: 150000, emi: 8000));
      final w = await LocalAssetsService(db).summary();
      expect(w['net_worth'], 350000.0);
      expect(w['total_liabilities_outstanding'], 150000.0);
      expect(w['total_monthly_emi'], 8000.0);
    });
  });

  group('insurance', () {
    late LocalInsuranceService insurance;
    setUp(() => insurance = LocalInsuranceService(db, today: () => today));

    Map<String, dynamic> policy(String name, String type, double cover, {String? renewal}) => {
          'policy_name': name,
          'policy_type': type,
          'sum_insured': cover,
          'annual_premium': 12000,
          'renewal_date': renewal,
        };

    test('summary flags cover gaps against income and counts renewals', () async {
      await LocalProfileService(db).updateProfile({'monthly_income': 100000});
      await insurance.create(policy('Family floater', 'HEALTH', 500000, renewal: '2026-12-10'));
      await insurance.create(policy('Car', 'MOTOR', 600000, renewal: '2027-06-01'));
      var s = await insurance.summary();
      expect(s['total_policies'], 2);
      expect(s['upcoming_renewals'], 1);
      expect(s['health_coverage_adequate'], true); // 5,00,000 >= 5 × 1,00,000
      expect(s['life_coverage_adequate'], false);
      expect(s['critical_gaps'], ['No adequate term life insurance coverage']);
      expect(s['next_renewal_date'], '2026-12-10');

      await insurance.create(policy('Term plan', 'TERM_LIFE', 10000000));
      s = await insurance.summary();
      expect(s['life_coverage_adequate'], true);
      expect(s['critical_gaps'], isEmpty);
    });

    test('list order, update, delete and validation', () async {
      await insurance.create(policy('B', 'HEALTH', 300000));
      await insurance.create(policy('A', 'HEALTH', 300000, renewal: '2027-01-01'));
      await insurance.create(policy('C', 'CRITICAL_ILLNESS', 300000));
      expect((await insurance.list()).map((p) => p['policy_name']), ['C', 'A', 'B']);

      final id = (await insurance.list()).last['id'] as String;
      await insurance.update(id, {'payment_status': 'PAID', 'insurer_name': null});
      expect((await insurance.list()).last['payment_status'], 'PAID');
      await insurance.delete(id);
      expect((await errorOf(() => insurance.delete(id))).toString(), 'Policy not found');
      expect((await errorOf(() => insurance.create(policy('X', 'HEALTH', 0)))).toString(), 'Sum insured: Input should be greater than 0');
    });
  });
}
