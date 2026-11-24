/// Automatic capture and the review inbox, stored on the phone.
///
/// Flow: message -> [SmsParser] -> duplicate check -> account match ->
/// type & category (learned rule, built-in rule, or keyword guess) ->
/// PENDING transaction. The user then confirms (counts from then on, and
/// teaches the app) or ignores it. A rule with "add automatically" skips
/// the inbox; a rule that says "ignore" hides such messages for good.
library;

import '../capture/categorizer.dart';
import '../capture/rules.dart';
import '../capture/sms_parser.dart';
import '../services/errors.dart';
import '../services/services.dart';
import 'local_db.dart';
import 'local_money.dart';
import 'py_round.dart';
import 'validate.dart';

/// The type and category chosen for a captured payment, and why.
class _Choice {
  const _Choice({
    required this.type,
    this.categoryId,
    this.subcategoryId,
    this.accountId,
    this.ruleId,
    this.source,
    this.label,
    this.autoAdd = false,
    this.ignore = false,
  });

  final String type;
  final String? categoryId, subcategoryId, accountId, ruleId;

  /// RULE, BUILTIN, GUESS or null (nothing suggested).
  final String? source;
  final String? label;
  final bool autoAdd, ignore;
}

const _ruleTypes = {'INCOME', 'EXPENSE', 'TRANSFER', 'IGNORE'};

class LocalCaptureService implements CaptureService {
  LocalCaptureService(this._db);
  final LocalDb _db;

  /// Two captures of the same amount this close together are treated as the
  /// same payment (e.g. bank SMS + UPI app notification), unless their UPI
  /// references or account digits show they are different.
  static const duplicateWindow = Duration(minutes: 10);

