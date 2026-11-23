/// Accounts, categories, transactions and budgets stored on the phone.
///
/// Each method is a translation of the matching FastAPI route in
/// backend/app/routers/{accounts,categories,transactions,budgets}.py and
/// returns the same JSON shape, so the screens work unchanged.
library;

import '../services/errors.dart';
import '../services/services.dart';
import 'local_db.dart';
import 'py_round.dart';
import 'validate.dart';

/// The single on-phone owner. Stands in for the backend's `user_id`.
const localUserId = 'local-user';

/// Sources whose messages could be read again (SMS, notifications, shares):
/// deleting such a transaction hides it so it is never captured twice.
const capturedSources = {'SMS', 'UPI_NOTIFICATION', 'SHARE'};

const accountTypes = {'SAVINGS', 'CURRENT', 'CREDIT_CARD', 'WALLET', 'FIXED_DEPOSIT', 'INVESTMENT', 'OTHER'};
const transactionTypes = {'INCOME', 'EXPENSE', 'TRANSFER'};

// ---------------------------------------------------------------------------
// Accounts  (routers/accounts.py)
// ---------------------------------------------------------------------------

class LocalAccountsService implements AccountsService {
  LocalAccountsService(this._db);
  final LocalDb _db;

  @override
  Future<List<Json>> list() async =>
      _db.query('SELECT * FROM accounts ORDER BY created_at ASC, rowid ASC').map(accountOut).toList();

  @override
  Future<void> create(Json account) async {
    final name = readString(account, 'name', required: true)!;
    final type = _accountType(account, required: true)!;
    final balance = readNumber(account, 'balance', ge: 0) ?? 0;
    final now = nowTimestamp();
    _db.execute(
      'INSERT INTO accounts (id, name, account_type, balance_minor, currency, institution, is_active, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        newId(),
        name,
        type,
        toMinor(balance),
        readString(account, 'currency') ?? 'INR',
        readString(account, 'institution'),
        (readBool(account, 'is_active') ?? true) ? 1 : 0,
        now,
        now,
      ],
    );
  }

  @override
  Future<void> update(String id, Json changes) async {
    if (_db.queryOne('SELECT id FROM accounts WHERE id = ?', [id]) == null) {
      throw const NotFoundException('Account not found.');
    }
    // Only the fields AccountUpdate allows; others are ignored like Pydantic does.
    final sets = <String>[];
    final params = <Object?>[];
    void set(String column, Object? value) {
      sets.add('$column = ?');
      params.add(value);
    }

    if (changes.containsKey('name')) set('name', readString(changes, 'name', required: true));
    if (changes.containsKey('account_type')) set('account_type', _accountType(changes, required: true));
    if (changes.containsKey('balance')) set('balance_minor', toMinor(readNumber(changes, 'balance', required: true, ge: 0)!));
    if (changes.containsKey('institution')) set('institution', readString(changes, 'institution'));
    if (changes.containsKey('is_active')) set('is_active', (readBool(changes, 'is_active') ?? true) ? 1 : 0);
    if (sets.isEmpty) return;
    set('updated_at', nowTimestamp());
    _db.execute('UPDATE accounts SET ${sets.join(', ')} WHERE id = ?', [...params, id]);
  }

  /// Deletes the account and every transaction linked to it (as the backend does).
  @override
  Future<void> delete(String id) async {
    _db.transaction(() {
      if (_db.queryOne('SELECT id FROM accounts WHERE id = ?', [id]) == null) {
        throw const NotFoundException('Account not found.');
      }
      if (_db.queryOne('SELECT 1 FROM scheduled_cashflows WHERE account_id = ?', [id]) != null) {
        throw const ServiceException('Recurring items in Bills & recurring use this account. Move or delete them first.');
      }
      _db.execute('DELETE FROM transactions WHERE account_id = ?', [id]);
      _db.execute('DELETE FROM accounts WHERE id = ?', [id]);
    });
  }

  String? _accountType(Json input, {bool required = false}) {
    final raw = readString(input, 'account_type', required: required);
    if (raw == null) return null;
    final type = raw.toUpperCase();
    if (!accountTypes.contains(type)) throw ValidationException('account_type', 'Choose a valid account type');
    return type;
  }
}

