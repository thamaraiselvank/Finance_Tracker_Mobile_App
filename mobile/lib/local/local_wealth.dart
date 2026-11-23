/// Investment holdings (Wealth) and Bills & recurring on the phone,
/// translated from backend/app/routers/{assets,scheduled_cashflows}.py.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/errors.dart';
import '../services/services.dart';
import 'debt_math.dart' show addMonths;
import 'local_db.dart';
import 'local_money.dart' show localUserId, applyToBalance;
import 'py_round.dart';
import 'validate.dart';

double _f(Object? minor) => minor == null ? 0.0 : fromMinor(minor as int);

// ---------------------------------------------------------------------------
// Holdings  (routers/assets.py)
// ---------------------------------------------------------------------------

const assetClasses = {'EQUITY', 'MUTUAL_FUND', 'COMMODITY_GOLD', 'REAL_ESTATE', 'CASH_EQUIVALENT', 'FIXED_INCOME', 'CRYPTO', 'OTHER'};

class LocalAssetsService implements AssetsService {
  LocalAssetsService(this._db, {http.Client? client}) : _client = client ?? http.Client();
  final LocalDb _db;
  final http.Client _client;

  /// Net worth: holdings + active account balances − debts, with totals per
  /// asset class (largest holdings first).
  @override
  Future<Json> summary() async {
    final assets = _db.query('SELECT * FROM assets ORDER BY current_value_minor DESC, rowid ASC').map(assetOut).toList();
    var accountBalance = 0.0;
    for (final a in _db.query('SELECT balance_minor FROM accounts WHERE is_active = 1')) {
      accountBalance += fromMinor(a['balance_minor'] as int);
    }
    var totalInvested = 0.0;
    var assetsCurrent = 0.0;
    for (final a in assets) {
      totalInvested += a['invested_amount'] as double;
      assetsCurrent += a['current_value'] as double;
    }
    final totalCurrent = assetsCurrent + accountBalance;
    final totalPnl = totalCurrent - totalInvested;

    var liabilities = 0.0;
    var emi = 0.0;
    for (final d in _db.query('SELECT current_outstanding_minor, monthly_emi_minor FROM debts')) {
      liabilities += fromMinor(d['current_outstanding_minor'] as int);
      emi += _f(d['monthly_emi_minor']);
    }

    final groups = <String, List<Json>>{};
    for (final a in assets) {
      groups.putIfAbsent(a['asset_class'] as String, () => []).add(a);
    }
    return {
      'total_assets_invested': pyRound(totalInvested, 2),
      'total_assets_current': pyRound(totalCurrent, 2),
      'total_assets_pnl': pyRound(totalPnl, 2),
      'total_assets_pnl_pct': totalInvested > 0 ? pyRound(totalPnl / totalInvested * 100.0, 2) : 0.0,
      'total_liabilities_outstanding': pyRound(liabilities, 2),
      'total_monthly_emi': pyRound(emi, 2),
      'net_worth': pyRound(totalCurrent - liabilities, 2),
      'asset_classes': [
        for (final MapEntry(key: assetClass, value: items) in groups.entries) _classSummary(assetClass, items, totalCurrent),
      ],
    };
  }

  Json _classSummary(String assetClass, List<Json> items, double totalCurrent) {
    var invested = 0.0;
    var current = 0.0;
    for (final i in items) {
      invested += i['invested_amount'] as double;
      current += i['current_value'] as double;
    }
    final pnl = current - invested;
    return {
      'asset_class': assetClass,
      'total_invested': pyRound(invested, 2),
      'total_current_value': pyRound(current, 2),
      'total_pnl': pyRound(pnl, 2),
      'pnl_percentage': invested > 0 ? pyRound(pnl / invested * 100.0, 2) : 0.0,
      'allocation_percentage': totalCurrent > 0 ? pyRound(current / totalCurrent * 100.0, 1) : 0.0,
      'count': items.length,
      'items': items,
    };
  }

