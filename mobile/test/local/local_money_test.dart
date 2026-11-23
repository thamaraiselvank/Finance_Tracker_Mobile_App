import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/services/errors.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Behaviour of the on-phone Money services, checked against the rules in
/// backend/app/routers/{accounts,categories,transactions,budgets}.py.
void main() {
  late LocalDb db;
  late LocalAccountsService accounts;
  late LocalTransactionsService transactions;
  late LocalBudgetsService budgets;
  final today = DateTime(2026, 11, 23);

  const food = '00000000-0000-0000-0000-000000000011';
  const salary = '00000000-0000-0000-0000-000000000001';

  setUp(() {
    db = LocalDb.inMemory();
    accounts = LocalAccountsService(db);
    transactions = LocalTransactionsService(db, today: () => today);
    budgets = LocalBudgetsService(db);
  });
  tearDown(() => db.close());

  Future<String> addAccount({String name = 'HDFC Savings', double balance = 10000, bool active = true}) async {
    await accounts.create({'name': name, 'account_type': 'savings', 'balance': balance, 'is_active': active});
    return (await accounts.list()).firstWhere((a) => a['name'] == name)['id'] as String;
  }

  Future<double> balanceOf(String id) async => (await accounts.list()).firstWhere((a) => a['id'] == id)['balance'] as double;

  Future<String> addTx(String accountId, {String type = 'EXPENSE', double amount = 100, String date = '2026-11-10', String? category, String description = 'Test'}) async {
    await transactions.create({
      'account_id': accountId,
      'type': type,
      'amount': amount,
      'date': date,
      'description': description,
      'category_id': category,
    });
    return db.queryOne('SELECT id FROM transactions ORDER BY rowid DESC LIMIT 1')!['id'] as String;
  }

  Future<Object?> errorOf(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      return e;
    }
    return null;
  }

  group('accounts', () {
    test('create returns the backend AccountOut shape', () async {
      await addAccount(balance: 2500.5);
      final a = (await accounts.list()).single;
      expect(a.keys, containsAll(['id', 'user_id', 'name', 'account_type', 'balance', 'currency', 'institution', 'is_active', 'created_at', 'updated_at']));
      expect(a['account_type'], 'SAVINGS'); // upper-cased like the backend
      expect(a['balance'], 2500.5);
      expect(a['currency'], 'INR');
      expect(a['is_active'], true);
    });

    test('accounts are listed oldest first', () async {
      await addAccount(name: 'First');
      await addAccount(name: 'Second');
      expect((await accounts.list()).map((a) => a['name']), ['First', 'Second']);
    });

    test('update changes only the given fields', () async {
      final id = await addAccount();
      await accounts.update(id, {'name': 'Renamed', 'is_active': false});
      final a = (await accounts.list()).single;
      expect(a['name'], 'Renamed');
      expect(a['is_active'], false);
      expect(a['balance'], 10000.0);
    });

    test('negative balance and unknown type are rejected with backend-style messages', () async {
      expect((await errorOf(() => accounts.create({'name': 'X', 'account_type': 'SAVINGS', 'balance': -1}))).toString(),
          'Balance: Input should be greater than or equal to 0');
      expect(await errorOf(() => accounts.create({'name': 'X', 'account_type': 'GOLD'})), isA<ValidationException>());
      expect((await errorOf(() => accounts.create({'account_type': 'SAVINGS'}))).toString(), 'Name: Field required');
    });

    test('deleting an account also deletes its transactions', () async {
      final keep = await addAccount(name: 'Keep');
      final gone = await addAccount(name: 'Gone');
      await addTx(keep);
      await addTx(gone);
      await accounts.delete(gone);
      expect((await accounts.list()).map((a) => a['name']), ['Keep']);
      expect(await transactions.list(), hasLength(1));
      expect((await errorOf(() => accounts.delete(gone))).toString(), 'Account not found.');
    });
  });

  group('transactions and balances', () {
    test('expense lowers, income raises, transfer leaves the balance', () async {
      final id = await addAccount(balance: 1000);
      await addTx(id, type: 'EXPENSE', amount: 250.75);
      expect(await balanceOf(id), 749.25);
      await addTx(id, type: 'income', amount: 1000); // lower case accepted, like the backend
      expect(await balanceOf(id), 1749.25);
      await addTx(id, type: 'TRANSFER', amount: 500);
      expect(await balanceOf(id), 1749.25);
    });

    test('many small amounts do not drift (stored as paise)', () async {
      final id = await addAccount(balance: 0);
      for (var i = 0; i < 100; i++) {
        await addTx(id, type: 'INCOME', amount: 0.1);
      }
      expect(await balanceOf(id), 10.0);
    });

    test('editing the amount, type or account moves the balance effect', () async {
      final a = await addAccount(name: 'A', balance: 1000);
      final b = await addAccount(name: 'B', balance: 1000);
      final tx = await addTx(a, amount: 100);
      expect(await balanceOf(a), 900);

      await transactions.update(tx, {'amount': 300});
      expect(await balanceOf(a), 700);

      await transactions.update(tx, {'type': 'INCOME'});
      expect(await balanceOf(a), 1300);

      await transactions.update(tx, {'account_id': b});
      expect(await balanceOf(a), 1000);
      expect(await balanceOf(b), 1300);

      await transactions.update(tx, {'description': 'Only text changed'});
      expect(await balanceOf(b), 1300);
    });

    test('deleting a transaction reverses its effect', () async {
      final id = await addAccount(balance: 1000);
      final tx = await addTx(id, amount: 400);
      await transactions.delete(tx);
      expect(await balanceOf(id), 1000);
      expect((await errorOf(() => transactions.delete(tx))).toString(), 'Transaction not found.');
    });

    test('validation matches the backend', () async {
      final id = await addAccount();
      expect((await errorOf(() => addTx(id, amount: 0))).toString(), 'Amount: Input should be greater than 0');
      expect((await errorOf(() => addTx('no-such-account'))).toString(), 'Account not found.');
      expect((await errorOf(() => transactions.create({'type': 'EXPENSE', 'amount': 5, 'description': 'x'}))).toString(),
          'Account id: Field required');
      expect((await errorOf(() => addTx(id, date: '2026-13-01'))).toString(), 'Date: Input should be a valid date');
      // Nothing was saved by the failed attempts.
      expect(await balanceOf(id), 10000);
      expect(await transactions.list(), isEmpty);
    });

    test('a missing date defaults to today', () async {
      final id = await addAccount();
      await transactions.create({'account_id': id, 'type': 'EXPENSE', 'amount': 10, 'description': 'Tea'});
      expect((await transactions.list()).single['date'], '2026-11-23');
    });

    test('list returns TransactionOut with joined names, newest first, filtered', () async {
      final id = await addAccount();
      await addTx(id, date: '2026-11-01', category: food, description: 'Older');
      await addTx(id, date: '2026-11-15', type: 'INCOME', category: salary, description: 'Salary');
      await addTx(id, date: '2026-10-31', description: 'Last month');

      final all = await transactions.list();
      expect(all.map((t) => t['description']), ['Salary', 'Older', 'Last month']);
      final older = all[1];
      expect(older['category_name'], 'Food & Groceries');
      expect(older['category_icon'], 'Utensils');
      expect(older['account_name'], 'HDFC Savings');
      expect(older['amount'], 100.0);

      final novemberExpenses = await transactions.list(start: DateTime(2026, 11, 1), end: DateTime(2026, 11, 30), type: 'EXPENSE');
      expect(novemberExpenses.map((t) => t['description']), ['Older']);
      expect(await transactions.list(limit: 1), hasLength(1));
    });

    test('pending (not yet reviewed) transactions are invisible and do not move balances', () async {
      final id = await addAccount(balance: 1000);
      db.execute(
        "INSERT INTO transactions (id, account_id, type, amount_minor, date, description, status, source, created_at) VALUES ('p1', ?, 'EXPENSE', 50000, '2026-11-20', 'From SMS', 'PENDING', 'SMS', ?)",
        [id, nowTimestamp()],
      );
      expect(await transactions.list(), isEmpty);
      expect((await transactions.summary())['total_expense'], 0.0);
      await transactions.delete('p1');
      expect(await balanceOf(id), 1000);
    });
  });

  group('summary', () {
    test('current month totals, 90-day average and recent list', () async {
      final id = await addAccount(balance: 0);
      await addTx(id, type: 'INCOME', amount: 60000, date: '2026-11-01');
      await addTx(id, amount: 1000.10, date: '2026-11-05');
      await addTx(id, amount: 500, date: '2026-10-20'); // previous month, inside 90 days
      await addTx(id, amount: 999, date: '2026-07-01'); // older than 90 days

      final s = await transactions.summary();
      expect(s['total_income'], 60000.0);
      expect(s['total_expense'], 1000.1);
      expect(s['net_savings'], 58999.9);
      expect(s['monthly_avg_income'], 20000.0);
      expect(s['monthly_avg_expense'], 500.03); // (1000.10 + 500) / 3 = 500.0333…
      expect((s['recent_transactions'] as List).length, 4);
    });

    test('an explicit period is used when given', () async {
      final id = await addAccount();
      await addTx(id, amount: 200, date: '2026-10-05');
      await addTx(id, amount: 300, date: '2026-11-05');
      final s = await transactions.summary(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 31));
      expect(s['total_expense'], 200.0);
    });

    test('start after end is refused', () async {
      expect((await errorOf(() => transactions.summary(start: DateTime(2026, 11, 2), end: DateTime(2026, 11, 1)))).toString(),
          'Start date must be on or before end date.');
    });
  });

  group('budgets', () {
    test('every expense category is listed with limit, spent and remaining', () async {
      final id = await addAccount();
      await addTx(id, amount: 1200, date: '2026-11-03', category: food);
      await addTx(id, amount: 300, date: '2026-12-01', category: food); // next month
      await budgets.setLimit(categoryId: food, monthlyLimit: 1000, month: 11, year: 2026);

      final rows = await budgets.forMonth(11, 2026);
      expect(rows, hasLength(12)); // 12 default expense categories
      expect(rows.map((r) => r['category_name']).toList(), [...rows.map((r) => r['category_name'])]..sort((a, b) => (a as String).toLowerCase().compareTo((b as String).toLowerCase())));
      final f = rows.firstWhere((r) => r['category_id'] == food);
      expect(f['monthly_limit'], 1000.0);
      expect(f['spent'], 1200.0);
      expect(f['remaining'], -200.0);
      expect(f['over_budget'], true);
      final other = rows.firstWhere((r) => r['category_id'] != food);
      expect(other['monthly_limit'], isNull);
      expect(other['remaining'], isNull);
      expect(other['over_budget'], false);
    });

    test('setting a limit again replaces it', () async {
      await budgets.setLimit(categoryId: food, monthlyLimit: 1000, month: 11, year: 2026);
      await budgets.setLimit(categoryId: food, monthlyLimit: 2500, month: 11, year: 2026);
      expect((await budgets.forMonth(11, 2026)).firstWhere((r) => r['category_id'] == food)['monthly_limit'], 2500.0);
      expect(db.queryOne('SELECT count(*) AS n FROM budgets')!['n'], 1);
    });

    test('income categories and bad months are refused', () async {
      expect((await errorOf(() => budgets.setLimit(categoryId: salary, monthlyLimit: 1, month: 11, year: 2026))).toString(),
          'Expense category not found.');
      expect((await errorOf(() => budgets.forMonth(13, 2026))).toString(), 'Month: Input should be less than or equal to 12');
      expect((await errorOf(() => budgets.setLimit(categoryId: food, monthlyLimit: -5, month: 1, year: 2026))).toString(),
          'Monthly limit: Input should be greater than or equal to 0');
    });
  });

  group('categories', () {
    test('system categories come with their subcategories, ordered by name', () async {
      final list = await LocalCategoriesService(db).list();
      expect(list, hasLength(17));
      final names = list.map((c) => c['name'] as String).toList();
      expect(names, [...names]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
      final f = list.firstWhere((c) => c['id'] == food);
      expect(f['is_system'], true);
      expect((f['subcategories'] as List).map((s) => s['name']), ['Coffee & Snacks', 'Daily Groceries', 'Dining Out']);
    });
  });

  group('profile (replaces sign-in)', () {
    test('first launch creates an empty profile that needs onboarding', () async {
      final profile = LocalProfileService(db);
      expect(profile.hasAccounts, isFalse);
      expect(await profile.restoreSession(), isTrue);
      final user = await profile.currentUser();
      expect(user['is_onboarded'], false);
      expect(user['monthly_income'], 0.0);
      expect(user['currency'], 'INR');
    });

    test('onboarding answers are saved and validated', () async {
      final profile = LocalProfileService(db);
      final user = await profile.updateProfile({
        'currency': 'INR',
        'monthly_income': 85000,
        'monthly_expense': 40000.5,
        'current_age': 29,
        'target_savings_rate': 35.0,
        'is_onboarded': true,
      });
      expect(user['monthly_income'], 85000.0);
      expect(user['monthly_expense'], 40000.5);
      expect(user['current_age'], 29);
      expect(user['is_onboarded'], true);
      expect((await errorOf(() => profile.updateProfile({'monthly_income': -1}))).toString(),
          'Monthly income: Input should be greater than or equal to 0');
    });
  });

  test('net worth on Home is the total of active account balances', () async {
    await addAccount(name: 'A', balance: 15000);
    await addAccount(name: 'B', balance: 5000.25);
    await addAccount(name: 'Closed', balance: 99999, active: false);
    final s = await LocalAssetsService(db).summary();
    expect(s['net_worth'], 20000.25);
    expect(s['total_assets_current'], 20000.25);
    expect(s['asset_classes'], isEmpty);
  });

  test('areas not moved yet say so clearly instead of using the server', () async {
    final services = localServices(db);
    expect((await errorOf(() => services.imports.commitAssets([]))).toString(), contains('not in the offline version yet'));
    expect(await errorOf(() => services.ai.chat('hi')), isA<NotAvailableYetException>());
    expect(services, isA<Services>());
  });
}