  @override
  Future<Json> ingest(List<CapturedMessage> messages) async {
    var duplicates = 0, skipped = 0, autoAdded = 0, autoIgnored = 0;
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
        final direction = directionOf(parsed.type);
        final dedupKey = parsed.upiRef != null
            ? 'upi:${parsed.upiRef}'
            : 'msg:${_fnv64('${m.source}|${m.sender}|${m.receivedAt.millisecondsSinceEpoch}|${m.body}')}';
        final exact = _db.queryOne('SELECT id FROM transactions WHERE dedup_key = ?', [dedupKey])?['id'] as String?;
        final same = exact ?? _nearDuplicate(parsed, direction, amountMinor, at);
        if (same != null) {
          if (exact == null) _enrich(same, parsed, m, dedupKey);
          duplicates++;
          continue;
        }

        final keys = RuleKeys.of(text: m.body, merchant: parsed.merchant);
        final choice = _choose(keys, direction, parsed.type, m.body, parsed.merchant);
        final accountId = _matchAccount(parsed.accountLast4) ?? _activeAccount(choice.accountId);
        final status = choice.ignore ? 'IGNORED' : (choice.autoAdd && accountId != null ? 'CONFIRMED' : 'PENDING');
        final type = choice.ignore ? parsed.type : choice.type;
        final id = newId();
        _db.execute(
          '''INSERT INTO transactions (id, account_id, category_id, subcategory_id, type, amount_minor, date, description, notes,
               source, status, merchant, merchant_key, upi_ref, account_last4, bank, raw_text, dedup_key, occurred_at, created_at,
               direction, vpa, template_key, rule_id, suggest_source, suggest_label, seen_via)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id,
            accountId,
            choice.categoryId,
            choice.subcategoryId,
            type,
            amountMinor,
            dateOnly(at.toLocal()),
            parsed.merchant ?? _fallbackDescription(parsed),
            parsed.note,
            m.source,
            status,
            parsed.merchant,
            keys.party,
            parsed.upiRef,
            parsed.accountLast4,
            parsed.bank,
            m.body,
            dedupKey,
            at.toUtc().toIso8601String(),
            nowTimestamp(),
            direction,
            keys.vpa,
            keys.template,
            choice.ruleId,
            choice.source,
            choice.label,
            _seenEntry(m.source, parsed.bank),
          ],
        );
        if (status == 'CONFIRMED') {
          applyToBalance(_db, accountId!, type, amountMinor, direction);
          _db.execute('UPDATE capture_rules SET hits = hits + 1 WHERE id = ?', [choice.ruleId]);
          autoAdded++;
        } else if (status == 'IGNORED') {
          autoIgnored++;
        } else {
          ids.add(id);
        }
      }
    });
    return {
      'read': messages.length,
      'added': ids.length,
      'auto_added': autoAdded,
      'auto_ignored': autoIgnored,
      'duplicates': duplicates,
      'skipped': skipped,
      'ids': ids,
    };
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
  Future<int> addedThisMonth() async {
    final now = DateTime.now();
    final month = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    return _db.queryOne(
      "SELECT count(*) AS n FROM transactions WHERE status = 'CONFIRMED' AND source IN ('SMS', 'UPI_NOTIFICATION', 'SHARE') AND substr(date, 1, 7) = ?",
      [month],
    )!['n'] as int;
  }

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
      applyToBalance(_db, accountId, row['type'] as String, row['amount_minor'] as int, row['direction'] as String?);
      _learnAccount(accountId, row['account_last4'] as String?);
      _learnFromConfirm(row);
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
        applyToBalance(_db, row['account_id'] as String, row['type'] as String, -(row['amount_minor'] as int), row['direction'] as String?);
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
  // Teaching: "payments like this one are …"
  // -------------------------------------------------------------------------

  @override
  Future<Json> similar(String id) async {
    final row = _pendingRow(id);
    final direction = row['direction'] as String? ?? directionOf(row['type'] as String);
    final key = _keysOf(row).best;
    if (key == null) {
      return {'match_kind': null, 'match_label': null, 'direction': direction, 'other_pending': 0, 'past': 0, 'rule': null};
    }
    final (kind, value) = key;
    int count(String status) => _db.queryOne(
          'SELECT count(*) AS n FROM transactions WHERE ${_column(kind)} = ? AND direction = ? AND status = ? AND id <> ?',
          [value, direction, status, id],
        )!['n'] as int;
    final rule = _findRule(kind, value, direction);
    return {
      'match_kind': kind.code,
      'match_label': _matchLabel(kind, value, row),
      'direction': direction,
      'other_pending': count('PENDING'),
      'past': count('CONFIRMED'),
      'rule': rule == null ? null : _ruleOut(_ruleRow(rule['id'] as String)!),
    };
  }

  @override
  Future<Json> classify(String id, Json choice) async {
    final type = readString(choice, 'type', required: true)!.toUpperCase();
    if (!_ruleTypes.contains(type)) throw ValidationException('type', 'Choose money in, money out, own money or ignore');
    final ignore = type == 'IGNORE';
    final categoryId = ignore ? null : readId(choice, 'category_id');
    final subcategoryId = ignore ? null : readId(choice, 'subcategory_id');
    final remember = readBool(choice, 'remember') ?? true;
    final autoAdd = !ignore && (readBool(choice, 'auto_add') ?? false);
    final applyToPast = readBool(choice, 'apply_to_past') ?? false;

    return _db.transaction(() {
      final row = _pendingRow(id);
      _checkCategoryType(categoryId, subcategoryId, type);
      if (ignore) {
        _db.execute("UPDATE transactions SET status = 'IGNORED', suggest_source = 'USER' WHERE id = ?", [id]);
      } else {
        _db.execute(
          "UPDATE transactions SET type = ?, category_id = ?, subcategory_id = ?, suggest_source = 'USER', suggest_label = NULL WHERE id = ?",
          [type, categoryId, subcategoryId, id],
        );
      }
      var pendingUpdated = 0, pastUpdated = 0;
      final key = _keysOf(row).best;
      if (remember && key != null) {
        final (kind, value) = key;
        final direction = row['direction'] as String? ?? directionOf(row['type'] as String);
        final ruleId = _saveRule(
          kind: kind,
          value: value,
          direction: direction,
          type: type,
          categoryId: categoryId,
          subcategoryId: subcategoryId,
          // Payments without account digits (e.g. app notifications) use the
          // account chosen here; the others are matched by their digits.
          accountId: row['account_last4'] == null ? row['account_id'] as String? : null,
          autoAdd: autoAdd,
          label: _ruleLabel(kind, value, row),
        );
        final match = 'WHERE ${_column(kind)} = ? AND direction = ? AND id <> ?';
        final matchArgs = [value, direction, id];

        // Other waiting payments like it follow right away (not ones the
        // user already changed by hand).
        final others = _db.query("SELECT id FROM transactions $match AND status = 'PENDING' AND COALESCE(suggest_source, '') <> 'USER'", matchArgs);
        for (final o in others) {
          if (ignore) {
            _db.execute("UPDATE transactions SET status = 'IGNORED', rule_id = ? WHERE id = ?", [ruleId, o['id']]);
          } else {
            _db.execute(
              "UPDATE transactions SET type = ?, category_id = ?, subcategory_id = ?, rule_id = ?, suggest_source = 'RULE', suggest_label = NULL WHERE id = ?",
              [type, categoryId, subcategoryId, ruleId, o['id']],
            );
          }
        }
        pendingUpdated = others.length;

        if (applyToPast) {
          final past = _db.query("SELECT * FROM transactions $match AND status = 'CONFIRMED'", matchArgs);
          for (final p in past) {
            final accountId = p['account_id'] as String?;
            if (accountId != null) {
              applyToBalance(_db, accountId, p['type'] as String, -(p['amount_minor'] as int), p['direction'] as String?);
            }
            if (ignore) {
              _db.execute("UPDATE transactions SET status = 'IGNORED', rule_id = ? WHERE id = ?", [ruleId, p['id']]);
            } else {
              _db.execute(
                'UPDATE transactions SET type = ?, category_id = ?, subcategory_id = ?, rule_id = ? WHERE id = ?',
                [type, categoryId, subcategoryId, ruleId, p['id']],
              );
              if (accountId != null) applyToBalance(_db, accountId, type, p['amount_minor'] as int, p['direction'] as String?);
            }
          }
          pastUpdated = past.length;
        }
      }
      return {'pending_updated': pendingUpdated, 'past_updated': pastUpdated};
    });
  }

  @override
  Future<List<Json>> rules() async => _db.query('$_ruleSelect ORDER BY r.updated_at DESC, r.rowid DESC').map(_ruleOut).toList();

  @override
  Future<void> updateRule(String id, Json changes) async {
    _db.transaction(() {
      final rule = _ruleRow(id);
      if (rule == null) throw const NotFoundException('Rule not found.');
      final columns = <String, Object?>{};
      if (changes.containsKey('type')) {
        final type = readString(changes, 'type', required: true)!.toUpperCase();
        if (!_ruleTypes.contains(type)) throw ValidationException('type', 'Choose money in, money out, own money or ignore');
        columns['type'] = type;
        if (type == 'IGNORE') {
          columns['category_id'] = null;
          columns['subcategory_id'] = null;
          columns['auto_add'] = 0;
        }
      }
      if (changes.containsKey('category_id')) {
        columns['category_id'] = readId(changes, 'category_id');
        if (!changes.containsKey('subcategory_id')) columns['subcategory_id'] = null;
      }
      if (changes.containsKey('subcategory_id')) columns['subcategory_id'] = readId(changes, 'subcategory_id');
      if (changes.containsKey('account_id')) {
        final accountId = readId(changes, 'account_id');
        if (accountId != null) requireAccount(_db, accountId);
        columns['account_id'] = accountId;
      }
      if (changes.containsKey('auto_add')) columns['auto_add'] = (readBool(changes, 'auto_add') ?? false) ? 1 : 0;
      if (columns.isEmpty) return;
      final merged = {...rule, ...columns};
      _checkCategoryType(merged['category_id'] as String?, merged['subcategory_id'] as String?, merged['type'] as String);
      if (merged['type'] == 'IGNORE') columns['auto_add'] = 0;
      columns['updated_at'] = nowTimestamp();
      _db.execute('UPDATE capture_rules SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, id]);
    });
  }

  @override
  Future<void> deleteRule(String id) async {
    if (_ruleRow(id) == null) throw const NotFoundException('Rule not found.');
    _db.execute('DELETE FROM capture_rules WHERE id = ?', [id]);
    _db.execute('UPDATE transactions SET rule_id = NULL WHERE rule_id = ?', [id]);
  }

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
      // A category of the old type no longer fits.
      final categoryId = columns.containsKey('category_id') ? columns['category_id'] as String? : row['category_id'] as String?;
      if (categoryId != null && _categoryType(categoryId) != type) {
        columns['category_id'] = null;
        columns['subcategory_id'] = null;
      }
    }
    if (changes.containsKey('direction')) {
      // Fixes a message read the wrong way round (money in vs out).
      final direction = readString(changes, 'direction', required: true)!.toUpperCase();
      if (direction != 'IN' && direction != 'OUT') throw ValidationException('direction', 'Choose money in or money out');
      columns['direction'] = direction;
    }
    if (changes.containsKey('amount')) columns['amount_minor'] = toMinor(readNumber(changes, 'amount', required: true, gt: 0)!);
    if (changes.containsKey('description')) columns['description'] = readString(changes, 'description', required: true);
    if (changes.containsKey('date')) columns['date'] = readDate(changes, 'date', required: true);
    if (changes.containsKey('notes')) columns['notes'] = readString(changes, 'notes');
    if (columns.isEmpty) return;
    if (columns.containsKey('category_id') || columns.containsKey('type')) {
      columns['suggest_source'] = 'USER';
      columns['suggest_label'] = null;
    }
    _db.execute('UPDATE transactions SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, row['id']]);
  }

  /// The type and category Finverse would give a payment with this text,
  /// for other ways of adding payments (statement import). [direction] is
  /// IN or OUT. Returns `type` (INCOME / EXPENSE / TRANSFER / IGNORE),
  /// `category_id`, `subcategory_id`, `rule_id`, `source` (RULE, BUILTIN,
  /// GUESS or null) and `label`.
  Json suggest({required String text, String? merchant, required String direction}) {
    final parsedType = direction == 'IN' ? 'INCOME' : 'EXPENSE';
    final choice = _choose(RuleKeys.of(text: text, merchant: merchant), direction, parsedType, text, merchant);
    return {
      'type': choice.ignore ? 'IGNORE' : choice.type,
      'category_id': choice.categoryId,
      'subcategory_id': choice.subcategoryId,
      'rule_id': choice.ruleId,
      'source': choice.source,
      'label': choice.label,
    };
  }

  /// Learned rule, built-in rule, or keyword guess, in that order.
  _Choice _choose(RuleKeys keys, String direction, String parsedType, String text, String? merchant) {
    for (final (kind, value) in keys.all) {
      final rule = _findRule(kind, value, direction);
      if (rule == null) continue;
      final type = rule['type'] as String;
      return _Choice(
        type: type == 'IGNORE' ? parsedType : type,
        categoryId: rule['category_id'] as String?,
        subcategoryId: rule['subcategory_id'] as String?,
        accountId: rule['account_id'] as String?,
        ruleId: rule['id'] as String,
        source: 'RULE',
        autoAdd: rule['auto_add'] == 1,
        ignore: type == 'IGNORE',
      );
    }
    final builtin = builtinRule(direction: direction, text: text, merchant: merchant);
    if (builtin != null) {
      return _Choice(type: builtin.type, categoryId: builtin.categoryId, source: 'BUILTIN', label: builtin.label);
    }
    final guess = suggestCategory(parsedType, '${merchant ?? ''} $text');
    return _Choice(type: parsedType, categoryId: guess, source: guess == null ? null : 'GUESS');
  }

  Row? _findRule(MatchKind kind, String value, String direction) => _db.queryOne(
        'SELECT * FROM capture_rules WHERE match_kind = ? AND match_value = ? AND direction = ?',
        [kind.code, value, direction],
      );

  /// Creates or updates the rule; returns its id.
  String _saveRule({
    required MatchKind kind,
    required String value,
    required String direction,
    required String type,
    required String? categoryId,
    required String? subcategoryId,
    required String? accountId,
    required bool? autoAdd,
    required String label,
  }) {
    final now = nowTimestamp();
    final existing = _findRule(kind, value, direction);
    if (existing != null) {
      _db.execute(
        '''UPDATE capture_rules SET type = ?, category_id = ?, subcategory_id = ?, account_id = COALESCE(?, account_id),
             auto_add = COALESCE(?, auto_add), hits = hits + 1, updated_at = ? WHERE id = ?''',
        [type, categoryId, subcategoryId, accountId, autoAdd == null ? null : (autoAdd ? 1 : 0), now, existing['id']],
      );
      return existing['id'] as String;
    }
    final id = newId();
    _db.execute(
      '''INSERT INTO capture_rules (id, match_kind, match_value, direction, type, category_id, subcategory_id, account_id, auto_add,
           label, hits, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)''',
      [id, kind.code, value, direction, type, categoryId, subcategoryId, accountId, (autoAdd ?? false) ? 1 : 0, label, now, now],
    );
    return id;
  }

  /// Confirming teaches quietly: the payee's UPI ID or name now means this
  /// type and category. (Rules on message wording are only made when the
  /// user asks, in the "payments like this" sheet, because wording alone is
  /// a weaker match.)
  void _learnFromConfirm(Row row) {
    final categoryId = row['category_id'] as String?;
    final type = row['type'] as String;
    final direction = row['direction'] as String?;
    if (direction == null || (categoryId == null && type != 'TRANSFER')) return;
    final keys = _keysOf(row);
    final used = row['rule_id'] == null ? null : _ruleRow(row['rule_id'] as String);
    final (MatchKind, String)? key = used != null
        ? (MatchKind.fromCode(used['match_kind'] as String), used['match_value'] as String)
        : (keys.vpa != null ? (MatchKind.upi, keys.vpa!) : (keys.party != null ? (MatchKind.party, keys.party!) : null));
    if (key == null) return;
    final (kind, value) = key;
    final ruleId = _saveRule(
      kind: kind,
      value: value,
      direction: direction,
      type: type,
      categoryId: categoryId,
      subcategoryId: row['subcategory_id'] as String?,
      accountId: row['account_last4'] == null ? row['account_id'] as String? : null,
      autoAdd: null,
      label: _ruleLabel(kind, value, row),
    );
    _db.execute(
      '''UPDATE transactions SET type = ?, category_id = ?, subcategory_id = ?, rule_id = ?, suggest_source = 'RULE', suggest_label = NULL
         WHERE status = 'PENDING' AND ${_column(kind)} = ? AND direction = ? AND COALESCE(suggest_source, '') <> 'USER' ''',
      [type, categoryId, row['subcategory_id'], ruleId, value, direction],
    );
  }

  RuleKeys _keysOf(Row row) => RuleKeys(
        vpa: row['vpa'] as String?,
        party: row['merchant_key'] as String?,
        template: row['template_key'] as String?,
      );

  static String _column(MatchKind kind) => switch (kind) {
        MatchKind.upi => 'vpa',
        MatchKind.party => 'merchant_key',
        MatchKind.template => 'template_key',
      };

  String _ruleLabel(MatchKind kind, String value, Row row) => switch (kind) {
        MatchKind.upi => value,
        MatchKind.party => row['merchant'] as String? ?? value,
        MatchKind.template => value.length > 90 ? '${value.substring(0, 90)}…' : value,
      };

  String _matchLabel(MatchKind kind, String value, Row row) => switch (kind) {
        MatchKind.upi => 'UPI ID $value',
        MatchKind.party => 'name “${row['merchant'] ?? value}”',
        MatchKind.template => 'messages worded like this one${row['bank'] == null ? '' : ' from ${row['bank']}'}',
      };

  String? _categoryType(String categoryId) => _db.queryOne('SELECT type FROM categories WHERE id = ?', [categoryId])?['type'] as String?;

  void _checkCategoryType(String? categoryId, String? subcategoryId, String type) {
    checkCategory(_db, categoryId, subcategoryId);
    if (categoryId != null && _categoryType(categoryId) != type) {
      throw ValidationException('category_id', 'This category is for a different kind of payment');
    }
  }

  String? _activeAccount(String? id) =>
      id == null ? null : _db.queryOne('SELECT id FROM accounts WHERE id = ? AND is_active = 1', [id])?['id'] as String?;

  /// Id of an already captured payment that is the same as [parsed], if any.
  String? _nearDuplicate(ParsedSms parsed, String direction, int amountMinor, DateTime at) {
    final from = at.subtract(duplicateWindow).toUtc().toIso8601String();
    final to = at.add(duplicateWindow).toUtc().toIso8601String();
    final rows = _db.query(
      'SELECT id, direction, upi_ref, account_last4 FROM transactions WHERE amount_minor = ? AND occurred_at BETWEEN ? AND ?',
      [amountMinor, from, to],
    );
    for (final r in rows) {
      if (r['direction'] != direction) continue;
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
  /// UPI reference). Fill in what the waiting inbox item is missing, note
  /// where it was seen, and use a rule the new details now match.
  void _enrich(String id, ParsedSms parsed, CapturedMessage m, String dedupKey) {
    final row = _db.queryOne("SELECT * FROM transactions WHERE id = ? AND status = 'PENDING'", [id]);
    if (row == null) return;
    final keys = RuleKeys.of(text: m.body, merchant: parsed.merchant);
    final upgradeKey = (row['dedup_key'] as String?)?.startsWith('msg:') == true && dedupKey.startsWith('upi:');
    final seen = _seenEntry(m.source, parsed.bank);
    final seenVia = row['seen_via'] as String?;
    _db.execute('''
      UPDATE transactions SET
        account_last4 = COALESCE(account_last4, ?),
        bank = CASE WHEN account_last4 IS NULL AND ? IS NOT NULL THEN ? ELSE COALESCE(bank, ?) END,
        upi_ref = COALESCE(upi_ref, ?),
        description = CASE WHEN merchant IS NULL AND ? IS NOT NULL THEN ? ELSE description END,
        merchant = COALESCE(merchant, ?),
        merchant_key = COALESCE(merchant_key, ?),
        vpa = COALESCE(vpa, ?),
        template_key = COALESCE(template_key, ?),
        account_id = COALESCE(account_id, ?),
        seen_via = ?,
        dedup_key = CASE WHEN ? THEN ? ELSE dedup_key END
      WHERE id = ?''', [
      parsed.accountLast4,
      parsed.accountLast4, parsed.bank, parsed.bank,
      parsed.upiRef,
      parsed.merchant, parsed.merchant,
      parsed.merchant,
      keys.party,
      keys.vpa,
      keys.template,
      _matchAccount(parsed.accountLast4),
      seenVia == null ? seen : (seenVia.split('|').contains(seen) ? seenVia : '$seenVia|$seen'),
      upgradeKey ? 1 : 0, dedupKey,
      id,
    ]);

    // Only a guess (or nothing) is replaced; the user's and rules' choices stay.
    final source = row['suggest_source'] as String?;
    if (source != null && source != 'GUESS') return;
    final updated = _db.queryOne('SELECT * FROM transactions WHERE id = ?', [id])!;
    final direction = updated['direction'] as String? ?? directionOf(parsed.type);
    final choice = _choose(_keysOf(updated), direction, directionOf(parsed.type) == 'IN' ? 'INCOME' : 'EXPENSE',
        '${row['raw_text'] ?? ''} ${m.body}', updated['merchant'] as String?);
    if (choice.source != 'RULE' && choice.source != 'BUILTIN') return;
    if (choice.ignore) {
      _db.execute("UPDATE transactions SET status = 'IGNORED', rule_id = ? WHERE id = ?", [choice.ruleId, id]);
      return;
    }
    _db.execute(
      '''UPDATE transactions SET type = ?, category_id = ?, subcategory_id = ?, rule_id = ?, suggest_source = ?, suggest_label = ?,
           account_id = COALESCE(account_id, ?) WHERE id = ?''',
      [choice.type, choice.categoryId, choice.subcategoryId, choice.ruleId, choice.source, choice.label, _activeAccount(choice.accountId), id],
    );
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

  String _fallbackDescription(ParsedSms p) {
    final what = p.type == 'INCOME' ? 'Money received' : (p.isCard ? 'Card payment' : 'Payment');
    return p.bank == null ? what : '$what · ${p.bank}';
  }

  static String _seenEntry(String source, String? bank) => bank == null ? source : '$source:$bank';

  Json _pendingOut(Row r) => {
        ...transactionOut(r),
        'merchant': r['merchant'],
        'bank': r['bank'],
        'account_last4': r['account_last4'],
        'upi_ref': r['upi_ref'],
        'raw_text': r['raw_text'],
        'occurred_at': r['occurred_at'],
        'vpa': r['vpa'],
        'rule_id': r['rule_id'],
        'suggest_source': r['suggest_source'],
        'suggest_label': r['suggest_label'],
        'seen_via': [
          for (final entry in (r['seen_via'] as String? ?? r['source'] as String).split('|'))
            {'source': entry.split(':').first, 'label': entry.contains(':') ? entry.substring(entry.indexOf(':') + 1) : null},
        ],
      };

  static const _ruleSelect = '''
SELECT r.*, c.name AS category_name, sc.name AS subcategory_name, a.name AS account_name
FROM capture_rules r
LEFT JOIN categories c ON c.id = r.category_id
LEFT JOIN subcategories sc ON sc.id = r.subcategory_id
LEFT JOIN accounts a ON a.id = r.account_id''';

  Row? _ruleRow(String id) => _db.queryOne('$_ruleSelect WHERE r.id = ?', [id]);

  Json _ruleOut(Row r) => {
        'id': r['id'],
        'match_kind': r['match_kind'],
        'match_value': r['match_value'],
        'label': r['label'],
        'direction': r['direction'],
        'type': r['type'],
        'category_id': r['category_id'],
        'category_name': r['category_name'],
        'subcategory_id': r['subcategory_id'],
        'subcategory_name': r['subcategory_name'],
        'account_id': r['account_id'],
        'account_name': r['account_name'],
        'auto_add': r['auto_add'] == 1,
        'hits': r['hits'],
        'updated_at': r['updated_at'],
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