  /// Value and invested amount are worked out from quantity × price when
  /// prices are given, as in the backend.
  @override
  Future<void> create(Json asset) async {
    final name = readString(asset, 'name', required: true)!;
    final assetClass = _assetClass(asset);
    final invested = readNumber(asset, 'invested_amount', ge: 0) ?? 0.0;
    final currentValue = readNumber(asset, 'current_value', required: true, ge: 0)!;
    final quantity = readNumber(asset, 'quantity', ge: 0) ?? 1.0;
    final buyPrice = readNumber(asset, 'buy_price', ge: 0) ?? 0.0;
    final currentPrice = readNumber(asset, 'current_price', ge: 0) ?? 0.0;
    final current = currentPrice > 0 && quantity != 0 ? pyRound(quantity * currentPrice, 2) : currentValue;
    final investedAmount = buyPrice > 0 && quantity != 0 && invested == 0 ? pyRound(quantity * buyPrice, 2) : invested;
    final ts = nowTimestamp();
    _db.execute('''
      INSERT INTO assets (id, name, asset_class, sub_type, invested_minor, current_value_minor, quantity, buy_price_minor,
                          current_price_minor, purchase_date, notes, meta_data, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', [
      newId(), name, assetClass, readString(asset, 'sub_type'), toMinor(investedAmount), toMinor(current),
      quantity == 0 ? 1.0 : _q(quantity), toMinor(buyPrice), toMinor(currentPrice), readDate(asset, 'purchase_date'),
      readString(asset, 'notes'), jsonEncode(_meta(asset) ?? const {}), ts, ts,
    ]);
  }

  @override
  Future<void> update(String id, Json changes) async {
    if (_db.queryOne('SELECT id FROM assets WHERE id = ?', [id]) == null) throw const NotFoundException('Asset not found.');
    final columns = <String, Object?>{};
    bool has(String f) => changes.containsKey(f);
    if (has('name')) columns['name'] = readString(changes, 'name', required: true);
    if (has('asset_class')) columns['asset_class'] = _assetClass(changes);
    if (has('sub_type')) columns['sub_type'] = readString(changes, 'sub_type');
    for (final (field, column) in const [
      ('invested_amount', 'invested_minor'),
      ('current_value', 'current_value_minor'),
      ('buy_price', 'buy_price_minor'),
      ('current_price', 'current_price_minor'),
    ]) {
      if (has(field)) columns[column] = toMinor(readNumber(changes, field, required: true, ge: 0)!);
    }
    if (has('quantity')) columns['quantity'] = _q(readNumber(changes, 'quantity', required: true, ge: 0)!);
    if (has('purchase_date')) columns['purchase_date'] = readDate(changes, 'purchase_date');
    if (has('notes')) columns['notes'] = readString(changes, 'notes');
    if (has('meta_data') && changes['meta_data'] != null) columns['meta_data'] = jsonEncode(_meta(changes));
    if (columns.isEmpty) return;
    columns['updated_at'] = nowTimestamp();
    _db.execute('UPDATE assets SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, id]);
  }

  @override
  Future<void> delete(String id) async {
    _db.execute('DELETE FROM assets WHERE id = ?', [id]);
    if (_db.changes == 0) throw const NotFoundException('Asset not found.');
  }

  @override
  Future<void> deleteAll() async => _db.execute('DELETE FROM assets');

  /// Latest market prices for stocks, from Yahoo Finance's public quote
  /// service. Only ticker symbols are sent; nothing about the user.
  @override
  Future<Json> refreshPrices() async {
    final equities = _db.query("SELECT * FROM assets WHERE asset_class = 'EQUITY'");
    if (equities.isEmpty) {
      return {'updated_count': 0, 'failed_count': 0, 'message': 'No equity holdings to refresh.', 'failures': <Json>[]};
    }
    final failures = <Json>[];
    var updated = 0;
    for (final asset in equities) {
      try {
        final price = await _quote(asset);
        final quantity = (asset['quantity'] as num?)?.toDouble() ?? 1.0;
        final qty = quantity == 0 ? 1.0 : quantity;
        _db.execute('UPDATE assets SET current_price_minor = ?, current_value_minor = ?, updated_at = ? WHERE id = ?',
            [toMinor(price), toMinor(pyRound(price * qty, 2)), nowTimestamp(), asset['id']]);
        updated++;
      } on ServiceException catch (e) {
        failures.add({'asset': asset['name'], 'reason': e.message});
      } catch (e) {
        failures.add({'asset': asset['name'], 'reason': 'Unexpected refresh error: $e'});
      }
    }
    return {
      'updated_count': updated,
      'failed_count': failures.length,
      'message': 'Updated prices for $updated of ${equities.length} equity holdings.',
      'failures': failures,
    };
  }

  Future<double> _quote(Row asset) async {
    final meta = _parseMeta(asset['meta_data']);
    final symbol = (meta['symbol'] ?? meta['ticker'] ?? asset['name']).toString().trim().toUpperCase();
    final candidates = symbol.contains('.') ? [symbol] : ['$symbol.NS', '$symbol.BO', symbol];
    var lastError = 'No quote data returned.';
    for (final candidate in candidates) {
      try {
        final uri = Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/${Uri.encodeComponent(candidate)}', {'range': '1d', 'interval': '1m'});
        final response = await _client.get(uri, headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) {
          lastError = 'Yahoo Finance request failed for $candidate: HTTP ${response.statusCode}';
          continue;
        }
        final result = (jsonDecode(response.body)['chart']?['result'] as List?) ?? const [];
        final price = result.isEmpty ? null : result.first['meta']?['regularMarketPrice'];
        if (price is num) return pyRound(price.toDouble(), 2);
        lastError = 'No price found for $candidate.';
      } catch (e) {
        lastError = 'Yahoo Finance request failed for $candidate: $e';
      }
    }
    throw ServiceException(lastError);
  }

  String _assetClass(Json input) {
    final value = readString(input, 'asset_class', required: true)!.toUpperCase();
    if (!assetClasses.contains(value)) throw ValidationException('asset_class', 'Choose a valid asset class');
    return value;
  }

  Map<String, dynamic>? _meta(Json input) {
    final value = input['meta_data'];
    if (value == null) return null;
    if (value is! Map) throw ValidationException('meta_data', 'Input should be a valid dictionary');
    return Map<String, dynamic>.from(value);
  }

  /// NUMERIC(15,4) quantity.
  static double _q(double v) => (v * 10000).round() / 10000;
}

Map<String, dynamic> _parseMeta(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  return {};
}

/// Row -> AssetOut with profit/loss (backend `hydrate_asset`).
Json assetOut(Row a) {
  final invested = fromMinor(a['invested_minor'] as int);
  final current = fromMinor(a['current_value_minor'] as int);
  final pnl = current - invested;
  final quantity = (a['quantity'] as num?)?.toDouble() ?? 0.0;
  return {
    'id': a['id'],
    'user_id': localUserId,
    'name': a['name'],
    'asset_class': a['asset_class'],
    'sub_type': a['sub_type'],
    'invested_amount': invested,
    'current_value': current,
    'quantity': quantity == 0 ? 1.0 : quantity,
    'buy_price': _f(a['buy_price_minor']),
    'current_price': _f(a['current_price_minor']),
    'purchase_date': a['purchase_date'],
    'notes': a['notes'],
    'meta_data': _parseMeta(a['meta_data']),
    'pnl': pyRound(pnl, 2),
    'pnl_percentage': invested > 0 ? pyRound(pnl / invested * 100.0, 2) : 0.0,
    'price_updated_at': null,
    'created_at': a['created_at'],
    'updated_at': a['updated_at'],
  };
}

// ---------------------------------------------------------------------------
// Bills & recurring  (routers/scheduled_cashflows.py)
// ---------------------------------------------------------------------------

const _sourceTypes = {'BILL', 'SUBSCRIPTION', 'EMI', 'INSURANCE_PREMIUM', 'SALARY', 'RENTAL_INCOME', 'DIVIDEND', 'INTEREST', 'OTHER'};
const _incomeSources = {'SALARY', 'RENTAL_INCOME', 'DIVIDEND', 'INTEREST', 'OTHER'};
const _expenseSources = {'BILL', 'SUBSCRIPTION', 'EMI', 'INSURANCE_PREMIUM', 'OTHER'};
const _frequencies = {'WEEKLY', 'MONTHLY', 'QUARTERLY', 'YEARLY'};

/// A schedule's recurrence (pure, so it can be checked against Python).
class Recurrence {
  Recurrence({required this.frequency, required this.intervalCount, required this.start, this.end});
  final String frequency;
  final int intervalCount;
  final DateTime start;
  final DateTime? end;

  factory Recurrence.of(Map<String, dynamic> s) => Recurrence(
        frequency: s['frequency'] as String,
        intervalCount: (s['interval_count'] as num).toInt(),
        start: DateTime.parse(s['start_date'] as String),
        end: s['end_date'] == null ? null : DateTime.parse(s['end_date'] as String),
      );

  int? get _stepMonths => switch (frequency) { 'MONTHLY' => intervalCount, 'QUARTERLY' => 3 * intervalCount, 'YEARLY' => 12 * intervalCount, _ => null };

  DateTime at(int index) => frequency == 'WEEKLY'
      ? DateTime(start.year, start.month, start.day + 7 * index * intervalCount)
      : addMonths(start, index * _stepMonths!);

  /// A safe index to start searching from for occurrences on or after [target].
  int indexOnOrBefore(DateTime target) {
    if (!target.isAfter(start)) return 0;
    if (frequency == 'WEEKLY') {
      final days = DateTime.utc(target.year, target.month, target.day).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
      return _max0(days ~/ (7 * intervalCount) - 1);
    }
    final monthsApart = (target.year - start.year) * 12 + target.month - start.month;
    return _max0(monthsApart ~/ _stepMonths! - 1);
  }

  bool isOccurrence(DateTime date) {
    if (date.isBefore(start)) return false;
    if (end != null && date.isAfter(end!)) return false;
    final index = indexOnOrBefore(date);
    for (var i = index; i < index + 3; i++) {
      final candidate = at(i);
      if (candidate == date) return true;
      if (candidate.isAfter(date)) return false;
    }
    return false;
  }

  static int _max0(int v) => v < 0 ? 0 : v;
}

class LocalSchedulesService implements SchedulesService {
  LocalSchedulesService(this._db, {DateTime Function()? today}) : _today = today ?? DateTime.now;
  final LocalDb _db;
  final DateTime Function() _today;

  DateTime get _todayDate {
    final now = _today();
    return DateTime(now.year, now.month, now.day);
  }

  static const _select = '''
    SELECT s.*, c.name AS category_name, a.name AS account_name, asset.name AS asset_name,
           COALESCE(d.debt_name, p.policy_name) AS linked_record_name
    FROM scheduled_cashflows s
    LEFT JOIN categories c ON c.id = s.category_id
    LEFT JOIN accounts a ON a.id = s.account_id
    LEFT JOIN assets asset ON asset.id = s.asset_id
    LEFT JOIN debts d ON d.id = s.debt_id
    LEFT JOIN insurance_policies p ON p.id = s.insurance_policy_id''';

  @override
  Future<List<Json>> list() async =>
      _db.query('$_select ORDER BY s.is_active DESC, s.start_date, s.description').map(_scheduleOut).toList();

  /// Every due date in the range, marked paid/received (a transaction was
  /// recorded for it), overdue or upcoming.
  @override
  Future<List<Json>> occurrences({required DateTime start, required DateTime end}) async =>
      scheduleOccurrences(start: start, end: end);

  List<Json> scheduleOccurrences({DateTime? start, DateTime? end}) {
    final today = _todayDate;
    final rangeStart = start == null ? DateTime(today.year, today.month) : DateTime(start.year, start.month, start.day);
    final rangeEnd = end == null
        ? addMonths(DateTime(today.year, today.month), 2).subtract(const Duration(days: 1))
        : DateTime(end.year, end.month, end.day);
    if (rangeEnd.isBefore(rangeStart)) throw const ServiceException('End date must be on or after the start date.');
    if (DateTime.utc(rangeEnd.year, rangeEnd.month, rangeEnd.day).difference(DateTime.utc(rangeStart.year, rangeStart.month, rangeStart.day)).inDays > 366) {
      throw const ServiceException('Calendar range cannot exceed 367 days.');
    }

    final schedules = _db.query('$_select WHERE s.is_active = 1 ORDER BY s.description').map(_scheduleOut).toList();
    final actuals = {
      for (final r in _db.query('''
        SELECT scheduled_cashflow_id, scheduled_occurrence_date, id AS transaction_id, date AS actual_date, amount_minor
        FROM transactions WHERE status <> 'IGNORED' AND scheduled_cashflow_id IS NOT NULL
          AND scheduled_occurrence_date BETWEEN ? AND ?''', [dateOnly(rangeStart), dateOnly(rangeEnd)]))
        '${r['scheduled_cashflow_id']}|${r['scheduled_occurrence_date']}': r,
    };
    return buildOccurrences(schedules, actuals, rangeStart, rangeEnd, today);
  }

  @override
  Future<void> create(Json schedule) async {
    final v = _validateFields(schedule);
    _checkRelated(v, requireActiveAccount: true);
    if (v['debt_id'] != null) {
      v['category_id'] ??= _defaultCategory('Loan EMI & Debt Payoff');
    } else if (v['insurance_policy_id'] != null) {
      v['category_id'] ??= _defaultCategory('Insurance Premiums');
    }
    final ts = nowTimestamp();
    _db.execute('''
      INSERT INTO scheduled_cashflows (id, account_id, category_id, asset_id, description, flow_type, source_type, amount_minor,
        amount_is_estimate, frequency, interval_count, start_date, end_date, debt_id, insurance_policy_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', [
      newId(), v['account_id'], v['category_id'], v['asset_id'], v['description'], v['flow_type'], v['source_type'],
      toMinor(v['amount'] as double), (v['amount_is_estimate'] as bool) ? 1 : 0, v['frequency'], v['interval_count'],
      v['start_date'], v['end_date'], v['debt_id'], v['insurance_policy_id'], ts, ts,
    ]);
  }

