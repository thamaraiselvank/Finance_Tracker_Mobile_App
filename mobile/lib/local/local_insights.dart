/// Smart insights and alerts, worked out on the phone with plain rules.
///
/// Nothing here uses AI or the internet: each rule is a few SQL queries over
/// the user's own confirmed transactions, budgets, bills, policies and goals.
library;

import 'dart:convert';

import 'package:intl/intl.dart';

import '../core/format.dart';
import '../services/errors.dart';
import '../services/services.dart';
import 'local_db.dart';
import 'local_wealth.dart' show LocalAssetsService, LocalSchedulesService;
import 'py_round.dart';
import 'validate.dart';

class LocalInsightsService implements InsightsService {
  LocalInsightsService(this._db, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final LocalDb _db;
  final DateTime Function() _now;

  static const _dismissedKey = 'insights_dismissed';
  static const _notifiedKey = 'insights_notified';
  static const _settingsKey = 'insights_settings';

  /// Remembered dismissals / notifications older than this are forgotten
  /// (their keys contain a month or a payment id, so they never match again).
  static const _keepDays = 120;

  @override
  Future<List<Json>> list({bool hideAmounts = false}) async {
    await _recordWealth();
    final dismissed = _readMap(_dismissedKey);
    return [
      for (final i in InsightEngine(_db, _now(), hideAmounts: hideAmounts).insights())
        if (!dismissed.containsKey(i['key'])) i,
    ];
  }

  @override
  Future<Json> trends() async {
    await _recordWealth();
    return InsightEngine(_db, _now()).trends();
  }

  @override
  Future<Json> compareMonths({String? monthA, String? monthB, String type = 'EXPENSE', bool sameDays = false}) async =>
      InsightEngine(_db, _now()).compareMonths(monthA: monthA, monthB: monthB, type: type, sameDays: sameDays);

  @override
  Future<Json> wealthOverview() async {
    await _recordWealth();
    final summary = await LocalAssetsService(_db).summary();
    return InsightEngine(_db, _now()).wealthOverview(summary);
  }

  /// Today's net-worth reading (replaced if the app is used again today).
  Future<void> _recordWealth() async {
    final w = await LocalAssetsService(_db).summary();
    var invested = 0.0, holdings = 0.0;
    for (final c in (w['asset_classes'] as List).cast<Json>()) {
      invested += toDouble(c['total_invested']);
      holdings += toDouble(c['total_current_value']);
    }
    _db.execute('''
      INSERT INTO wealth_snapshots (date, net_worth_minor, assets_minor, liabilities_minor, invested_minor, holdings_minor)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (date) DO UPDATE SET net_worth_minor = excluded.net_worth_minor, assets_minor = excluded.assets_minor,
        liabilities_minor = excluded.liabilities_minor, invested_minor = excluded.invested_minor, holdings_minor = excluded.holdings_minor''', [
      dateOnly(_now()),
      toMinor(toDouble(w['net_worth'])),
      toMinor(toDouble(w['total_assets_current'])),
      toMinor(toDouble(w['total_liabilities_outstanding'])),
      toMinor(invested),
      toMinor(holdings),
    ]);
  }

  @override
  Future<void> dismiss(String key) async {
    final dismissed = _readMap(_dismissedKey)..[key] = dateOnly(_now());
    _writeMap(_dismissedKey, dismissed);
  }

  @override
  Future<List<Json>> reminders({bool hideAmounts = false}) async =>
      InsightEngine(_db, _now(), hideAmounts: hideAmounts).reminders();

  @override
  Future<Json> settings() async {
    final saved = _read(_settingsKey);
    final kinds = saved is Map ? saved['kinds'] : null;
    return {
      'enabled': saved is Map ? saved['enabled'] != false : true,
      'kinds': {for (final k in notificationKinds.keys) k: kinds is Map ? kinds[k] != false : true},
    };
  }

  @override
  Future<void> updateSettings(Json changes) async {
    final current = await settings();
    if (changes['enabled'] is bool) current['enabled'] = changes['enabled'];
    final kinds = changes['kinds'];
    if (kinds is Map) {
      for (final e in kinds.entries) {
        if (notificationKinds.containsKey(e.key) && e.value is bool) (current['kinds'] as Map)[e.key] = e.value;
      }
    }
    _write(_settingsKey, current);
  }

  @override
  Future<List<String>> markNotified(List<String> keys) async {
    final sent = _readMap(_notifiedKey);
    final fresh = [for (final k in keys) if (!sent.containsKey(k)) k];
    if (fresh.isEmpty) return fresh;
    final today = dateOnly(_now());
    for (final k in fresh) {
      sent[k] = today;
    }
    _writeMap(_notifiedKey, sent);
    return fresh;
  }

  // -------------------------------------------------------------------------

  Object? _read(String key) {
    final value = _db.queryOne('SELECT value FROM app_settings WHERE key = ?', [key])?['value'] as String?;
    if (value == null) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  void _write(String key, Object value) => _db.execute(
        'INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
        [key, jsonEncode(value)],
      );

  Map<String, String> _readMap(String key) {
    final value = _read(key);
    return value is Map ? {for (final e in value.entries) '${e.key}': '${e.value}'} : {};
  }

  void _writeMap(String key, Map<String, String> map) {
    final cutoff = dateOnly(_now().subtract(const Duration(days: _keepDays)));
    map.removeWhere((_, date) => date.compareTo(cutoff) < 0);
    _write(key, map);
  }
}

/// The rules. [now] is the phone's local time.
class InsightEngine {
  InsightEngine(this._db, this.now, {bool hideAmounts = false})
      : today = DateTime(now.year, now.month, now.day),
        _hide = hideAmounts,
        _money = Money(_db.queryOne('SELECT currency FROM profile LIMIT 1')?['currency'] as String?);

  final LocalDb _db;
  final DateTime now;
  final DateTime today;
  final bool _hide;
  final Money _money;

  /// A "noticeable" amount in minor units: ₹100 for rupees, 2 units of
  /// other currencies. Thresholds below are multiples of it.
  int get _unit => _money.code == 'INR' ? 10000 : 200;

  DateTime get _monthStart => DateTime(today.year, today.month);
  static int _daysIn(DateTime month) => DateTime(month.year, month.month + 1, 0).day;
  static String _ym(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
  static String _monthName(DateTime d) => DateFormat('MMMM').format(d);
  static String _day(DateTime d) => DateFormat('d MMM').format(d);

  String _m(int minor) => _money.format(fromMinor(minor), hidden: _hide);

  static const _severityRank = {'alert': 0, 'warning': 1, 'info': 2, 'good': 3};

  /// Everything worth showing today, most important first.
  List<Json> insights() {
    final out = <Json>[];
    final flagged = <String>{}; // categories already mentioned
    _budgets(out, flagged);
    _spending(out, flagged);
    _comparedWithLastMonth(out, flagged);
    _subcategoryRise(out, flagged);
    _payeeJump(out);
    _weekends(out);
    _incomeMissing(out);
    _uncategorised(out);
    _cash(out);
    _wealthChange(out);
    _emergencyCover(out);
    _unusual(out);
    _duplicates(out);
    _bills(out);
    _renewals(out);
    _goals(out);
    _recurring(out);
    _summary(out);
    final order = {for (var i = 0; i < out.length; i++) out[i]['key']: i};
    out.sort((a, b) {
      final bySeverity = _severityRank[a['severity']]!.compareTo(_severityRank[b['severity']]!);
      return bySeverity != 0 ? bySeverity : order[a['key']]!.compareTo(order[b['key']]!);
    });
    return out;
  }

  Json _insight(String key, String kind, String severity, String title, String body, {required String target, bool notify = false}) => {
        'key': key,
        'kind': kind,
        'severity': severity,
        'title': title,
        'body': body,
        'target': target,
        'notify': notify,
      };

  String _daysLeftText(int days) => days <= 1 ? 'today' : 'the next $days days';

  // ---- Budgets --------------------------------------------------------------

  void _budgets(List<Json> out, Set<String> flagged) {
    final month = _ym(today);
    final rows = _db.query('''
      SELECT c.id, c.name, b.monthly_limit_minor AS limit_minor,
             COALESCE((SELECT SUM(t.amount_minor) FROM transactions t
                       WHERE t.category_id = c.id AND t.type = 'EXPENSE' AND t.status = 'CONFIRMED'
                         AND t.date >= ? AND t.date < ?), 0) AS spent
      FROM budgets b JOIN categories c ON c.id = b.category_id
      WHERE b.month = ? AND b.year = ? AND b.monthly_limit_minor > 0
      ORDER BY c.name''', [dateOnly(_monthStart), dateOnly(DateTime(today.year, today.month + 1)), today.month, today.year]);
    final daysInMonth = _daysIn(_monthStart);
    final daysLeft = daysInMonth - today.day + 1; // including today
    for (final r in rows) {
      final id = r['id'] as String, name = r['name'] as String;
      final limit = r['limit_minor'] as int, spent = r['spent'] as int;
      if (spent >= limit) {
        flagged.add(id);
        out.add(_insight(
          'budget-over:$id:$month',
          'budget',
          'alert',
          spent > limit ? '$name is over budget' : '$name budget used up',
          spent > limit
              ? 'You have spent ${_m(spent)} of your ${_m(limit)} budget, ${_m(spent - limit)} more than planned.'
              : 'You have spent all of your ${_m(limit)} budget with ${daysLeft <= 1 ? 'today still to go' : '$daysLeft days to go'}.',
          target: 'budgets',
          notify: true,
        ));
      } else if (spent * 100 >= limit * 80) {
        flagged.add(id);
        out.add(_insight(
          'budget-80:$id:$month',
          'budget',
          'warning',
          '$name: ${spent * 100 ~/ limit}% of budget used',
          '${_m(limit - spent)} left for ${_daysLeftText(daysLeft)}.',
          target: 'budgets',
          notify: true,
        ));
      } else if (today.day >= 7 && daysLeft > 1) {
        final projected = spent * daysInMonth ~/ today.day;
        if (projected * 10 > limit * 11) {
          flagged.add(id);
          out.add(_insight(
            'budget-pace:$id:$month',
            'budget',
            'info',
            'On pace to overspend on $name',
            'At this pace you will spend about ${_m(projected)} this month, ${_m(projected - limit)} more than your ${_m(limit)} budget.',
            target: 'budgets',
          ));
        }
      }
    }
  }

  // ---- Spending compared with the usual -----------------------------------

  void _spending(List<Json> out, Set<String> flagged) {
    if (today.day < 5) return; // too early in the month to compare
    final first = _db.queryOne("SELECT MIN(date) AS d FROM transactions WHERE status = 'CONFIRMED' AND type = 'EXPENSE'")?['d'] as String?;
    if (first == null) return;
    final firstDate = DateTime.parse(first);
    // Past months that were fully tracked (history starts by their 3rd).
    final months = [
      for (var i = 1; i <= 3; i++) DateTime(today.year, today.month - i),
    ].where((m) => !firstDate.isAfter(DateTime(m.year, m.month, 3))).toList();
    if (months.length < 2) return;

    Map<String?, int> byCategory(DateTime month) {
      final lastDay = today.day < _daysIn(month) ? today.day : _daysIn(month);
      return {
        for (final r in _db.query('''
          SELECT category_id, SUM(amount_minor) AS total FROM transactions
          WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ?
          GROUP BY category_id''', [dateOnly(month), dateOnly(DateTime(month.year, month.month, lastDay))]))
          r['category_id'] as String?: r['total'] as int,
      };
    }

    final current = byCategory(_monthStart);
    final past = [for (final m in months) byCategory(m)];
    int usualFor(String? id) => past.fold<int>(0, (s, m) => s + (m[id] ?? 0)) ~/ past.length;
    final thisTotal = current.values.fold<int>(0, (s, v) => s + v);
    final usualTotal = past.fold<int>(0, (s, m) => s + m.values.fold<int>(0, (a, v) => a + v)) ~/ past.length;
    final month = _ym(today);
    final byTheDay = 'by the ${_ordinal(today.day)}';

    if (usualTotal > 0 && thisTotal * 4 >= usualTotal * 5 && thisTotal - usualTotal >= 10 * _unit) {
      final pct = (thisTotal - usualTotal) * 100 ~/ usualTotal;
      out.add(_insight(
        'spend-high:$month',
        'spending',
        'warning',
        'Spending is higher than usual',
        'You have spent ${_m(thisTotal)} so far this month, ${_m(thisTotal - usualTotal)} ($pct%) more than you usually do $byTheDay.',
        target: 'transactions',
        notify: true,
      ));
    } else if (today.day >= 20 && usualTotal > 0 && thisTotal * 5 <= usualTotal * 4 && usualTotal - thisTotal >= 10 * _unit) {
      out.add(_insight(
        'spend-low:$month',
        'spending',
        'good',
        'Spending less than usual',
        'You have spent ${_m(thisTotal)} so far this month, ${_m(usualTotal - thisTotal)} less than you usually do $byTheDay. Nice work.',
        target: 'transactions',
      ));
    }

    final names = {for (final r in _db.query("SELECT id, name FROM categories WHERE type = 'EXPENSE'")) r['id'] as String: r['name'] as String};
    final minRise = [10 * _unit, usualTotal ~/ 20].reduce((a, b) => a > b ? a : b);
    final rises = <(String, int, int)>[];
    for (final e in current.entries) {
      final id = e.key;
      if (id == null || flagged.contains(id) || !names.containsKey(id)) continue;
      final usual = usualFor(id);
      if (e.value * 2 >= usual * 3 && e.value - usual >= minRise) rises.add((id, e.value, usual));
    }
    rises.sort((a, b) => (b.$2 - b.$3).compareTo(a.$2 - a.$3));
    for (final (id, spent, usual) in rises.take(2)) {
      flagged.add(id);
      out.add(_insight(
        'spend-cat:$id:$month',
        'spending',
        'info',
        '${names[id]} is higher than usual',
        usual == 0
            ? 'You have spent ${_m(spent)} on ${names[id]} this month. Usually there is almost nothing here $byTheDay.'
            : 'You have spent ${_m(spent)} on ${names[id]} this month, against about ${_m(usual)} usually $byTheDay.',
        target: 'transactions',
        notify: true,
      ));
    }
  }

  static String _ordinal(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    return '$n${switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' }}';
  }

  // ---- Unusual and double payments -----------------------------------------

  void _unusual(List<Json> out) {
    final recent = _db.query('''
      SELECT t.id, t.amount_minor, t.date, t.description, t.merchant, t.category_id, c.name AS category_name
      FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
      WHERE t.status = 'CONFIRMED' AND t.type = 'EXPENSE' AND t.scheduled_cashflow_id IS NULL
        AND t.date >= ? AND t.date <= ? AND t.amount_minor >= ?
      ORDER BY t.amount_minor DESC LIMIT 20''', [dateOnly(today.subtract(const Duration(days: 6))), dateOnly(today), 20 * _unit]);
    var found = 0;
    for (final t in recent) {
      final date = DateTime.parse(t['date'] as String);
      final history = [
        for (final r in _db.query('''
          SELECT amount_minor FROM transactions
          WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND id <> ? AND category_id IS ? AND date >= ? AND date < ?''',
            [t['id'], t['category_id'], dateOnly(date.subtract(const Duration(days: 180))), t['date']]))
          r['amount_minor'] as int,
      ]..sort();
      if (history.length < 5) continue;
      final amount = t['amount_minor'] as int;
      final median = history[history.length ~/ 2];
      if (amount < median * 3 || (amount <= history.last && amount < median * 6)) continue;
      final who = (t['merchant'] as String?) ?? (t['description'] as String);
      final category = (t['category_name'] as String?) ?? 'uncategorised';
      out.add(_insight(
        'unusual:${t['id']}',
        'unusual',
        'warning',
        'Unusually large payment',
        '${_m(amount)} for $who on ${_day(date)} is much more than your usual $category payment (about ${_m(median)}). '
            'If you don\'t recognise it, check with your bank.',
        target: 'transactions',
        notify: true,
      ));
      if (++found == 3) break;
    }
  }

  void _duplicates(List<Json> out) {
    final since = dateOnly(today.subtract(const Duration(days: 14)));
    final rows = _db.query('''
      SELECT a.id AS a_id, b.id AS b_id, a.amount_minor, a.date AS a_date, b.date AS b_date,
             COALESCE(a.merchant, a.description) AS name
      FROM transactions a JOIN transactions b
        ON b.amount_minor = a.amount_minor AND a.id < b.id AND b.type = a.type
       AND abs(julianday(a.date) - julianday(b.date)) <= 1
       AND (COALESCE(a.merchant_key, lower(trim(a.description))) = COALESCE(b.merchant_key, lower(trim(b.description)))
            OR (a.source <> b.source AND 'MANUAL' IN (a.source, b.source)))
      WHERE a.status = 'CONFIRMED' AND b.status = 'CONFIRMED' AND a.type = 'EXPENSE'
        AND a.date >= ? AND b.date >= ? AND a.amount_minor >= ?
        AND a.scheduled_cashflow_id IS NULL AND b.scheduled_cashflow_id IS NULL
      ORDER BY a.date DESC LIMIT 3''', [since, since, 2 * _unit]);
    for (final r in rows) {
      final a = DateTime.parse(r['a_date'] as String), b = DateTime.parse(r['b_date'] as String);
      out.add(_insight(
        'dup:${r['a_id']}:${r['b_id']}',
        'unusual',
        'warning',
        'Possible double entry',
        '${_m(r['amount_minor'] as int)} for ${r['name']} is in Money twice (${a == b ? _day(a) : '${_day(a)} and ${_day(b)}'}). '
            'If it was one payment, delete one of them.',
        target: 'transactions',
        notify: true,
      ));
    }
  }

  // ---- Bills, renewals and goals ------------------------------------------

  List<Json> _occurrences(DateTime start, DateTime end) =>
      LocalSchedulesService(_db, today: () => today).scheduleOccurrences(start: start, end: end);

  void _bills(List<Json> out) {
    var upcoming = 0;
    for (final o in _occurrences(today.subtract(const Duration(days: 30)), today.add(const Duration(days: 7)))) {
      if (o['flow_type'] != 'EXPENSE') continue;
      final date = DateTime.parse(o['occurrence_date'] as String);
      final amount = (o['amount_is_estimate'] == true ? 'About ' : '') + _m(toMinor(toDouble(o['amount'])));
      final key = '${o['schedule_id']}:${o['occurrence_date']}';
      if (o['status'] == 'overdue') {
        out.add(_insight(
          'bill-overdue:$key',
          'bill',
          'warning',
          'Overdue: ${o['description']}',
          '$amount was due on ${_day(date)}. Once it is paid, mark it paid in Bills & recurring.',
          target: 'bills',
        ));
      } else if (o['status'] == 'upcoming' && upcoming++ < 5) {
        final days = date.difference(today).inDays;
        out.add(_insight(
          'bill:$key',
          'bill',
          'info',
          switch (days) { 0 => 'Due today: ${o['description']}', 1 => 'Due tomorrow: ${o['description']}', _ => '${o['description']} due in $days days' },
          '$amount on ${DateFormat('EEEE, d MMM').format(date)}.',
          target: 'bills',
        ));
      }
    }
  }

  void _renewals(List<Json> out) {
    final rows = _db.query('''
      SELECT id, policy_name, renewal_date, annual_premium_minor FROM insurance_policies
      WHERE status = 'ACTIVE' AND renewal_date IS NOT NULL AND renewal_date >= ? AND renewal_date <= ?
      ORDER BY renewal_date''', [dateOnly(today.subtract(const Duration(days: 15))), dateOnly(today.add(const Duration(days: 30)))]);
    for (final r in rows) {
      final date = DateTime.parse(r['renewal_date'] as String);
      final days = date.difference(today).inDays;
      final key = '${r['id']}:${r['renewal_date']}';
      final premium = r['annual_premium_minor'] as int;
      if (days < 0) {
        out.add(_insight(
          'renewal-passed:$key',
          'bill',
          'alert',
          'Renewal date passed: ${r['policy_name']}',
          'It was due on ${_day(date)}. Renew it to stay covered, then update the renewal date in Insurance.',
          target: 'insurance',
        ));
      } else {
        out.add(_insight(
          'renewal:$key',
          'bill',
          days <= 7 ? 'warning' : 'info',
          days == 0 ? '${r['policy_name']} renews today' : '${r['policy_name']} renews in $days day${days == 1 ? '' : 's'}',
          'Renewal on ${_day(date)}${premium > 0 ? ', premium about ${_m(premium)}' : ''}.',
          target: 'insurance',
        ));
      }
    }
  }

  void _goals(List<Json> out) {
    final rows = _db.query('''
      SELECT id, goal_name, target_amount_minor, current_amount_minor, target_date FROM goals
      WHERE status = 'ACTIVE' AND current_amount_minor < target_amount_minor AND target_date <= ?
      ORDER BY target_date''', [dateOnly(today.add(const Duration(days: 90)))]);
    for (final r in rows) {
      final date = DateTime.parse(r['target_date'] as String);
      final days = date.difference(today).inDays;
      final target = r['target_amount_minor'] as int, saved = r['current_amount_minor'] as int;
      final pct = target > 0 ? saved * 100 ~/ target : 0;
      out.add(days < 0
          ? _insight(
              'goal-passed:${r['id']}:${r['target_date']}',
              'goal',
              'warning',
              'Goal date passed: ${r['goal_name']}',
              '$pct% saved, ${_m(target - saved)} still to go. Move the date or change the target so your plan stays realistic.',
              target: 'goals',
            )
          : _insight(
              'goal-due:${r['id']}:${_ym(today)}',
              'goal',
              'info',
              '${r['goal_name']}: $days day${days == 1 ? '' : 's'} to go',
              '$pct% saved. ${_m(target - saved)} still needed by ${_day(date)}.',
              target: 'goals',
            ));
    }
  }

  // ---- Payments that look like subscriptions ------------------------------

  void _recurring(List<Json> out) {
    final months = [for (var i = 3; i >= 1; i--) _ym(DateTime(today.year, today.month - i))];
    final rows = _db.query('''
      SELECT COALESCE(merchant_key, vpa, lower(trim(description))) AS k, MAX(COALESCE(merchant, description)) AS name,
             substr(date, 1, 7) AS ym, COUNT(*) AS n, SUM(amount_minor) AS total
      FROM transactions
      WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND scheduled_cashflow_id IS NULL AND date >= ? AND date < ?
      GROUP BY k, ym''', ['${months.first}-01', dateOnly(_monthStart)]);
    final byKey = <String, Map<String, Row>>{};
    for (final r in rows) {
      (byKey[r['k'] as String] ??= {})[r['ym'] as String] = r;
    }
    final scheduled = [
      for (final r in _db.query('SELECT description FROM scheduled_cashflows WHERE is_active = 1')) (r['description'] as String).toLowerCase(),
    ];
    var found = 0;
    for (final e in byKey.entries) {
      final perMonth = [for (final m in months) e.value[m]];
      if (perMonth.any((r) => r == null || r['n'] != 1)) continue;
      final amounts = [for (final r in perMonth) r!['total'] as int]..sort();
      if (amounts.first < _unit ~/ 2 || amounts.last * 100 > amounts.first * 115) continue;
      final name = perMonth.last!['name'] as String;
      final lower = name.toLowerCase();
      if (scheduled.any((s) => s.contains(lower) || lower.contains(s))) continue;
      out.add(_insight(
        'recurring:${e.key}',
        'recurring',
        'info',
        'Looks like a monthly payment: $name',
        'You paid about ${_m(amounts[1])} every month for the last 3 months. '
            'Add it to Bills & recurring to get a reminder before it is due.',
        target: 'bills',
      ));
      if (++found == 3) break;
    }
  }

  // ---- Last month in one line -----------------------------------------------

  ({int income, int expense}) _totals(DateTime month) {
    final r = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN type = 'INCOME' THEN amount_minor END), 0) AS income,
             COALESCE(SUM(CASE WHEN type = 'EXPENSE' THEN amount_minor END), 0) AS expense
      FROM transactions WHERE status = 'CONFIRMED' AND date >= ? AND date < ?''',
        [dateOnly(month), dateOnly(DateTime(month.year, month.month + 1))])!;
    return (income: r['income'] as int, expense: r['expense'] as int);
  }

  void _summary(List<Json> out) {
    if (today.day > 10) return;
    final last = DateTime(today.year, today.month - 1);
    final t = _totals(last);
    if (t.income == 0 && t.expense == 0) return;
    final before = _totals(DateTime(today.year, today.month - 2)).expense;
    final top = _db.queryOne('''
      SELECT c.name, SUM(t.amount_minor) AS total FROM transactions t JOIN categories c ON c.id = t.category_id
      WHERE t.status = 'CONFIRMED' AND t.type = 'EXPENSE' AND t.date >= ? AND t.date < ?
      GROUP BY c.id ORDER BY total DESC LIMIT 1''', [dateOnly(last), dateOnly(_monthStart)]);

    final saved = t.income - t.expense;
    final parts = <String>[
      t.income > 0
          ? 'Income ${_m(t.income)}, spent ${_m(t.expense)}, ${saved >= 0 ? 'saved ${_m(saved)} (${saved * 100 ~/ t.income}%)' : 'spent ${_m(-saved)} more than came in'}.'
          : 'You spent ${_m(t.expense)}.',
      if (top != null) 'Most went on ${top['name']} (${_m(top['total'] as int)}).',
      if (before > 0 && t.expense > 0)
        'Spending was ${((t.expense - before).abs() * 100 / before).round()}% ${t.expense >= before ? 'higher' : 'lower'} than in ${_monthName(DateTime(today.year, today.month - 2))}.',
    ];
    out.add(_insight(
      'summary:${_ym(last)}',
      'summary',
      t.income > 0 && saved < 0 ? 'warning' : (t.income > 0 ? 'good' : 'info'),
      '${_monthName(last)} in short',
      parts.join(' '),
      target: 'transactions',
    ));
  }

  // ---- This month against last month ----------------------------------------

  /// Income and spending between two dates (both included), in minor units.
  ({int income, int expense}) _between(DateTime from, DateTime to) {
    final r = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN type = 'INCOME' THEN amount_minor END), 0) AS income,
             COALESCE(SUM(CASE WHEN type = 'EXPENSE' THEN amount_minor END), 0) AS expense
      FROM transactions WHERE status = 'CONFIRMED' AND date >= ? AND date <= ?''', [dateOnly(from), dateOnly(to)])!;
    return (income: r['income'] as int, expense: r['expense'] as int);
  }

  Map<String?, int> _byCategoryBetween(DateTime from, DateTime to) => {
        for (final r in _db.query('''
          SELECT category_id, SUM(amount_minor) AS total FROM transactions
          WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ?
          GROUP BY category_id''', [dateOnly(from), dateOnly(to)]))
          r['category_id'] as String?: r['total'] as int,
      };

  DateTime get _lastMonth => DateTime(today.year, today.month - 1);

  /// The same day of last month (or its last day, for the 31st...).
  DateTime get _sameDayLastMonth {
    final last = _lastMonth;
    final days = _daysIn(last);
    return DateTime(last.year, last.month, today.day < days ? today.day : days);
  }

  void _comparedWithLastMonth(List<Json> out, Set<String> flagged) {
    if (today.day < 5) return;
    final now = _between(_monthStart, today);
    final before = _between(_lastMonth, _sameDayLastMonth);
    if (before.income == 0 && before.expense == 0) return;
    final month = _ym(today);
    final byThen = 'by ${_day(_sameDayLastMonth)}';

    final savedNow = now.income - now.expense, savedBefore = before.income - before.expense;
    if (now.income > 0 && before.income > 0 && savedNow > 0 && savedNow - savedBefore >= 10 * _unit) {
      out.add(_insight(
        'saved-more:$month',
        'spending',
        'good',
        'Saving more than last month',
        '${_m(savedNow)} saved so far this month, against ${_m(savedBefore)} $byThen.',
        target: 'transactions',
      ));
    }
    final spentLess = before.expense - now.expense;
    if (before.expense > 0 && now.expense * 100 <= before.expense * 85 && spentLess >= 10 * _unit && !out.any((i) => i['key'] == 'spend-high:$month')) {
      out.add(_insight(
        'spent-less:$month',
        'spending',
        'good',
        'Spending down from last month',
        '${_m(now.expense)} spent so far, against ${_m(before.expense)} $byThen. That is ${_m(spentLess)} (${spentLess * 100 ~/ before.expense}%) less.',
        target: 'transactions',
      ));
    }

    final names = {for (final r in _db.query("SELECT id, name FROM categories WHERE type = 'EXPENSE'")) r['id'] as String: r['name'] as String};
    final thisMonth = _byCategoryBetween(_monthStart, today);
    final lastMonth = _byCategoryBetween(_lastMonth, _sameDayLastMonth);
    (String, int, int)? best;
    for (final e in lastMonth.entries) {
      final id = e.key;
      if (id == null || flagged.contains(id) || !names.containsKey(id)) continue;
      final nowSpent = thisMonth[id] ?? 0;
      final drop = e.value - nowSpent;
      if (nowSpent * 10 <= e.value * 6 && drop >= 10 * _unit && (best == null || drop > best.$2 - best.$3)) best = (id, e.value, nowSpent);
    }
    if (best != null) {
      final (id, was, isNow) = best;
      out.add(_insight(
        'cat-down:$id:$month',
        'spending',
        'good',
        'Less on ${names[id]} this month',
        '${_m(isNow)} so far, against ${_m(was)} $byThen. ${_m(was - isNow)} less.',
        target: 'transactions',
      ));
    }
  }

  // ---- Net worth over time --------------------------------------------------

  Row? _snapshot(String sql, [List<Object?> params = const []]) => _db.queryOne('SELECT * FROM wealth_snapshots $sql LIMIT 1', params);

  void _wealthChange(List<Json> out) {
    final now = _snapshot('WHERE date <= ? ORDER BY date DESC', [dateOnly(today)]);
    final then = _snapshot('WHERE date <= ? ORDER BY date DESC', [dateOnly(today.subtract(const Duration(days: 28)))]);
    if (now == null || then == null) return;
    final from = DateTime.parse(then['date'] as String);
    final days = today.difference(from).inDays;
    final a = then['net_worth_minor'] as int, b = now['net_worth_minor'] as int;
    if ((b - a).abs() < 10 * _unit) return;
    out.add(_insight(
      'networth:${_ym(today)}',
      'wealth',
      b > a ? 'good' : 'info',
      b > a ? 'Net worth up ${_m(b - a)}' : 'Net worth down ${_m(a - b)}',
      'From ${_m(a)} on ${_day(from)} to ${_m(b)} today ($days days).',
      target: 'wealth',
    ));
  }

  // ---- More spending patterns ------------------------------------------------

  /// SQL for the key that groups payments to the same payee.
  static const _payeeKey = 'COALESCE(merchant_key, lower(trim(COALESCE(merchant, description))))';

  static const _cashWithdrawal = '00000000-0000-0000-0000-000000000034';

  /// One subcategory that grew a lot against the same days of last month.
  void _subcategoryRise(List<Json> out, Set<String> flagged) {
    if (today.day < 7) return;
    Map<String, int> bySub(DateTime from, DateTime to) => {
          for (final r in _db.query('''
            SELECT subcategory_id, SUM(amount_minor) AS total FROM transactions
            WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND subcategory_id IS NOT NULL AND date >= ? AND date <= ?
            GROUP BY subcategory_id''', [dateOnly(from), dateOnly(to)]))
            r['subcategory_id'] as String: r['total'] as int,
        };
    final now = bySub(_monthStart, today);
    final before = bySub(_lastMonth, _sameDayLastMonth);
    (String, int, int)? best;
    for (final e in now.entries) {
      final was = before[e.key] ?? 0;
      final rise = e.value - was;
      if (was > 0 && e.value * 2 >= was * 3 && rise >= 10 * _unit && (best == null || rise > best.$2 - best.$3)) best = (e.key, e.value, was);
    }
    if (best == null) return;
    final (id, isNow, was) = best;
    final r = _db.queryOne(
        'SELECT s.name, c.id AS cid, c.name AS cname FROM subcategories s JOIN categories c ON c.id = s.category_id WHERE s.id = ?', [id]);
    if (r == null || flagged.contains(r['cid'])) return;
    out.add(_insight(
      'sub-up:$id:${_ym(today)}',
      'spending',
      'info',
      '${r['name']} is up this month',
      '${_m(isNow)} on ${r['name']} (${r['cname']}) so far, against ${_m(was)} by ${_day(_sameDayLastMonth)}. ${_m(isNow - was)} more.',
      target: 'transactions',
    ));
  }

  /// Paying one place much more often than by this day last month.
  void _payeeJump(List<Json> out) {
    if (today.day < 7) return;
    Map<String, Row> byPayee(DateTime from, DateTime to) => {
          for (final r in _db.query('''
            SELECT $_payeeKey AS pkey, MAX(COALESCE(merchant, description)) AS name, COUNT(*) AS n, SUM(amount_minor) AS total
            FROM transactions WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ?
            GROUP BY pkey''', [dateOnly(from), dateOnly(to)]))
            if (r['pkey'] != null) r['pkey'] as String: r,
        };
    final now = byPayee(_monthStart, today);
    final before = byPayee(_lastMonth, _sameDayLastMonth);
    Row? best;
    var bestRise = 0;
    for (final e in now.entries) {
      final n = e.value['n'] as int, total = e.value['total'] as int;
      final wasN = (before[e.key]?['n'] as int?) ?? 0, wasTotal = (before[e.key]?['total'] as int?) ?? 0;
      final rise = total - wasTotal;
      if (n >= 4 && n * 2 >= wasN * 3 && rise >= 5 * _unit && rise > bestRise) {
        best = e.value;
        bestRise = rise;
      }
    }
    if (best == null) return;
    final was = before[best['pkey']];
    out.add(_insight(
      'payee-up:${best['pkey']}:${_ym(today)}',
      'spending',
      'info',
      '${best['name']}: ${best['n']} payments this month',
      was == null
          ? '${_m(best['total'] as int)} so far. By ${_day(_sameDayLastMonth)} last month there were none.'
          : '${_m(best['total'] as int)} so far, against ${_m(was['total'] as int)} (${was['n']} payment${was['n'] == 1 ? '' : 's'}) by ${_day(_sameDayLastMonth)} last month.',
      target: 'transactions',
    ));
  }

  /// Weekends cost clearly more per day than weekdays (last 8 weeks).
  void _weekends(List<Json> out) {
    final first = _db.queryOne("SELECT MIN(date) AS d FROM transactions WHERE status = 'CONFIRMED' AND type = 'EXPENSE'")?['d'] as String?;
    if (first == null) return;
    final firstDate = DateTime.parse(first);
    if (firstDate.isAfter(today.subtract(const Duration(days: 28)))) return;
    final eightWeeks = today.subtract(const Duration(days: 56));
    final start = firstDate.isAfter(eightWeeks) ? firstDate : eightWeeks;
    final to = today.subtract(const Duration(days: 1));
    final r = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN strftime('%w', date) IN ('0', '6') THEN amount_minor END), 0) AS weekend,
             COALESCE(SUM(CASE WHEN strftime('%w', date) NOT IN ('0', '6') THEN amount_minor END), 0) AS weekday
      FROM transactions WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ?''', [dateOnly(start), dateOnly(to)])!;
    var weekendDays = 0, weekdayDays = 0;
    for (var d = start; !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 1)) {
      if (d.weekday >= DateTime.saturday) {
        weekendDays++;
      } else {
        weekdayDays++;
      }
    }
    if (weekendDays < 4 || weekdayDays < 10) return;
    final weekend = r['weekend'] as int;
    final perWeekend = weekend ~/ weekendDays, perWeekday = (r['weekday'] as int) ~/ weekdayDays;
    if (perWeekday <= 0 || perWeekend * 2 < perWeekday * 3 || weekend < 20 * _unit) return;
    out.add(_insight(
      'weekend:${_ym(today)}',
      'spending',
      'info',
      'Weekends cost more',
      'On Saturdays and Sundays you spend about ${_m(perWeekend)} a day, against ${_m(perWeekday)} on other days (last 8 weeks).',
      target: 'transactions',
    ));
  }

  /// Regular income (same payer in each of the last two months) not in yet.
  void _incomeMissing(List<Json> out) {
    final last = _lastMonth, before = DateTime(today.year, today.month - 2);
    final top = _db.queryOne('''
      SELECT $_payeeKey AS pkey, MAX(COALESCE(merchant, description)) AS name, SUM(amount_minor) AS total, MIN(date) AS first_date
      FROM transactions WHERE status = 'CONFIRMED' AND type = 'INCOME' AND date >= ? AND date < ?
      GROUP BY pkey ORDER BY total DESC LIMIT 1''', [dateOnly(last), dateOnly(_monthStart)]);
    if (top == null || top['pkey'] == null || (top['total'] as int) < 50 * _unit) return;
    bool seen(DateTime from, DateTime to) =>
        _db.queryOne('''
          SELECT 1 AS x FROM transactions WHERE status = 'CONFIRMED' AND type = 'INCOME' AND $_payeeKey = ? AND date >= ? AND date <= ? LIMIT 1''',
            [top['pkey'], dateOnly(from), dateOnly(to)]) !=
        null;
    if (!seen(before, DateTime(before.year, before.month + 1, 0))) return; // not regular
    final usualDay = DateTime.parse(top['first_date'] as String).day;
    if (today.day <= usualDay + 3 || seen(_monthStart, today)) return;
    out.add(_insight(
      'income-missing:${top['pkey']}:${_ym(today)}',
      'income',
      'warning',
      'No income from ${top['name']} yet',
      'Last month ${_m(top['total'] as int)} came from ${top['name']} around the ${_ordinal(usualDay)}. Nothing has arrived this month yet. '
          'If it has, check the review inbox.',
      target: 'transactions',
      notify: true,
    ));
  }

  /// Payments this month that are in no category (budgets miss them).
  void _uncategorised(List<Json> out) {
    final r = _db.queryOne('''
      SELECT COUNT(*) AS n, COALESCE(SUM(amount_minor), 0) AS total FROM transactions
      WHERE status = 'CONFIRMED' AND type IN ('EXPENSE', 'INCOME') AND category_id IS NULL AND date >= ? AND date <= ?''',
        [dateOnly(_monthStart), dateOnly(today)])!;
    final n = r['n'] as int;
    if (n < 3) return;
    out.add(_insight(
      'uncat:${_ym(today)}',
      'summary',
      'info',
      '$n payments have no category',
      '${_m(r['total'] as int)} this month is not in any category, so budgets and comparisons leave it out. Tap to sort them.',
      target: 'transactions',
    ));
  }

  /// Cash taken out this month: what is paid in cash is not tracked.
  void _cash(List<Json> out) {
    final total = _db.queryOne('''
      SELECT COALESCE(SUM(amount_minor), 0) AS total FROM transactions
      WHERE status = 'CONFIRMED' AND type = 'TRANSFER' AND category_id = ? AND date >= ? AND date <= ?''',
        [_cashWithdrawal, dateOnly(_monthStart), dateOnly(today)])!['total'] as int;
    if (total < 20 * _unit) return;
    out.add(_insight(
      'cash:${_ym(today)}',
      'spending',
      'info',
      '${_m(total)} taken out as cash',
      'Cash payments are not tracked automatically. Add the big ones in Money so your spending stays right.',
      target: 'transactions',
    ));
  }

  /// Bank balances and cash-like savings, in months of usual spending (the
  /// average of the last 3 full months that had spending; needs 2).
  ({int cash, int monthly, double months})? _cover() {
    final bank = _db.queryOne('''
      SELECT COALESCE(SUM(CASE WHEN balance_minor > 0 THEN balance_minor END), 0) AS total FROM accounts
      WHERE is_active = 1 AND account_type IN ('SAVINGS', 'CURRENT', 'WALLET')''')!['total'] as int;
    final liquid =
        _db.queryOne("SELECT COALESCE(SUM(current_value_minor), 0) AS total FROM assets WHERE asset_class = 'CASH_EQUIVALENT'")!['total'] as int;
    final spends = [
      for (var i = 1; i <= 3; i++) _totals(DateTime(today.year, today.month - i)).expense,
    ].where((e) => e > 0).toList();
    if (spends.length < 2) return null;
    final monthly = spends.reduce((a, b) => a + b) ~/ spends.length;
    if (monthly <= 0) return null;
    final cash = bank + liquid;
    return (cash: cash, monthly: monthly, months: cash / monthly);
  }

  void _emergencyCover(List<Json> out) {
    final c = _cover();
    if (c == null) return;
    final months = c.months.toStringAsFixed(c.months < 10 ? 1 : 0);
    if (c.months < 3) {
      out.add(_insight(
        'emergency:${_ym(today)}',
        'wealth',
        c.months < 1 ? 'warning' : 'info',
        'Savings cover $months months of spending',
        'Your bank balances and cash-like savings (${_m(c.cash)}) would last about $months months at your usual ${_m(c.monthly)} a month. '
            'A cushion of 3 to 6 months is safer.',
        target: 'wealth',
      ));
    } else if (c.months >= 6) {
      out.add(_insight(
        'emergency:${_ym(today)}',
        'wealth',
        'good',
        'A strong safety cushion',
        'Your bank balances and cash-like savings (${_m(c.cash)}) would cover about $months months of spending. '
            'Money beyond 6 months could be put to work in investments.',
        target: 'wealth',
      ));
    }
  }

  // ---- Numbers for the comparison screens ----------------------------------

  static double _amount(int minor) => fromMinor(minor);

  Json _totalsJson(({int income, int expense}) t) =>
      {'income': _amount(t.income), 'expense': _amount(t.expense), 'saved': _amount(t.income - t.expense)};

  Json trends() {
    final lastMonth = _lastMonth;
    final lastMonthEnd = DateTime(lastMonth.year, lastMonth.month + 1, 0);

    // Last 6 months, oldest first; this month is "so far".
    final months = <Json>[];
    for (var i = 5; i >= 0; i--) {
      final m = DateTime(today.year, today.month - i);
      final t = _between(m, i == 0 ? today : DateTime(m.year, m.month + 1, 0));
      months.add({'month': _ym(m), 'label': DateFormat('MMM').format(m), 'partial': i == 0, ..._totalsJson(t)});
    }

    // Categories: this month so far, last month by the same day, all of last month.
    final thisMonth = _byCategoryBetween(_monthStart, today);
    final sameDays = _byCategoryBetween(lastMonth, _sameDayLastMonth);
    final fullLast = _byCategoryBetween(lastMonth, lastMonthEnd);
    final cats = {
      for (final r in _db.query("SELECT id, name, color FROM categories WHERE type = 'EXPENSE'")) r['id'] as String: r,
    };
    final categories = [
      for (final id in {...thisMonth.keys, ...fullLast.keys})
        <String, dynamic>{
          'id': id,
          'name': id == null ? 'Uncategorised' : (cats[id]?['name'] ?? 'Other'),
          'color': id == null ? null : cats[id]?['color'],
          'this': _amount(thisMonth[id] ?? 0),
          'last_same': _amount(sameDays[id] ?? 0),
          'last_full': _amount(fullLast[id] ?? 0),
        },
    ]..sort((a, b) {
        final byThis = (b['this'] as double).compareTo(a['this'] as double);
        return byThis != 0 ? byThis : (b['last_full'] as double).compareTo(a['last_full'] as double);
      });

    // Since the first record.
    final first = _db.queryOne("SELECT MIN(date) AS d FROM transactions WHERE status = 'CONFIRMED'")?['d'] as String?;
    Json? since;
    if (first != null) {
      final from = DateTime.parse(first);
      final t = _between(from, today);
      final monthsCount = (today.year - from.year) * 12 + today.month - from.month + 1;
      since = {
        'first_date': first,
        'days': today.difference(from).inDays + 1,
        'months': monthsCount,
        ..._totalsJson(t),
        'avg_month_expense': _amount(t.expense ~/ monthsCount),
        'avg_month_income': _amount(t.income ~/ monthsCount),
      };
    }

    // Net worth: first reading, about a month ago, and now.
    Json? reading(Row? r) => r == null
        ? null
        : {
            'date': r['date'],
            'net_worth': _amount(r['net_worth_minor'] as int),
            'assets': _amount(r['assets_minor'] as int),
            'liabilities': _amount(r['liabilities_minor'] as int),
            'invested': _amount(r['invested_minor'] as int),
            'holdings': _amount(r['holdings_minor'] as int),
          };

    return {
      'today': dateOnly(today),
      'this_label': _monthName(today),
      'last_label': _monthName(lastMonth),
      'same_day_last_month': dateOnly(_sameDayLastMonth),
      'compare': {
        'this': _totalsJson(_between(_monthStart, today)),
        'last': _totalsJson(_between(lastMonth, _sameDayLastMonth)),
        'last_full': _totalsJson(_between(lastMonth, lastMonthEnd)),
      },
      'months': months,
      'categories': categories,
      'since': since,
      'wealth': {
        'first': reading(_snapshot('ORDER BY date ASC')),
        'month_ago': reading(_snapshot('WHERE date <= ? ORDER BY date DESC', [dateOnly(today.subtract(const Duration(days: 30)))])),
        'now': reading(_snapshot('WHERE date <= ? ORDER BY date DESC', [dateOnly(today)])),
      },
      'highlights': _highlights(lastMonth, lastMonthEnd),
    };
  }

  // ---- Compare any two months ----------------------------------------------

  static DateTime _parseMonth(String ym) {
    final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(ym);
    if (m == null) throw ValidationException('month', 'Use a month like 2026-11');
    return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  Json compareMonths({String? monthA, String? monthB, String type = 'EXPENSE', bool sameDays = false}) {
    if (type != 'EXPENSE' && type != 'INCOME') throw ValidationException('type', 'Choose spending or income');
    final current = _ym(today);
    final months = {
      current,
      for (final r in _db.query("SELECT DISTINCT substr(date, 1, 7) AS m FROM transactions WHERE status = 'CONFIRMED'")) r['m'] as String,
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    final a = _parseMonth(monthA ?? current), b = _parseMonth(monthB ?? _ym(_lastMonth));
    final cutDay = sameDays && (_ym(a) == current || _ym(b) == current) ? today.day : null;

    // The last day counted in a month: today for this month, the cut day
    // when comparing the same days, otherwise the month's last day.
    DateTime endOf(DateTime m) {
      final last = DateTime(m.year, m.month + 1, 0);
      var end = cutDay == null ? last : DateTime(m.year, m.month, cutDay < last.day ? cutDay : last.day);
      if (end.isAfter(today)) end = today;
      return end;
    }

    Json side(DateTime m) {
      final end = endOf(m);
      final full = DateTime(m.year, m.month + 1, 0);
      return {
        'month': _ym(m),
        'label': DateFormat('MMM yyyy').format(m),
        'from': dateOnly(m),
        'to': dateOnly(end),
        'partial': end.isBefore(full),
        ..._totalsJson(m.isAfter(today) ? (income: 0, expense: 0) : _between(m, end)),
      };
    }

    final sideA = side(a), sideB = side(b);
    final cats = <String?, _Group>{};
    void collect(DateTime m, bool isA) {
      if (m.isAfter(today)) return;
      for (final r in _db.query('''
        SELECT category_id, subcategory_id, $_payeeKey AS pkey, MAX(COALESCE(merchant, description)) AS name,
               SUM(amount_minor) AS total, COUNT(*) AS n
        FROM transactions WHERE status = 'CONFIRMED' AND type = ? AND date >= ? AND date <= ?
        GROUP BY category_id, subcategory_id, pkey''', [type, dateOnly(m), dateOnly(endOf(m))])) {
        final total = r['total'] as int, n = r['n'] as int;
        final g = cats.putIfAbsent(r['category_id'] as String?, _Group.new);
        g.pair.add(isA, total, n);
        g.subs.putIfAbsent(r['subcategory_id'] as String?, _Pair.new).add(isA, total, n);
        final key = (r['pkey'] as String?) ?? '';
        final p = g.payees.putIfAbsent(key, _Pair.new)..add(isA, total, n);
        p.name ??= r['name'] as String?;
      }
    }

    collect(a, true);
    collect(b, false);
    final catRows = {for (final r in _db.query('SELECT id, name, color FROM categories')) r['id'] as String: r};
    final subNames = {for (final r in _db.query('SELECT id, name FROM subcategories')) r['id'] as String: r['name'] as String};
    int biggest(Json x) => (x['a_minor'] as int) > (x['b_minor'] as int) ? x['a_minor'] as int : x['b_minor'] as int;
    List<Json> sorted(List<Json> rows) => rows
      ..sort((x, y) => biggest(y).compareTo(biggest(x)))
      ..forEach((r) => r
        ..remove('a_minor')
        ..remove('b_minor'));

    final categories = [
      for (final MapEntry(key: id, value: g) in cats.entries)
        {
          'id': id,
          'name': id == null ? 'No category' : (catRows[id]?['name'] ?? 'Other'),
          'color': id == null ? null : catRows[id]?['color'],
          ...g.pair.json(),
          'subcategories': sorted([
            for (final MapEntry(key: sid, value: s) in g.subs.entries)
              {'id': sid, 'name': sid == null ? 'No subcategory' : (subNames[sid] ?? 'Other'), ...s.json()},
          ]),
          'payees': sorted([
            for (final p in g.payees.values) {'name': p.name ?? 'Unknown', ...p.json()},
          ]).take(8).toList(),
        },
    ];
    return {
      'type': type,
      'same_days': cutDay != null,
      'cut_day': cutDay,
      'available': [for (final m in months) {'month': m, 'label': DateFormat('MMM yyyy').format(_parseMonth(m))}],
      'a': sideA,
      'b': sideB,
      'categories': sorted(categories),
    };
  }

  // ---- More for the Wealth screen ---------------------------------------------

  static const _readyClasses = {'CASH_EQUIVALENT', 'EQUITY', 'MUTUAL_FUND', 'CRYPTO', 'COMMODITY_GOLD'};

  Json wealthOverview(Json summary) {
    Json reading(Row r) => {
          'date': r['date'],
          'net_worth': _amount(r['net_worth_minor'] as int),
          'assets': _amount(r['assets_minor'] as int),
          'liabilities': _amount(r['liabilities_minor'] as int),
        };
    final history = [
      for (final r in _db.query('SELECT * FROM wealth_snapshots WHERE date >= ? AND date <= ? ORDER BY date',
          [dateOnly(today.subtract(const Duration(days: 365))), dateOnly(today)]))
        reading(r),
    ];
    final now = _snapshot('WHERE date <= ? ORDER BY date DESC', [dateOnly(today)]);
    Json? since(Row? then) => then == null || now == null || then['date'] == now['date']
        ? null
        : {'date': then['date'], 'from': _amount(then['net_worth_minor'] as int), 'to': _amount(now['net_worth_minor'] as int)};
    Row? before(int days) => _snapshot('WHERE date <= ? ORDER BY date DESC', [dateOnly(today.subtract(Duration(days: days)))]);

    // Accounts and where the money sits.
    final accounts = [
      for (final r in _db.query('SELECT name, account_type, balance_minor FROM accounts WHERE is_active = 1 ORDER BY balance_minor DESC'))
        {'name': r['name'], 'type': r['account_type'], 'balance': _amount(r['balance_minor'] as int)},
    ];
    var bank = 0.0, locked = 0.0, ready = 0.0;
    for (final a in accounts) {
      final balance = a['balance'] as double;
      if (balance <= 0) continue;
      if (a['type'] == 'FIXED_DEPOSIT') {
        locked += balance;
      } else {
        bank += balance;
      }
    }
    final classes = (summary['asset_classes'] as List).cast<Json>();
    final holdings = <Json>[];
    var investments = 0.0;
    for (final c in classes) {
      final value = toDouble(c['total_current_value']);
      investments += value;
      if (_readyClasses.contains(c['asset_class'])) {
        ready += value;
      } else {
        locked += value;
      }
      holdings.addAll((c['items'] as List).cast<Json>());
    }

    // Best and worst performers (by % gain on what was put in).
    final priced = holdings.where((h) => toDouble(h['invested_amount']) > 0).toList()
      ..sort((x, y) => toDouble(y['pnl_percentage']).compareTo(toDouble(x['pnl_percentage'])));
    Json perf(Json h) => {
          'name': h['name'],
          'asset_class': h['asset_class'],
          'invested': toDouble(h['invested_amount']),
          'value': toDouble(h['current_value']),
          'pnl': toDouble(h['pnl']),
          'pnl_pct': toDouble(h['pnl_percentage']),
        };
    final gainers = [for (final h in priced.where((h) => toDouble(h['pnl']) > 0).take(3)) perf(h)];
    final losers = [for (final h in priced.reversed.where((h) => toDouble(h['pnl']) < 0).take(3)) perf(h)];

    Json? concentration;
    if (holdings.length >= 2 && investments > 0) {
      final top = holdings.reduce((x, y) => toDouble(x['current_value']) >= toDouble(y['current_value']) ? x : y);
      concentration = {'name': top['name'], 'value': toDouble(top['current_value']), 'share': toDouble(top['current_value']) / investments * 100};
    }

    final cover = _cover();
    final incomes = [
      for (var i = 1; i <= 3; i++) _totals(DateTime(today.year, today.month - i)).income,
    ].where((e) => e > 0).toList();
    final monthlyIncome = incomes.isEmpty ? 0.0 : _amount(incomes.reduce((x, y) => x + y) ~/ incomes.length);
    final assets = toDouble(summary['total_assets_current']);
    final liabilities = toDouble(summary['total_liabilities_outstanding']);
    final emi = toDouble(summary['total_monthly_emi']);
    final owedOnCards = accounts.where((a) => a['type'] == 'CREDIT_CARD' && (a['balance'] as double) < 0).fold<double>(0, (s, a) => s - (a['balance'] as double));

    return {
      'history': history,
      'changes': {
        'month': since(before(30)),
        'quarter': since(before(90)),
        'start': since(_snapshot('ORDER BY date ASC')),
      },
      'accounts': accounts,
      'split': {'bank': bank, 'ready': ready, 'locked': locked, 'investments': investments},
      'emergency': cover == null ? null : {'cash': _amount(cover.cash), 'monthly_spend': _amount(cover.monthly), 'months': cover.months},
      'debt': {
        'liabilities': liabilities,
        'assets': assets,
        'debt_to_assets': assets > 0 ? liabilities / assets * 100 : null,
        'emi': emi,
        'monthly_income': monthlyIncome,
        'emi_to_income': monthlyIncome > 0 ? emi / monthlyIncome * 100 : null,
        'cards_owed': owedOnCards,
      },
      'gainers': gainers,
      'losers': losers,
      'concentration': concentration,
    };
  }

  /// Plain facts about this month so far, each {kind, title, value, note}.
  List<Json> _highlights(DateTime lastMonth, DateTime lastMonthEnd) {
    final out = <Json>[];
    final from = dateOnly(_monthStart), to = dateOnly(today);
    final spent = _between(_monthStart, today).expense;
    final lastSpent = _between(lastMonth, lastMonthEnd).expense;
    if (spent > 0 || lastSpent > 0) {
      out.add({
        'kind': 'daily',
        'title': 'Average spend per day',
        'value': _m(spent ~/ today.day),
        'note': lastSpent > 0 ? '${_m(lastSpent ~/ _daysIn(lastMonth))} a day in ${_monthName(lastMonth)}' : null,
      });
    }
    final biggest = _db.queryOne('''
      SELECT COALESCE(merchant, description) AS name, amount_minor, date FROM transactions
      WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ? ORDER BY amount_minor DESC LIMIT 1''', [from, to]);
    if (biggest != null) {
      out.add({
        'kind': 'biggest',
        'title': 'Biggest payment',
        'value': _m(biggest['amount_minor'] as int),
        'note': '${biggest['name']} · ${_day(DateTime.parse(biggest['date'] as String))}',
      });
    }
    final busiest = _db.queryOne('''
      SELECT date, SUM(amount_minor) AS total, COUNT(*) AS n FROM transactions
      WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ? GROUP BY date ORDER BY total DESC LIMIT 1''', [from, to]);
    if (busiest != null && (busiest['n'] as int) > 1) {
      out.add({
        'kind': 'busiest',
        'title': 'Busiest spending day',
        'value': _m(busiest['total'] as int),
        'note': '${DateFormat('EEEE, d MMM').format(DateTime.parse(busiest['date'] as String))} · ${busiest['n']} payments',
      });
    }
    final payee = _db.queryOne('''
      SELECT MAX(COALESCE(merchant, description)) AS name, COUNT(*) AS n, SUM(amount_minor) AS total FROM transactions
      WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ?
      GROUP BY COALESCE(merchant_key, lower(trim(COALESCE(merchant, description)))) HAVING COUNT(*) > 1
      ORDER BY n DESC, total DESC LIMIT 1''', [from, to]);
    if (payee != null) {
      out.add({
        'kind': 'payee',
        'title': 'Paid most often',
        'value': '${payee['name']}',
        'note': '${payee['n']} times · ${_m(payee['total'] as int)}',
      });
    }
    final count = _db.queryOne('''
      SELECT COUNT(DISTINCT date) AS days, COUNT(*) AS n FROM transactions
      WHERE status = 'CONFIRMED' AND type = 'EXPENSE' AND date >= ? AND date <= ?''', [from, to])!;
    if ((count['n'] as int) > 0) {
      final noSpend = today.day - (count['days'] as int);
      out.add({
        'kind': 'count',
        'title': 'Payments this month',
        'value': '${count['n']}',
        'note': noSpend > 0 ? '$noSpend day${noSpend == 1 ? '' : 's'} with no spending' : 'Spent something every day',
      });
    }
    return out;
  }


  // ---- Reminders to schedule as phone notifications -------------------------

  /// Future notifications: bills the day before (or the morning of) their due
  /// date, policy renewals a week ahead, the monthly summary on the 1st, and
  /// a check-in if the app is not opened for 3 days.
  List<Json> reminders({int days = 30}) {
    final out = <Json>[];
    DateTime at(DateTime d, int hour) => DateTime(d.year, d.month, d.day, hour);
    void add(String key, String kind, DateTime when, String title, String body) {
      if (when.isAfter(now)) out.add({'key': key, 'kind': kind, 'at': when.toIso8601String(), 'title': title, 'body': body});
    }

    for (final o in _occurrences(today, today.add(Duration(days: days)))) {
      if (o['flow_type'] != 'EXPENSE' || o['status'] != 'upcoming') continue;
      final date = DateTime.parse(o['occurrence_date'] as String);
      final amount = (o['amount_is_estimate'] == true ? 'About ' : '') + _m(toMinor(toDouble(o['amount'])));
      final key = 'bill:${o['schedule_id']}:${o['occurrence_date']}';
      final dayBefore = at(date.subtract(const Duration(days: 1)), 9);
      if (dayBefore.isAfter(now)) {
        add(key, 'bill', dayBefore, 'Due tomorrow: ${o['description']}', '$amount. Tap to see your bills.');
      } else {
        add(key, 'bill', at(date, 9), 'Due today: ${o['description']}', '$amount. Tap to see your bills.');
      }
    }

    for (final r in _db.query('''
      SELECT id, policy_name, renewal_date FROM insurance_policies
      WHERE status = 'ACTIVE' AND renewal_date IS NOT NULL AND renewal_date > ? AND renewal_date <= ?''',
        [dateOnly(today), dateOnly(today.add(Duration(days: days + 7)))])) {
      final date = DateTime.parse(r['renewal_date'] as String);
      add('renewal:${r['id']}:${r['renewal_date']}', 'bill', at(date.subtract(const Duration(days: 7)), 9),
          '${r['policy_name']} renews in 7 days', 'Renewal on ${_day(date)}. Renew in time to stay covered.');
    }

    final nextMonth = DateTime(today.year, today.month + 1);
    add('summary:${_ym(today)}', 'summary', at(nextMonth, 9), '${_monthName(today)} summary is ready',
        'See what came in, what went out and what you saved.');

    add('checkin', 'checkin', at(today.add(const Duration(days: 3)), 20), 'Catch up on your money',
        'Open Finverse to pick up new bank payments and see this week\'s insights.');

    out.sort((a, b) => (a['at'] as String).compareTo(b['at'] as String));
    return out;
  }
}

/// Amounts (minor units) and payment counts for month A and month B.
class _Pair {
  int a = 0, b = 0, countA = 0, countB = 0;
  String? name;

  void add(bool isA, int total, int n) {
    if (isA) {
      a += total;
      countA += n;
    } else {
      b += total;
      countB += n;
    }
  }

  Json json() => {'a': fromMinor(a), 'b': fromMinor(b), 'count_a': countA, 'count_b': countB, 'a_minor': a, 'b_minor': b};
}

/// One category in a month comparison, with its subcategories and payees.
class _Group {
  final pair = _Pair();
  final subs = <String?, _Pair>{};
  final payees = <String, _Pair>{};
}
