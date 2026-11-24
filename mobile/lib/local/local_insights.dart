/// Smart insights and alerts, worked out on the phone with plain rules.
///
/// Nothing here uses AI or the internet: each rule is a few SQL queries over
/// the user's own confirmed transactions, budgets, bills, policies and goals.
library;

import 'dart:convert';

import 'package:intl/intl.dart';

import '../core/format.dart';
import '../services/services.dart';
import 'local_db.dart';
import 'local_wealth.dart' show LocalSchedulesService;
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
    final dismissed = _readMap(_dismissedKey);
    return [
      for (final i in InsightEngine(_db, _now(), hideAmounts: hideAmounts).insights())
        if (!dismissed.containsKey(i['key'])) i,
    ];
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
