import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_insights.dart';
import 'package:finance_tracker_mobile/local/local_wealth.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDb db;
  final now = DateTime(2026, 11, 24, 10, 30);
  const food = '00000000-0000-0000-0000-000000000011';
  const shopping = '00000000-0000-0000-0000-000000000015';
  const salary = '00000000-0000-0000-0000-000000000001';
  const groceries = '00000000-0000-0000-0001-000000000010';
  const diningOut = '00000000-0000-0000-0001-000000000011';
  const cash = '00000000-0000-0000-0000-000000000034';
  var n = 0;

  setUp(() {
    db = LocalDb.inMemory();
    db.execute("INSERT INTO accounts (id, name, account_type, balance_minor, created_at, updated_at) VALUES ('a1', 'HDFC', 'SAVINGS', 0, 'x', 'x')");
  });
  tearDown(() => db.close());

  void tx(String date, double amount,
      {String type = 'EXPENSE', String? category = food, String? sub, String description = 'Shop', String? merchant, String? merchantKey}) {
    db.execute('''INSERT INTO transactions (id, account_id, category_id, subcategory_id, type, amount_minor, date, description, merchant, merchant_key,
                    source, status, created_at) VALUES (?, 'a1', ?, ?, ?, ?, ?, ?, ?, ?, 'MANUAL', 'CONFIRMED', 'x')''',
        ['t${n++}', category, sub, type, (amount * 100).round(), date, description, merchant, merchantKey]);
  }

  void balance(double amount) => db.execute("UPDATE accounts SET balance_minor = ? WHERE id = 'a1'", [(amount * 100).round()]);

  List<Json> insights() => InsightEngine(db, now).insights();
  Json? byKey(String prefix) {
    for (final i in insights()) {
      if ((i['key'] as String).startsWith(prefix)) return i;
    }
    return null;
  }

  group('compare months', () {
    test('categories with subcategories and payees, for any two months', () {
      tx('2026-09-05', 900, sub: groceries, merchant: 'DMart', merchantKey: 'dmart');
      tx('2026-10-03', 1000, sub: groceries, merchant: 'DMart', merchantKey: 'dmart');
      tx('2026-10-12', 400, sub: diningOut, merchant: 'Swiggy', merchantKey: 'swiggy');
      tx('2026-10-20', 1900, category: shopping);
      tx('2026-11-04', 1200, sub: groceries, merchant: 'DMart', merchantKey: 'dmart');
      tx('2026-11-08', 300, sub: diningOut, merchant: 'Swiggy', merchantKey: 'swiggy');
      tx('2026-11-09', 500, sub: diningOut, merchant: 'Swiggy', merchantKey: 'swiggy');
      tx('2026-11-10', 50000, type: 'INCOME', category: salary, merchant: 'Acme', merchantKey: 'acme');

      final r = InsightEngine(db, now).compareMonths();
      expect((r['a'] as Json)['month'], '2026-11');
      expect((r['b'] as Json)['month'], '2026-10');
      expect((r['a'] as Json)['partial'], isTrue);
      expect((r['a'] as Json)['expense'], 2000.0);
      expect((r['b'] as Json)['expense'], 3300.0);
      expect([for (final m in (r['available'] as List).cast<Json>()) m['month']], ['2026-11', '2026-10', '2026-09']);

      final cats = (r['categories'] as List).cast<Json>();
      expect(cats.map((c) => c['name']), ['Food & Groceries', 'Shopping & Lifestyle']);
      final f = cats.first;
      expect([f['a'], f['b'], f['count_a'], f['count_b']], [2000.0, 1400.0, 3, 2]);
      final subs = (f['subcategories'] as List).cast<Json>();
      expect(subs.map((s) => [s['name'], s['a'], s['b']]), [
        ['Daily Groceries', 1200.0, 1000.0],
        ['Dining Out', 800.0, 400.0],
      ]);
      final payees = (f['payees'] as List).cast<Json>();
      expect(payees.first, {'name': 'DMart', 'a': 1200.0, 'b': 1000.0, 'count_a': 1, 'count_b': 1});
      expect(payees.last['count_a'], 2);
      expect(cats.last, containsPair('a', 0.0));

      // Older months, income, and the same days only.
      final sept = InsightEngine(db, now).compareMonths(monthA: '2026-10', monthB: '2026-09');
      expect((sept['categories'] as List).length, 2);
      final income = InsightEngine(db, now).compareMonths(type: 'INCOME');
      expect(((income['categories'] as List).single as Json)['name'], 'Salary');
      final early = InsightEngine(db, DateTime(2026, 11, 9)).compareMonths(sameDays: true);
      expect((early['b'] as Json)['to'], '2026-10-09');
      expect((early['b'] as Json)['expense'], 1000.0);
      expect(() => InsightEngine(db, now).compareMonths(monthA: 'Nov'), throwsA(anything));
    });
  });

  group('new insights', () {
    test('a subcategory up against the same days of last month', () {
      tx('2026-10-10', 1000, sub: diningOut);
      tx('2026-11-10', 3500, sub: diningOut);
      final i = byKey('sub-up:$diningOut')!;
      expect(i['title'], 'Dining Out is up this month');
      expect(i['body'], contains('(Food & Groceries)'));
    });

    test('paying one place much more often', () {
      for (final d in ['03', '06', '09', '12', '15']) {
        tx('2026-11-$d', 300, merchant: 'Swiggy', merchantKey: 'swiggy');
      }
      tx('2026-10-05', 300, merchant: 'Swiggy', merchantKey: 'swiggy');
      final i = byKey('payee-up:swiggy')!;
      expect(i['title'], 'Swiggy: 5 payments this month');
      expect(i['body'], contains('(1 payment)'));
    });

    test('weekends that cost more', () {
      // Eight weeks back from 24 Nov 2026 (a Tuesday): Saturdays and Sundays.
      for (var d = DateTime(2026, 9, 28); d.isBefore(DateTime(2026, 11, 24)); d = d.add(const Duration(days: 1))) {
        final day = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        tx(day, d.weekday >= DateTime.saturday ? 2000 : 200);
      }
      expect(byKey('weekend:2026-11')!['title'], 'Weekends cost more');
    });

    test('regular income that has not arrived', () {
      tx('2026-09-01', 60000, type: 'INCOME', category: salary, merchant: 'Acme', merchantKey: 'acme');
      tx('2026-10-01', 60000, type: 'INCOME', category: salary, merchant: 'Acme', merchantKey: 'acme');
      final i = byKey('income-missing:acme')!;
      expect(i['kind'], 'income');
      expect(i['notify'], isTrue);
      tx('2026-11-02', 60000, type: 'INCOME', category: salary, merchant: 'Acme', merchantKey: 'acme');
      expect(byKey('income-missing'), isNull);
    });

    test('uncategorised payments and cash withdrawals', () {
      for (var i = 0; i < 3; i++) {
        tx('2026-11-1$i', 100, category: null);
      }
      tx('2026-11-05', 5000, type: 'TRANSFER', category: cash);
      expect(byKey('uncat:2026-11')!['title'], '3 payments have no category');
      expect(byKey('cash:2026-11')!['title'], '₹5,000 taken out as cash');
    });

    test('savings cushion in months of spending', () {
      tx('2026-08-10', 20000);
      tx('2026-09-10', 20000);
      tx('2026-10-10', 20000);
      balance(30000);
      final low = byKey('emergency:2026-11')!;
      expect(low['title'], 'Savings cover 1.5 months of spending');
      balance(150000);
      expect(byKey('emergency:2026-11')!['severity'], 'good');
      balance(80000); // 4 months: nothing to say
      expect(byKey('emergency'), isNull);
    });
  });

  test('wealth overview: changes, cushion, debt, best and worst holdings', () async {
    balance(100000);
    tx('2026-09-10', 20000);
    tx('2026-10-10', 20000);
    tx('2026-10-01', 80000, type: 'INCOME', category: salary);
    final assets = LocalAssetsService(db);
    await assets.create({'name': 'Nifty fund', 'asset_class': 'MUTUAL_FUND', 'invested_amount': 100000, 'current_value': 130000});
    await assets.create({'name': 'XYZ Ltd', 'asset_class': 'EQUITY', 'invested_amount': 50000, 'current_value': 40000});
    await assets.create({'name': 'Flat', 'asset_class': 'REAL_ESTATE', 'invested_amount': 0, 'current_value': 500000});
    db.execute("INSERT INTO wealth_snapshots (date, net_worth_minor, assets_minor, liabilities_minor, invested_minor, holdings_minor) VALUES ('2026-10-01', 70000000, 70000000, 0, 0, 0)");

    final o = await LocalInsightsService(db, now: () => now).wealthOverview();
    expect((o['history'] as List).length, 2); // the old reading and today's
    final month = (o['changes'] as Json)['month'] as Json;
    expect(month['from'], 700000.0);
    expect(month['to'], 770000.0);
    expect(o['split'], {'bank': 100000.0, 'ready': 170000.0, 'locked': 500000.0, 'investments': 670000.0});
    expect((o['emergency'] as Json)['months'], 5.0);
    expect([for (final g in (o['gainers'] as List).cast<Json>()) g['name']], ['Nifty fund']);
    expect([for (final g in (o['losers'] as List).cast<Json>()) g['name']], ['XYZ Ltd']);
    expect((o['concentration'] as Json)['name'], 'Flat');
    expect((o['debt'] as Json)['emi_to_income'], 0.0);
  });
}