/// Row -> AccountOut JSON.
Json accountOut(Row r) => {
      'id': r['id'],
      'user_id': localUserId,
      'name': r['name'],
      'account_type': r['account_type'],
      'balance': fromMinor(r['balance_minor'] as int),
      'currency': r['currency'],
      'institution': r['institution'],
      'is_active': r['is_active'] == 1,
      'last4': r['last4'],
      'created_at': r['created_at'],
      'updated_at': r['updated_at'],
    };

// ---------------------------------------------------------------------------
// Categories  (routers/categories.py)
// ---------------------------------------------------------------------------

class LocalCategoriesService implements CategoriesService {
  LocalCategoriesService(this._db);
  final LocalDb _db;

  /// System and custom categories with their subcategories (duplicates by
  /// name removed), system ones first, then by name.
  @override
  Future<List<Json>> list() async {
    final categories = _db.query('SELECT * FROM categories ORDER BY is_system DESC, name COLLATE NOCASE ASC, name ASC');
    final subs = _db.query('SELECT * FROM subcategories ORDER BY name COLLATE NOCASE ASC, name ASC');
    final byCategory = <String, List<Json>>{};
    final seen = <String>{};
    for (final s in subs) {
      final categoryId = s['category_id'] as String;
      final key = '$categoryId|${(s['name'] as String).trim().toLowerCase()}';
      if (!seen.add(key)) continue;
      byCategory.putIfAbsent(categoryId, () => []).add({
        'id': s['id'],
        'category_id': categoryId,
        'name': s['name'],
        'created_at': s['created_at'],
      });
    }
    return [
      for (final c in categories)
        {
          'id': c['id'],
          'user_id': c['is_system'] == 1 ? null : localUserId,
          'name': c['name'],
          'type': c['type'],
          'icon': c['icon'],
          'color': c['color'],
          'is_system': c['is_system'] == 1,
          'subcategories': byCategory[c['id']] ?? <Json>[],
          'created_at': c['created_at'],
        },
    ];
  }
}

// ---------------------------------------------------------------------------
// Transactions  (routers/transactions.py)
// ---------------------------------------------------------------------------

const txSelect = '''
SELECT t.*, c.name AS category_name, c.icon AS category_icon, c.color AS category_color,
       sc.name AS subcategory_name, a.name AS account_name
FROM transactions t
LEFT JOIN categories c ON t.category_id = c.id
LEFT JOIN subcategories sc ON t.subcategory_id = sc.id
LEFT JOIN accounts a ON t.account_id = a.id
''';

/// Only confirmed transactions are real money movements. Pending ones (from
/// SMS etc.) wait in the review inbox and don't count anywhere yet.
const _confirmed = "t.status = 'CONFIRMED'";