  /// Applies the given fields after checking the merged schedule is valid.
  @override
  Future<void> update(String id, Json changes) async {
    final current = _db.queryOne('SELECT * FROM scheduled_cashflows WHERE id = ?', [id]);
    if (current == null) throw const NotFoundException('Scheduled cash flow not found.');
    const updatable = {
      'account_id', 'category_id', 'asset_id', 'description', 'flow_type', 'source_type', 'amount', 'amount_is_estimate',
      'frequency', 'interval_count', 'start_date', 'end_date', 'is_active',
    };
    final given = {for (final e in changes.entries) if (updatable.contains(e.key)) e.key: e.value};
    if (given.isEmpty) return;
    final merged = {
      ..._scheduleOut(current),
      ...given,
    };
    final v = _validateFields(merged);
    _checkRelated(v, requireActiveAccount: false);

    final columns = <String, Object?>{};
    for (final key in given.keys) {
      columns[switch (key) { 'amount' => 'amount_minor', _ => key }] = switch (key) {
        'amount' => toMinor(v['amount'] as double),
        'amount_is_estimate' => (v['amount_is_estimate'] as bool) ? 1 : 0,
        'is_active' => (readBool(given, 'is_active') ?? true) ? 1 : 0,
        _ => v[key],
      };
    }
    for (final key in const ['description', 'flow_type', 'source_type', 'frequency']) {
      columns[key] = v[key];
    }
    columns['updated_at'] = nowTimestamp();
    _db.execute('UPDATE scheduled_cashflows SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, id]);
  }

  @override
  Future<void> delete(String id) async {
    _db.execute('DELETE FROM scheduled_cashflows WHERE id = ?', [id]);
    if (_db.changes == 0) throw const NotFoundException('Scheduled cash flow not found.');
  }

  /// Marks one due date as paid / received: records the transaction and
  /// updates the account balance (and the linked policy's payment dates).
  @override
  Future<void> completeOccurrence(String scheduleId, DateTime occurrenceDate, {required double actualAmount, required DateTime actualDate}) async {
    final amount = readNumber({'actual_amount': actualAmount}, 'actual_amount', gt: 0, le: 9999999999999.99)!;
    _db.transaction(() {
      final s = _db.queryOne('SELECT * FROM scheduled_cashflows WHERE id = ?', [scheduleId]);
      if (s == null) throw const NotFoundException('Scheduled cash flow not found.');
      final occurrence = DateTime(occurrenceDate.year, occurrenceDate.month, occurrenceDate.day);
      final recurrence = Recurrence.of(_scheduleOut(s));
      if (!recurrence.isOccurrence(occurrence)) throw const ServiceException('That date is not part of this recurrence schedule.');
      if (_db.queryOne("SELECT id FROM transactions WHERE status <> 'IGNORED' AND scheduled_cashflow_id = ? AND scheduled_occurrence_date = ?",
              [scheduleId, dateOnly(occurrence)]) != null) {
        throw const ServiceException('This occurrence has already been recorded.');
      }
      final paid = DateTime(actualDate.year, actualDate.month, actualDate.day);
      if (paid.isAfter(_todayDate)) throw const ServiceException('A future date cannot be recorded as already paid or received.');

      final amountMinor = toMinor(amount);
      _db.execute('''
        INSERT INTO transactions (id, account_id, category_id, type, amount_minor, date, description, scheduled_cashflow_id,
                                  scheduled_occurrence_date, source, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'SCHEDULE', ?)''', [
        newId(), s['account_id'], s['category_id'], s['flow_type'], amountMinor, dateOnly(paid), s['description'], scheduleId,
        dateOnly(occurrence), nowTimestamp(),
      ]);
      applyToBalance(_db, s['account_id'] as String, s['flow_type'] as String, amountMinor);

      if (s['insurance_policy_id'] != null) {
        var index = recurrence.indexOnOrBefore(occurrence);
        while (recurrence.at(index).isBefore(occurrence)) {
          index++;
        }
        DateTime? next = recurrence.at(index + 1);
        if (recurrence.end != null && next.isAfter(recurrence.end!)) next = null;
        _db.execute("UPDATE insurance_policies SET last_payment_date = ?, next_payment_date = ?, payment_status = 'PAID', updated_at = ? WHERE id = ?",
            [dateOnly(paid), next == null ? null : dateOnly(next), nowTimestamp(), s['insurance_policy_id']]);
      }
    });
  }

  /// ScheduleFields: same rules and messages as the backend model.
  Map<String, dynamic> _validateFields(Json i) {
    final accountId = readId(i, 'account_id', required: true);
    final description = readString(i, 'description', required: true)!;
    if (description.isEmpty) throw ValidationException('description', 'String should have at least 1 character');
    if (description.length > 255) throw ValidationException('description', 'String should have at most 255 characters');
    final flow = readString(i, 'flow_type', required: true)!;
    if (flow != 'INCOME' && flow != 'EXPENSE') throw ValidationException('flow_type', "Input should be 'INCOME' or 'EXPENSE'");
    final source = readString(i, 'source_type') ?? 'OTHER';
    if (!_sourceTypes.contains(source)) throw ValidationException('source_type', 'Choose a valid type');
    final amount = readNumber(i, 'amount', required: true, gt: 0, le: 9999999999999.99)!;
    final estimate = readBool(i, 'amount_is_estimate') ?? false;
    final frequency = readString(i, 'frequency') ?? 'MONTHLY';
    if (!_frequencies.contains(frequency)) throw ValidationException('frequency', 'Choose a valid frequency');
    final interval = readInt(i, 'interval_count', ge: 1, le: 12) ?? 1;
    final start = readDate(i, 'start_date', required: true)!;
    final end = readDate(i, 'end_date');
    final values = {
      'account_id': accountId,
      'category_id': readId(i, 'category_id'),
      'asset_id': readId(i, 'asset_id'),
      'description': description.trim(),
      'flow_type': flow,
      'source_type': source,
      'amount': amount,
      'amount_is_estimate': estimate,
      'frequency': frequency,
      'interval_count': interval,
      'start_date': start,
      'end_date': end,
      'debt_id': readId(i, 'debt_id'),
      'insurance_policy_id': readId(i, 'insurance_policy_id'),
    };
    if (end != null && end.compareTo(start) < 0) throw const ServiceException('End date must be on or after the start date.');
    if (!(flow == 'INCOME' ? _incomeSources : _expenseSources).contains(source)) {
      throw const ServiceException('Choose a source type that matches income or expense.');
    }
    if (values['asset_id'] != null && flow != 'INCOME') throw const ServiceException('An asset can only be linked to expected income.');
    if (values['debt_id'] != null && values['insurance_policy_id'] != null) {
      throw const ServiceException('A schedule can link to only one debt or insurance policy.');
    }
    if (values['debt_id'] != null && (flow != 'EXPENSE' || source != 'EMI')) {
      throw const ServiceException('Debt schedules must be expenses with the EMI type.');
    }
    if (values['insurance_policy_id'] != null && (flow != 'EXPENSE' || source != 'INSURANCE_PREMIUM')) {
      throw const ServiceException('Insurance schedules must be expenses with the insurance premium type.');
    }
    if ((values['description'] as String).isEmpty) throw const ServiceException('Enter a name for this scheduled cash flow.');
    return values;
  }

  void _checkRelated(Map<String, dynamic> v, {required bool requireActiveAccount}) {
    final account = _db.queryOne(
      'SELECT id FROM accounts WHERE id = ?${requireActiveAccount ? ' AND is_active = 1' : ''}',
      [v['account_id']],
    );
    if (account == null) throw const ServiceException('Choose an active account that belongs to your profile.');
    if (v['category_id'] != null && _db.queryOne('SELECT id FROM categories WHERE id = ? AND type = ?', [v['category_id'], v['flow_type']]) == null) {
      throw const ServiceException('Choose a category that matches the cash-flow type.');
    }
    if (v['asset_id'] != null && _db.queryOne('SELECT id FROM assets WHERE id = ?', [v['asset_id']]) == null) {
      throw const ServiceException('The linked asset was not found in your profile.');
    }
    if (v['debt_id'] != null && _db.queryOne('SELECT id FROM debts WHERE id = ?', [v['debt_id']]) == null) {
      throw const ServiceException('The linked debt was not found in your profile.');
    }
    if (v['insurance_policy_id'] != null && _db.queryOne('SELECT id FROM insurance_policies WHERE id = ?', [v['insurance_policy_id']]) == null) {
      throw const ServiceException('The linked insurance policy was not found in your profile.');
    }
  }

  String? _defaultCategory(String name) =>
      _db.queryOne("SELECT id FROM categories WHERE type = 'EXPENSE' AND LOWER(name) = LOWER(?) ORDER BY is_system DESC LIMIT 1", [name])?['id']
          as String?;

  Json _scheduleOut(Row s) => {
        'id': s['id'],
        'user_id': localUserId,
        'account_id': s['account_id'],
        'category_id': s['category_id'],
        'asset_id': s['asset_id'],
        'description': s['description'],
        'flow_type': s['flow_type'],
        'source_type': s['source_type'],
        'amount': fromMinor(s['amount_minor'] as int),
        'amount_is_estimate': s['amount_is_estimate'] == 1,
        'frequency': s['frequency'],
        'interval_count': s['interval_count'],
        'start_date': s['start_date'],
        'end_date': s['end_date'],
        'is_active': s['is_active'] == 1,
        'liability_id': null,
        'debt_id': s['debt_id'],
        'insurance_policy_id': s['insurance_policy_id'],
        'category_name': s['category_name'],
        'account_name': s['account_name'],
        'asset_name': s['asset_name'],
        'linked_record_name': s['linked_record_name'],
        'created_at': s['created_at'],
        'updated_at': s['updated_at'],
      };
}

/// The occurrence calendar for already-loaded schedules (pure; checked
/// against Python in test/parity/schedules.json). [actuals] maps
/// "scheduleId|yyyy-mm-dd" to the recorded transaction.
List<Json> buildOccurrences(List<Json> schedules, Map<String, Row> actuals, DateTime rangeStart, DateTime rangeEnd, DateTime today) {
  final out = <Json>[];
  for (final s in schedules) {
    final r = Recurrence.of(s);
    var index = r.indexOnOrBefore(rangeStart);
    var occurrence = r.at(index);
    while (occurrence.isBefore(rangeStart)) {
      index++;
      occurrence = r.at(index);
    }
    while (!occurrence.isAfter(rangeEnd)) {
      if (r.end != null && occurrence.isAfter(r.end!)) break;
      final actual = actuals['${s['id']}|${dateOnly(occurrence)}'];
      final status = actual != null
          ? (s['flow_type'] == 'INCOME' ? 'received' : 'paid')
          : (occurrence.isBefore(today) ? 'overdue' : 'upcoming');
      out.add({
        'schedule_id': s['id'],
        'description': s['description'],
        'flow_type': s['flow_type'],
        'source_type': s['source_type'],
        'frequency': s['frequency'],
        'interval_count': s['interval_count'],
        'amount': s['amount'],
        'amount_is_estimate': s['amount_is_estimate'],
        'occurrence_date': dateOnly(occurrence),
        'status': status,
        'category_name': s['category_name'],
        'account_name': s['account_name'],
        'asset_name': s['asset_name'],
        'linked_record_name': s['linked_record_name'],
        'liability_id': s['liability_id'],
        'debt_id': s['debt_id'],
        'insurance_policy_id': s['insurance_policy_id'],
        'transaction_id': actual?['transaction_id'],
        'actual_date': actual?['actual_date'],
        'actual_amount': actual == null
            ? null
            : actual['actual_amount'] ?? (actual['amount_minor'] == null ? null : fromMinor(actual['amount_minor'] as int)),
      });
      index++;
      occurrence = r.at(index);
    }
  }
  out.sort((a, b) {
    final byDate = (a['occurrence_date'] as String).compareTo(b['occurrence_date'] as String);
    return byDate != 0 ? byDate : (a['description'] as String).toLowerCase().compareTo((b['description'] as String).toLowerCase());
  });
  return out;
}
