/// Automatic capture and the review inbox, stored on the phone.
///
/// Flow: message -> [SmsParser] -> duplicate check -> account match ->
/// category suggestion -> PENDING transaction. The user then confirms
/// (counts from then on, and teaches the app) or ignores it.
library;

import '../capture/categorizer.dart';
import '../capture/sms_parser.dart';
import '../services/errors.dart';
import '../services/services.dart';
import 'local_db.dart';
import 'local_money.dart';
import 'py_round.dart';
import 'validate.dart';

class LocalCaptureService implements CaptureService {
  LocalCaptureService(this._db);
  final LocalDb _db;

  /// Two captures of the same amount this close together are treated as the
  /// same payment (e.g. bank SMS + UPI app notification), unless their UPI
  /// references or account digits show they are different.
  static const duplicateWindow = Duration(minutes: 10);

  @override
  Future<Json> ingest(List<CapturedMessage> messages) async {
    var duplicates = 0, skipped = 0;
    final ids = <String>[];
    _db.transaction(() {
      for (final m in messages) {
        final parsed = m.parsed ?? SmsParser.parse(m.sender, m.body, fromPaymentApp: m.source != 'SMS');
        if (parsed == null) {
          skipped++;
          continue;
        }
        final amountMinor = toMinor(parsed.amount);
        // When the payment happened: the receipt's own time if it shows one.
        final at = parsed.occurredAt ?? m.receivedAt;
        final dedupKey = parsed.upiRef != null
            ? 'upi:${parsed.upiRef}'
            : 'msg:${_fnv64('${m.source}|${m.sender}|${m.receivedAt.millisecondsSinceEpoch}|${m.body}')}';
        final exact = _db.queryOne('SELECT id FROM transactions WHERE dedup_key = ?', [dedupKey])?['id'] as String?;
        final same = exact ?? _nearDuplicate(parsed, amountMinor, at);
        if (same != null) {
          if (exact == null) _enrich(same, parsed, dedupKey);
          duplicates++;
          continue;
        }

        final key = parsed.merchant == null ? null : merchantKey(parsed.merchant!);
        final (categoryId, subcategoryId) = _suggest(parsed.type, key, '${parsed.merchant ?? ''} ${m.body}');
        final id = newId();
        _db.execute(
          '''INSERT INTO transactions (id, account_id, category_id, subcategory_id, type, amount_minor, date, description, notes,
               source, status, merchant, merchant_key, upi_ref, account_last4, bank, raw_text, dedup_key, occurred_at, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id,
            _matchAccount(parsed.accountLast4),
            categoryId,
            subcategoryId,
            parsed.type,
            amountMinor,
            dateOnly(at.toLocal()),
            parsed.merchant ?? _fallbackDescription(parsed),
            parsed.note,
            m.source,
            parsed.merchant,
            key,
            parsed.upiRef,
            parsed.accountLast4,
            parsed.bank,
            m.body,
            dedupKey,
            at.toUtc().toIso8601String(),
            nowTimestamp(),
          ],
        );
        ids.add(id);
      }
    });
    return {'read': messages.length, 'added': ids.length, 'duplicates': duplicates, 'skipped': skipped, 'ids': ids};
  }

  @override
  Future<List<Json>> pending() async => _db
      .query("$txSelect WHERE t.status = 'PENDING' ORDER BY t.occurred_at DESC, t.created_at DESC")
      .map(_pendingOut)
      .toList();

  @override
  Future<int> pendingCount() async =>
      _db.queryOne("SELECT count(*) AS n FROM transactions WHERE status = 'PENDING'")!['n'] as int;

  @override
  Future<void> updatePending(String id, Json changes) async => _db.transaction(() => _applyEdits(_pendingRow(id), changes));

  @override
  Future<void> confirm(String id, [Json changes = const {}]) async {
    _db.transaction(() {
      _applyEdits(_pendingRow(id), changes);
      final row = _db.queryOne('SELECT * FROM transactions WHERE id = ?', [id])!;
      final accountId = row['account_id'] as String?;
      if (accountId == null) throw const ServiceException('Choose the account for this payment first.');
      requireAccount(_db, accountId);

      _db.execute("UPDATE transactions SET status = 'CONFIRMED' WHERE id = ?", [id]);
      applyToBalance(_db, accountId, row['type'] as String, row['amount_minor'] as int);
      _learnAccount(accountId, row['account_last4'] as String?);
      _learnCategory(row['merchant_key'] as String?, row['category_id'] as String?, row['subcategory_id'] as String?);
    });
  }

  @override
  Future<void> ignore(String id) async {
    _pendingRow(id);
    _db.execute("UPDATE transactions SET status = 'IGNORED' WHERE id = ?", [id]);
  }

  @override
  Future<void> reopen(String id) async {
    _db.transaction(() {
      final row = _db.queryOne('SELECT * FROM transactions WHERE id = ?', [id]);
      if (row == null) throw const NotFoundException('Transaction not found.');
      if (row['status'] == 'PENDING') return;
      if (row['status'] == 'CONFIRMED' && row['account_id'] != null) {
        applyToBalance(_db, row['account_id'] as String, row['type'] as String, -(row['amount_minor'] as int));
      }
      _db.execute("UPDATE transactions SET status = 'PENDING' WHERE id = ?", [id]);
    });
  }

  @override
  Future<String> createAccountFor(String id) async {
    return _db.transaction(() {
      final row = _pendingRow(id);
      final last4 = row['account_last4'] as String?;
      final bank = row['bank'] as String?;
      final raw = (row['raw_text'] as String? ?? '').toLowerCase();
      final accountId = newId();
      final now = nowTimestamp();
      _db.execute(
        '''INSERT INTO accounts (id, name, account_type, balance_minor, currency, institution, is_active, last4, created_at, updated_at)
           VALUES (?, ?, ?, 0, COALESCE((SELECT currency FROM profile LIMIT 1), 'INR'), ?, 1, ?, ?, ?)''',
        [
          accountId,
          [bank ?? 'Bank account', if (last4 != null) '••$last4'].join(' '),
          raw.contains('credit card') ? 'CREDIT_CARD' : 'SAVINGS',
          bank,
          last4,
          now,
          now,
        ],
      );
      _db.execute('UPDATE transactions SET account_id = ? WHERE id = ?', [accountId, id]);
      if (last4 != null) {
        _db.execute(
          "UPDATE transactions SET account_id = ? WHERE status = 'PENDING' AND account_id IS NULL AND account_last4 = ?",
          [accountId, last4],
        );
      }
      return accountId;
    });
  }

  @override
  Future<DateTime?> lastSmsScan() async {
    final value = _db.queryOne("SELECT value FROM app_settings WHERE key = 'last_sms_scan'")?['value'] as String?;
    return value == null ? null : DateTime.tryParse(value);
  }

  @override
  Future<void> setLastSmsScan(DateTime time) async => _db.execute(
        "INSERT INTO app_settings (key, value) VALUES ('last_sms_scan', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        [time.toUtc().toIso8601String()],
      );

  // -------------------------------------------------------------------------

  Row _pendingRow(String id) {
    final row = _db.queryOne('SELECT * FROM transactions WHERE id = ?', [id]);
    if (row == null) throw const NotFoundException('Transaction not found.');
    if (row['status'] != 'PENDING') throw const ServiceException('This payment has already been reviewed.');
    return row;
  }

  void _applyEdits(Row row, Json changes) {
    final columns = <String, Object?>{};
    if (changes.containsKey('account_id')) {
      final accountId = readId(changes, 'account_id');
      if (accountId != null) requireAccount(_db, accountId);
      columns['account_id'] = accountId;
    }
    if (changes.containsKey('category_id')) {
      columns['category_id'] = readId(changes, 'category_id');
      // A new category clears a subcategory that belonged to the old one.
      if (!changes.containsKey('subcategory_id')) columns['subcategory_id'] = null;
    }
    if (changes.containsKey('subcategory_id')) columns['subcategory_id'] = readId(changes, 'subcategory_id');
    checkCategory(_db, columns['category_id'] as String? ?? row['category_id'] as String?, columns['subcategory_id'] as String?);
    if (changes.containsKey('type')) {
      final type = readString(changes, 'type', required: true)!.toUpperCase();
      if (!transactionTypes.contains(type)) throw ValidationException('type', 'Choose income, expense or transfer');
      columns['type'] = type;
    }
    if (changes.containsKey('amount')) columns['amount_minor'] = toMinor(readNumber(changes, 'amount', required: true, gt: 0)!);
    if (changes.containsKey('description')) columns['description'] = readString(changes, 'description', required: true);
    if (changes.containsKey('date')) columns['date'] = readDate(changes, 'date', required: true);
    if (changes.containsKey('notes')) columns['notes'] = readString(changes, 'notes');
    if (columns.isEmpty) return;
    _db.execute('UPDATE transactions SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, row['id']]);
  }

  /// Id of an already captured payment that is the same as [parsed], if any.
  String? _nearDuplicate(ParsedSms parsed, int amountMinor, DateTime at) {
    final from = at.subtract(duplicateWindow).toUtc().toIso8601String();
    final to = at.add(duplicateWindow).toUtc().toIso8601String();
    final rows = _db.query(
      'SELECT id, type, upi_ref, account_last4 FROM transactions WHERE amount_minor = ? AND occurred_at BETWEEN ? AND ?',
      [amountMinor, from, to],
    );
    for (final r in rows) {
      if (r['type'] != parsed.type) continue;
      final ref = r['upi_ref'] as String?;
      if (ref != null && parsed.upiRef != null && ref != parsed.upiRef) continue;
      final last4 = r['account_last4'] as String?;
      if (last4 != null && parsed.accountLast4 != null && last4 != parsed.accountLast4) continue;
      return r['id'] as String;
    }
    return null;
  }

  /// The second sighting of a payment often knows more (a payment-app
  /// notification has the merchant; the bank SMS has the account digits and
  /// UPI reference). Fill in what the waiting inbox item is missing.
  void _enrich(String id, ParsedSms parsed, String dedupKey) {
    final row = _db.queryOne("SELECT * FROM transactions WHERE id = ? AND status = 'PENDING'", [id]);
    if (row == null) return;
    final key = parsed.merchant == null ? null : merchantKey(parsed.merchant!);
    final upgradeKey = (row['dedup_key'] as String?)?.startsWith('msg:') == true && dedupKey.startsWith('upi:');
    _db.execute('''
      UPDATE transactions SET
        account_last4 = COALESCE(account_last4, ?),
        bank = CASE WHEN account_last4 IS NULL AND ? IS NOT NULL THEN ? ELSE COALESCE(bank, ?) END,
        upi_ref = COALESCE(upi_ref, ?),
        description = CASE WHEN merchant IS NULL AND ? IS NOT NULL THEN ? ELSE description END,
        merchant = COALESCE(merchant, ?),
        merchant_key = COALESCE(merchant_key, ?),
        account_id = COALESCE(account_id, ?),
        dedup_key = CASE WHEN ? THEN ? ELSE dedup_key END
      WHERE id = ?''', [
      parsed.accountLast4,
      parsed.accountLast4, parsed.bank, parsed.bank,
      parsed.upiRef,
      parsed.merchant, parsed.merchant,
      parsed.merchant,
      key,
      _matchAccount(parsed.accountLast4),
      upgradeKey ? 1 : 0, dedupKey,
      id,
    ]);
  }

  /// The account with these last digits; or, if the user has exactly one
  /// account and hasn't linked any digits yet, that account.
  String? _matchAccount(String? last4) {
    if (last4 != null) {
      final matches = _db.query('SELECT id FROM accounts WHERE is_active = 1 AND last4 = ?', [last4]);
      if (matches.length == 1) return matches.single['id'] as String;
    }
    final all = _db.query('SELECT id, last4 FROM accounts WHERE is_active = 1');
    if (all.length == 1 && all.single['last4'] == null) return all.single['id'] as String;
    return null;
  }

  (String?, String?) _suggest(String type, String? key, String text) {
    if (key != null && key.isNotEmpty) {
      final rule = _db.queryOne(
        '''SELECT r.category_id, r.subcategory_id FROM merchant_rules r JOIN categories c ON c.id = r.category_id
           WHERE r.merchant_key = ? AND c.type = ?''',
        [key, type],
      );
      if (rule != null) return (rule['category_id'] as String, rule['subcategory_id'] as String?);
    }
    return (suggestCategory(type, text), null);
  }

  /// Remembers the account's last digits, and files other waiting payments
  /// with the same digits under this account.
  void _learnAccount(String accountId, String? last4) {
    if (last4 == null) return;
    final account = _db.queryOne('SELECT last4 FROM accounts WHERE id = ?', [accountId])!;
    final taken = _db.queryOne('SELECT 1 FROM accounts WHERE last4 = ? AND id <> ?', [last4, accountId]) != null;
    if (account['last4'] == null && !taken) {
      _db.execute('UPDATE accounts SET last4 = ? WHERE id = ?', [last4, accountId]);
    }
    if (account['last4'] == null || account['last4'] == last4) {
      _db.execute(
        "UPDATE transactions SET account_id = ? WHERE status = 'PENDING' AND account_id IS NULL AND account_last4 = ?",
        [accountId, last4],
      );
    }
  }

  /// "Swiggy is Food": saved as a rule and applied to waiting payments from
  /// the same merchant.
  void _learnCategory(String? key, String? categoryId, String? subcategoryId) {
    if (key == null || key.isEmpty || categoryId == null) return;
    _db.execute(
      '''INSERT INTO merchant_rules (merchant_key, category_id, subcategory_id, hits, updated_at) VALUES (?, ?, ?, 1, ?)
         ON CONFLICT (merchant_key) DO UPDATE SET category_id = excluded.category_id, subcategory_id = excluded.subcategory_id,
           hits = merchant_rules.hits + 1, updated_at = excluded.updated_at''',
      [key, categoryId, subcategoryId, nowTimestamp()],
    );
    _db.execute(
      '''UPDATE transactions SET category_id = ?, subcategory_id = ?
         WHERE status = 'PENDING' AND merchant_key = ? AND type = (SELECT type FROM categories WHERE id = ?)''',
      [categoryId, subcategoryId, key, categoryId],
    );
  }

  String _fallbackDescription(ParsedSms p) {
    final what = p.type == 'INCOME' ? 'Money received' : (p.isCard ? 'Card payment' : 'Payment');
    return p.bank == null ? what : '$what · ${p.bank}';
  }

  Json _pendingOut(Row r) => {
        ...transactionOut(r),
        'merchant': r['merchant'],
        'bank': r['bank'],
        'account_last4': r['account_last4'],
        'upi_ref': r['upi_ref'],
        'raw_text': r['raw_text'],
        'occurred_at': r['occurred_at'],
      };
}

/// 64-bit FNV-1a hash as hex: a compact fingerprint of a message.
/// (Native 64-bit ints wrap on overflow, which is exactly what FNV needs.)
String _fnv64(String input) {
  var hash = -3750763034362895579; // 0xcbf29ce484222325
  const prime = 1099511628211; // 0x100000001b3
  for (final unit in input.codeUnits) {
    hash = (hash ^ unit) * prime;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}