class LocalTransactionsService implements TransactionsService {
  LocalTransactionsService(this._db, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final DateTime Function() _today;

  @override
  Future<List<Json>> list({DateTime? start, DateTime? end, String? type, int? limit}) async {
    final where = [_confirmed];
    final params = <Object?>[];
    if (type != null && type.toUpperCase() != 'ALL') {
      where.add('t.type = ?');
      params.add(type.toUpperCase());
    }
    if (start != null) {
      where.add('t.date >= ?');
      params.add(dateOnly(start));
    }
    if (end != null) {
      where.add('t.date <= ?');
      params.add(dateOnly(end));
    }
    params.add(limit ?? 100);
    return _db
        .query('$txSelect WHERE ${where.join(' AND ')} ORDER BY t.date DESC, t.created_at DESC LIMIT ?', params)
        .map(transactionOut)
        .toList();
  }

  /// Totals for the period (default: the current month), the 90-day monthly
  /// average and the 10 latest transactions.
  @override
  Future<Json> summary({DateTime? start, DateTime? end}) async {
    if (start != null && end != null && dateOnly(start).compareTo(dateOnly(end)) > 0) {
      throw const ServiceException('Start date must be on or before end date.');
    }
    final today = _today();
    final where = [_confirmed];
    final params = <Object?>[];
    if (start != null) {
      where.add('t.date >= ?');
      params.add(dateOnly(start));
    } else {
      where.add('substr(t.date, 1, 7) = ?');
      params.add(dateOnly(today).substring(0, 7));
    }
    if (end != null) {
      where.add('t.date <= ?');
      params.add(dateOnly(end));
    }
    final totals = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN t.type = 'INCOME' THEN t.amount_minor ELSE 0 END), 0) AS income,
             COALESCE(SUM(CASE WHEN t.type = 'EXPENSE' THEN t.amount_minor ELSE 0 END), 0) AS expense
      FROM transactions t WHERE ${where.join(' AND ')}''', params)!;
    final since = dateOnly(DateTime(today.year, today.month, today.day).subtract(const Duration(days: 90)));
    final averages = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN t.type = 'INCOME' THEN t.amount_minor ELSE 0 END), 0) AS income,
             COALESCE(SUM(CASE WHEN t.type = 'EXPENSE' THEN t.amount_minor ELSE 0 END), 0) AS expense
      FROM transactions t WHERE $_confirmed AND t.date >= ?''', [since])!;
    final recent = _db.query('$txSelect WHERE $_confirmed ORDER BY t.date DESC, t.created_at DESC LIMIT 10');

    final income = fromMinor(totals['income'] as int);
    final expense = fromMinor(totals['expense'] as int);
    return {
      'total_income': pyRound(income, 2),
      'total_expense': pyRound(expense, 2),
      'net_savings': pyRound(income - expense, 2),
      'monthly_avg_income': pyRound(fromMinor(averages['income'] as int) / 3.0, 2),
      'monthly_avg_expense': pyRound(fromMinor(averages['expense'] as int) / 3.0, 2),
      'recent_transactions': recent.map(transactionOut).toList(),
    };
  }

  @override
  Future<void> create(Json transaction) async {
    final accountId = readId(transaction, 'account_id', required: true)!;
    final type = _type(transaction, required: true)!;
    final amount = readNumber(transaction, 'amount', required: true, gt: 0)!;
    final date = readDate(transaction, 'date') ?? dateOnly(_today());
    final description = readString(transaction, 'description', required: true)!;
    final categoryId = readId(transaction, 'category_id');
    final subcategoryId = readId(transaction, 'subcategory_id');

    _db.transaction(() {
      _requireAccount(accountId);
      _checkCategory(categoryId, subcategoryId);
      final amountMinor = toMinor(amount);
      _db.execute(
        '''INSERT INTO transactions (id, account_id, category_id, subcategory_id, type, amount_minor, date, description, notes, tags, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [newId(), accountId, categoryId, subcategoryId, type, amountMinor, date, description,
          readString(transaction, 'notes'), readString(transaction, 'tags'), nowTimestamp()],
      );
      _applyToBalance(accountId, type, amountMinor);
    });
  }

  /// Applies the given fields. If the amount, type or account changes, the old
  /// effect on the account balance is reversed and the new one applied.
  @override
  Future<void> update(String id, Json changes) async {
    _db.transaction(() {
      final existing = _db.queryOne('SELECT * FROM transactions WHERE id = ?', [id]);
      if (existing == null) throw const NotFoundException('Transaction not found.');

      final columns = <String, Object?>{};
      if (changes.containsKey('account_id')) columns['account_id'] = readId(changes, 'account_id');
      if (changes.containsKey('category_id')) columns['category_id'] = readId(changes, 'category_id');
      if (changes.containsKey('subcategory_id')) columns['subcategory_id'] = readId(changes, 'subcategory_id');
      if (changes.containsKey('type')) columns['type'] = _type(changes, required: true);
      if (changes.containsKey('amount')) columns['amount_minor'] = toMinor(readNumber(changes, 'amount', required: true, gt: 0)!);
      if (changes.containsKey('date')) columns['date'] = readDate(changes, 'date', required: true);
      if (changes.containsKey('description')) columns['description'] = readString(changes, 'description', required: true);
      if (changes.containsKey('notes')) columns['notes'] = readString(changes, 'notes');
      if (changes.containsKey('tags')) columns['tags'] = readString(changes, 'tags');
      if (columns.isEmpty) return;

      final merged = {...existing, ...columns};
      final newAccountId = merged['account_id'] as String?;
      if (newAccountId == null) throw const ServiceException('Select an account for this transaction.');
      _requireAccount(newAccountId);
      _checkCategory(merged['category_id'] as String?, merged['subcategory_id'] as String?);

      if (existing['status'] == 'CONFIRMED') {
        final oldAccount = existing['account_id'] as String?;
        if (oldAccount != null) _applyToBalance(oldAccount, existing['type'] as String, -(existing['amount_minor'] as int));
        _applyToBalance(newAccountId, merged['type'] as String, merged['amount_minor'] as int);
      }
      _db.execute(
        'UPDATE transactions SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?',
        [...columns.values, id],
      );
    });
  }

  /// Deletes the transaction and reverses its effect on the account balance.
  ///
  /// Transactions captured automatically (SMS etc.) are hidden (IGNORED)
  /// instead of erased, so the same message is never captured again.
  @override
  Future<void> delete(String id) async {
    _db.transaction(() {
      final existing = _db.queryOne('SELECT * FROM transactions WHERE id = ?', [id]);
      if (existing == null) throw const NotFoundException('Transaction not found.');
      final accountId = existing['account_id'] as String?;
      if (accountId != null && existing['status'] == 'CONFIRMED') {
        _applyToBalance(accountId, existing['type'] as String, -(existing['amount_minor'] as int));
      }
      if (capturedSources.contains(existing['source'])) {
        _db.execute("UPDATE transactions SET status = 'IGNORED' WHERE id = ?", [id]);
      } else {
        _db.execute('DELETE FROM transactions WHERE id = ?', [id]);
      }
    });
  }

  void _applyToBalance(String accountId, String type, int amountMinor) => applyToBalance(_db, accountId, type, amountMinor);
  void _requireAccount(String accountId) => requireAccount(_db, accountId);
  void _checkCategory(String? categoryId, String? subcategoryId) => checkCategory(_db, categoryId, subcategoryId);

  String? _type(Json input, {bool required = false}) {
    final raw = readString(input, 'type', required: required);
    if (raw == null) return null;
    final type = raw.toUpperCase();
    if (!transactionTypes.contains(type)) throw ValidationException('type', 'Choose income, expense or transfer');
    return type;
  }
}

/// Income adds to the account balance, expense subtracts; transfers don't
/// change it. Call with a negative amount to reverse.
void applyToBalance(LocalDb db, String accountId, String type, int amountMinor) {
  final delta = switch (type) { 'INCOME' => amountMinor, 'EXPENSE' => -amountMinor, _ => 0 };
  if (delta == 0) return;
  db.execute('UPDATE accounts SET balance_minor = balance_minor + ?, updated_at = ? WHERE id = ?', [delta, nowTimestamp(), accountId]);
}

void requireAccount(LocalDb db, String accountId) {
  if (db.queryOne('SELECT id FROM accounts WHERE id = ?', [accountId]) == null) {
    throw const NotFoundException('Account not found.');
  }
}

void checkCategory(LocalDb db, String? categoryId, String? subcategoryId) {
  if (categoryId != null && db.queryOne('SELECT id FROM categories WHERE id = ?', [categoryId]) == null) {
    throw const NotFoundException('Category not found.');
  }
  if (subcategoryId != null && db.queryOne('SELECT id FROM subcategories WHERE id = ?', [subcategoryId]) == null) {
    throw const NotFoundException('Subcategory not found.');
  }
}

/// Row (with joined names) -> TransactionOut JSON.
Json transactionOut(Row r) => {
      'id': r['id'],
      'user_id': localUserId,
      'account_id': r['account_id'],
      'category_id': r['category_id'],
      'subcategory_id': r['subcategory_id'],
      'type': r['type'],
      'amount': fromMinor(r['amount_minor'] as int),
      'date': r['date'],
      'description': r['description'],
      'notes': r['notes'],
      'tags': r['tags'],
      'category_name': r['category_name'],
      'category_icon': r['category_icon'],
      'category_color': r['category_color'],
      'subcategory_name': r['subcategory_name'],
      'account_name': r['account_name'],
      'scheduled_cashflow_id': r['scheduled_cashflow_id'],
      'scheduled_occurrence_date': r['scheduled_occurrence_date'],
      'source': r['source'],
      'status': r['status'],
      'created_at': r['created_at'],
    };

// ---------------------------------------------------------------------------
// Budgets  (routers/budgets.py)
// ---------------------------------------------------------------------------

class LocalBudgetsService implements BudgetsService {
  LocalBudgetsService(this._db);
  final LocalDb _db;

  /// Every expense category with its limit (if set) and spending that month.
  @override
  Future<List<Json>> forMonth(int month, int year) async {
    _checkMonth(month, year);
    final (from, to) = _monthRange(month, year);
    final rows = _db.query('''
      SELECT c.id AS category_id, c.name AS category_name, c.icon, b.monthly_limit_minor,
             COALESCE((SELECT SUM(t.amount_minor) FROM transactions t
                       WHERE t.category_id = c.id AND t.type = 'EXPENSE' AND $_confirmed
                         AND t.date >= ? AND t.date < ?), 0) AS spent_minor
      FROM categories c
      LEFT JOIN budgets b ON b.category_id = c.id AND b.month = ? AND b.year = ?
      WHERE c.type = 'EXPENSE'
      ORDER BY c.name COLLATE NOCASE ASC, c.name ASC''', [from, to, month, year]);
    return [
      for (final r in rows)
        _budgetOut(r['category_id'] as String, r['category_name'] as String, r['icon'] as String?,
            r['monthly_limit_minor'] == null ? null : fromMinor(r['monthly_limit_minor'] as int), fromMinor(r['spent_minor'] as int)),
    ];
  }

  @override
  Future<void> setLimit({required String categoryId, required double monthlyLimit, required int month, required int year}) async {
    readNumber({'monthly_limit': monthlyLimit}, 'monthly_limit', ge: 0);
    _checkMonth(month, year);
    if (_db.queryOne("SELECT id FROM categories WHERE id = ? AND type = 'EXPENSE'", [categoryId]) == null) {
      throw const NotFoundException('Expense category not found.');
    }
    _db.execute('''
      INSERT INTO budgets (id, category_id, monthly_limit_minor, month, year, created_at) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (category_id, month, year) DO UPDATE SET monthly_limit_minor = excluded.monthly_limit_minor''',
        [newId(), categoryId, toMinor(monthlyLimit), month, year, nowTimestamp()]);
  }

  void _checkMonth(int month, int year) {
    readInt({'month': month}, 'month', ge: 1, le: 12);
    readInt({'year': year}, 'year', ge: 2000, le: 2100);
  }

  (String, String) _monthRange(int month, int year) =>
      (dateOnly(DateTime(year, month, 1)), dateOnly(DateTime(year, month + 1, 1)));

  // Same float arithmetic as the backend (remaining = limit - spent, unrounded).
  Json _budgetOut(String categoryId, String name, String? icon, double? limit, double spent) => {
        'category_id': categoryId,
        'category_name': name,
        'icon': icon,
        'monthly_limit': limit,
        'spent': spent,
        'remaining': limit == null ? null : limit - spent,
        'over_budget': limit != null && spent > limit,
      };
}
