import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_insights.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDb db;
  final now = DateTime(2026, 11, 24, 10, 30);
  const food = '00000000-0000-0000-0000-000000000011';
  const shopping = '00000000-0000-0000-0000-000000000015';
  const health = '00000000-0000-0000-0000-000000000014';
  const salary = '00000000-0000-0000-0000-000000000001';
  var n = 0;

  setUp(() {
    db = LocalDb.inMemory();
    db.execute("INSERT INTO accounts (id, name, account_type, created_at, updated_at) VALUES ('a1', 'HDFC', 'SAVINGS', 'x', 'x')");
  });
  tearDown(() => db.close());

  String tx(String date, double amount,
      {String type = 'EXPENSE', String? category = food, String description = 'Shop', String source = 'MANUAL', String status = 'CONFIRMED', String? merchantKey, String? scheduleId}) {
    final id = 't${n++}';
    db.execute('''INSERT INTO transactions (id, account_id, category_id, type, amount_minor, date, description, source, status, merchant_key, scheduled_cashflow_id, created_at)
                  VALUES (?, 'a1', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'x')''',
        [id, category, type, (amount * 100).round(), date, description, source, status, merchantKey, scheduleId]);
    return id;
  }

  void budget(String category, double limit, {int month = 11, int year = 2026}) => db.execute(
      "INSERT INTO budgets (id, category_id, monthly_limit_minor, month, year, created_at) VALUES (?, ?, ?, ?, ?, 'x')",
      ['b$category$month', category, (limit * 100).round(), month, year]);

  List<Json> insights({DateTime? at}) => InsightEngine(db, at ?? now).insights();
  Json? byKey(String prefix, {DateTime? at}) {
    for (final i in insights(at: at)) {
      if ((i['key'] as String).startsWith(prefix)) return i;
    }
    return null;
  }

  group('budgets', () {
    test('over budget is an alert that is sent as a notification', () {
      budget(food, 5000);
      tx('2026-11-03', 3000);
      tx('2026-11-20', 2600);
      final i = byKey('budget-over:$food:2026-11')!;
      expect(i['severity'], 'alert');
      expect(i['notify'], isTrue);
      expect(i['title'], 'Food & Groceries is over budget');
      expect(i['body'], contains('₹600 more than planned'));
    });

    test('80% used warns with what is left for the rest of the month', () {
      budget(food, 10000);
      tx('2026-11-03', 8500);
      final i = byKey('budget-80:$food')!;
      expect(i['title'], 'Food & Groceries: 85% of budget used');
      expect(i['body'], '₹1,500 left for the next 7 days.');
    });

    test('spending pace beyond the budget is a quiet hint', () {
      budget(food, 10000);
      tx('2026-11-05', 7000); // 7000 in 24 days -> ~8750; under 110%: nothing
      expect(byKey('budget-pace'), isNull);
      tx('2026-11-06', 900); // 7900 -> ~9875 still under; 79% used
      expect(byKey('budget-pace'), isNull);
      final early = DateTime(2026, 11, 10);
      expect(byKey('budget-pace', at: early)!['notify'], isFalse);
    });

    test('pending and ignored payments do not count', () {
      budget(food, 1000);
      tx('2026-11-03', 5000, status: 'PENDING');
      tx('2026-11-03', 5000, status: 'IGNORED');
      expect(byKey('budget'), isNull);
    });
  });

  group('spending compared with usual', () {
    void history() {
      for (final m in ['08', '09', '10']) {
        tx('2026-$m-02', 10000, description: 'Rent', category: '00000000-0000-0000-0000-000000000010');
        tx('2026-$m-10', 4000);
        tx('2026-$m-12', 1000, category: shopping);
      }
    }

    test('flags a category well above the usual for this point of the month', () {
      history();
      tx('2026-11-02', 10000, description: 'Rent', category: '00000000-0000-0000-0000-000000000010');
      tx('2026-11-10', 4000);
      tx('2026-11-15', 6000, category: shopping);
      final i = byKey('spend-cat:$shopping:2026-11')!;
      expect(i['title'], 'Shopping & Lifestyle is higher than usual');
      expect(i['body'], contains('against about ₹1,000 usually by the 24th'));
      expect(byKey('spend-high'), isNotNull); // 20,000 vs 15,000 = +33%
    });

    test('needs two fully tracked months before comparing', () {
      tx('2026-10-15', 100);
      tx('2026-11-10', 50000);
      expect(byKey('spend'), isNull);
    });

    test('a category with a budget alert is not mentioned twice', () {
      history();
      budget(shopping, 3000);
      tx('2026-11-15', 6000, category: shopping);
      expect(byKey('budget-over:$shopping'), isNotNull);
      expect(byKey('spend-cat:$shopping'), isNull);
    });

    test('spending less than usual late in the month is good news', () {
      history();
      tx('2026-11-02', 5000);
      final i = byKey('spend-low')!;
      expect(i['severity'], 'good');
    });
  });

  group('unusual and double payments', () {
    test('a payment far above the usual for its category', () {
      for (var d = 1; d <= 6; d++) {
        tx('2026-10-${d.toString().padLeft(2, '0')}', 500, category: health);
      }
      final id = tx('2026-11-22', 18000, category: health, description: 'Apollo Hospitals');
      final i = byKey('unusual:$id')!;
      expect(i['body'], contains('₹18,000 for Apollo Hospitals on 22 Nov'));
      expect(i['body'], contains('about ₹500'));
    });

    test('ordinary payments and older ones are not flagged', () {
      for (var d = 1; d <= 6; d++) {
        tx('2026-10-0$d', 3000, category: health);
      }
      tx('2026-11-22', 4000, category: health);
      tx('2026-11-01', 40000, category: health); // more than 7 days ago
      expect(byKey('unusual'), isNull);
    });

    test('the same payment entered by hand and captured from SMS', () {
      final a = tx('2026-11-20', 1250, description: 'Lunch with team');
      final b = tx('2026-11-21', 1250, description: 'SWIGGY', source: 'SMS', merchantKey: 'swiggy');
      final i = byKey('dup:')!;
      expect(i['key'], 'dup:$a:$b');
      expect(i['body'], contains('(20 Nov and 21 Nov)'));
    });

    test('two different small purchases are not duplicates', () {
      tx('2026-11-20', 1250, description: 'Swiggy', source: 'SMS', merchantKey: 'swiggy');
      tx('2026-11-20', 1250, description: 'Zomato', source: 'SMS', merchantKey: 'zomato');
      tx('2026-11-20', 120, description: 'Tea');
      tx('2026-11-20', 120, description: 'Tea');
      expect(byKey('dup:'), isNull);
    });
  });

  group('bills, renewals, goals', () {
    void schedule(String id, String start, double amount, {String desc = 'Electricity'}) => db.execute('''
        INSERT INTO scheduled_cashflows (id, account_id, description, flow_type, source_type, amount_minor, frequency, start_date, created_at, updated_at)
        VALUES (?, 'a1', ?, 'EXPENSE', 'BILL', ?, 'MONTHLY', ?, 'x', 'x')''', [id, desc, (amount * 100).round(), start]);

    test('upcoming and overdue bills, and a paid one is quiet', () {
      schedule('s1', '2026-01-26', 1200);
      schedule('s2', '2026-01-20', 499, desc: 'Netflix');
      schedule('s3', '2026-01-15', 800, desc: 'Broadband');
      tx('2026-11-15', 800, scheduleId: 's3');
      db.execute("UPDATE transactions SET scheduled_occurrence_date = '2026-11-15' WHERE scheduled_cashflow_id = 's3'");
      final due = byKey('bill:s1:2026-11-26')!;
      expect(due['title'], 'Electricity due in 2 days');
      expect(due['body'], '₹1,200 on Thursday, 26 Nov.');
      expect(byKey('bill-overdue:s2:2026-11-20')!['title'], 'Overdue: Netflix');
      expect(byKey('bill-overdue:s3'), isNull);
    });

    test('reminders: the day before at 9, summary on the 1st, check-in in 3 days', () {
      schedule('s1', '2026-01-26', 1200);
      schedule('s2', '2026-01-25', 300, desc: 'Gym');
      final r = InsightEngine(db, now).reminders();
      final bill = r.firstWhere((x) => x['key'] == 'bill:s1:2026-11-26');
      expect(bill['at'], DateTime(2026, 11, 25, 9).toIso8601String());
      expect(bill['title'], 'Due tomorrow: Electricity');
      // Due tomorrow, but 9:00 today has passed: remind on the morning itself.
      expect(r.firstWhere((x) => x['key'] == 'bill:s2:2026-11-25')['at'], DateTime(2026, 11, 25, 9).toIso8601String());
      expect(r.firstWhere((x) => x['kind'] == 'summary')['at'], DateTime(2026, 12, 1, 9).toIso8601String());
      expect(r.firstWhere((x) => x['kind'] == 'checkin')['at'], DateTime(2026, 11, 27, 20).toIso8601String());
      expect(r.every((x) => DateTime.parse(x['at'] as String).isAfter(now)), isTrue);
    });

    test('policy renewal soon, and a missed one', () {
      db.execute('''INSERT INTO insurance_policies (id, policy_name, policy_type, sum_insured_minor, annual_premium_minor, renewal_date, created_at, updated_at)
                    VALUES ('p1', 'Family health', 'HEALTH', 50000000, 1800000, '2026-11-28', 'x', 'x'),
                           ('p2', 'Bike', 'MOTOR', 100000, 200000, '2026-11-14', 'x', 'x')''');
      final soon = byKey('renewal:p1')!;
      expect(soon['title'], 'Family health renews in 4 days');
      expect(soon['severity'], 'warning');
      expect(byKey('renewal-passed:p2')!['severity'], 'alert');
    });

    test('goal close to its date', () {
      db.execute('''INSERT INTO goals (id, goal_name, goal_type, target_amount_minor, current_amount_minor, target_date, created_at, updated_at)
                    VALUES ('g1', 'Goa trip', 'VACATION', 6000000, 4500000, '2027-01-23', 'x', 'x')''');
      final i = byKey('goal-due:g1')!;
      expect(i['title'], 'Goa trip: 60 days to go');
      expect(i['body'], '75% saved. ₹15,000 still needed by 23 Jan.');
    });
  });

  test('a payment made every month suggests adding it to bills', () {
    for (final m in ['08', '09', '10']) {
      tx('2026-$m-05', 649, description: 'NETFLIX', source: 'SMS', merchantKey: 'netflix', category: '00000000-0000-0000-0000-000000000016');
    }
    final i = byKey('recurring:netflix')!;
    expect(i['title'], 'Looks like a monthly payment: NETFLIX');
    expect(i['body'], contains('₹649'));
  });

  test('monthly summary in the first days of the month', () {
    tx('2026-10-01', 90000, type: 'INCOME', category: salary, description: 'Salary');
    tx('2026-10-05', 20000);
    tx('2026-10-08', 10000, category: shopping);
    tx('2026-09-05', 25000);
    final at = DateTime(2026, 11, 3, 8);
    final i = byKey('summary:2026-10', at: at)!;
    expect(i['title'], 'October in short');
    expect(i['severity'], 'good');
    expect(
      i['body'],
      'Income ₹90,000, spent ₹30,000, saved ₹60,000 (66%). Most went on Food & Groceries (₹20,000). Spending was 20% higher than in September.',
    );
    expect(byKey('summary'), isNull); // not on the 24th
  });

  test('amounts can be hidden', () {
    budget(food, 1000);
    tx('2026-11-03', 5000);
    final i = InsightEngine(db, now, hideAmounts: true).insights().first;
    expect(i['body'], isNot(contains('5,000')));
    expect(i['body'], contains('₹ ••••'));
  });

  test('alerts come first', () {
    budget(food, 1000);
    tx('2026-11-03', 5000);
    tx('2026-10-01', 90000, type: 'INCOME', category: salary);
    final all = insights(at: DateTime(2026, 11, 3, 8));
    expect(all.first['severity'], 'alert');
  });

  group('service', () {
    test('dismissed insights stay hidden; settings and notified keys persist', () async {
      final s = LocalInsightsService(db, now: () => now);
      budget(food, 1000);
      tx('2026-11-03', 5000);
      final key = (await s.list()).single['key'] as String;
      await s.dismiss(key);
      expect(await s.list(), isEmpty);

      expect(await s.markNotified([key, 'other']), [key, 'other']);
      expect(await s.markNotified([key, 'new']), ['new']);

      expect((await s.settings())['enabled'], isTrue);
      await s.updateSettings({'kinds': {'checkin': false, 'nonsense': true}});
      final settings = await s.settings();
      expect((settings['kinds'] as Map)['checkin'], isFalse);
      expect((settings['kinds'] as Map)['budget'], isTrue);
      expect((settings['kinds'] as Map).containsKey('nonsense'), isFalse);
    });

    test('old dismissals are forgotten', () async {
      var clock = now;
      final s = LocalInsightsService(db, now: () => clock);
      await s.dismiss('old');
      clock = now.add(const Duration(days: 200));
      await s.dismiss('new');
      final stored = db.queryOne("SELECT value FROM app_settings WHERE key = 'insights_dismissed'")!['value'] as String;
      expect(stored, isNot(contains('old')));
    });
  });
}
