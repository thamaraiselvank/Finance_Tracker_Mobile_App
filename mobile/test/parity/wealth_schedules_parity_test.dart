import 'dart:convert';

import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_wealth.dart';
import 'package:finance_tracker_mobile/local/py_round.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

/// Runs the local services on a phone database holding the same sample rows
/// the Python routes were given, and compares the results.
void main() {
  late LocalDb db;
  setUp(() => db = LocalDb.inMemory());
  tearDown(() => db.close());

  int? minor(Object? v) => v == null ? null : toMinor(v as num);

  group('Bills & recurring calendar matches Python', () {
    final fixture = loadFixture('schedules.json');
    final today = DateTime.parse(fixture['today'] as String);

    void load() {
      db.execute("INSERT INTO accounts (id, name, account_type, created_at, updated_at) VALUES ('acc', 'HDFC', 'SAVINGS', 'x', 'x')");
      for (final s in (fixture['schedules'] as List).cast<Map>()) {
        db.execute('''INSERT INTO scheduled_cashflows (id, account_id, description, flow_type, source_type, amount_minor, amount_is_estimate,
                        frequency, interval_count, start_date, end_date, created_at, updated_at)
                      VALUES (?, 'acc', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'x', 'x')''', [
          s['id'], s['description'], s['flow_type'], s['source_type'], minor(s['amount']), s['amount_is_estimate'] == true ? 1 : 0,
          s['frequency'], s['interval_count'], s['start_date'], s['end_date'],
        ]);
      }
      for (final a in (fixture['actuals'] as List).cast<Map>()) {
        db.execute('''INSERT INTO transactions (id, account_id, type, amount_minor, date, description, scheduled_cashflow_id,
                        scheduled_occurrence_date, source, created_at)
                      VALUES (?, 'acc', 'EXPENSE', ?, ?, 'x', ?, ?, 'SCHEDULE', 'x')''',
            [a['transaction_id'], minor(a['actual_amount']), a['actual_date'], a['scheduled_cashflow_id'], a['scheduled_occurrence_date']]);
      }
    }

    for (final (index, c) in (fixture['cases'] as List).cast<Map>().indexed) {
      test('range #$index ${c['start']} → ${c['end']}', () {
        load();
        final service = LocalSchedulesService(db, today: () => today);
        DateTime? d(Object? v) => v == null ? null : DateTime.parse(v as String);
        if (c.containsKey('error')) {
          expect(() => service.scheduleOccurrences(start: d(c['start']), end: d(c['end'])),
              throwsA(predicate((e) => e.toString() == (c['error'] as Map)['message'])));
        } else {
          expectMatchesPython(service.scheduleOccurrences(start: d(c['start']), end: d(c['end'])), c['output']);
        }
      });
    }

    test('which dates belong to a schedule', () {
      final byId = {for (final s in (fixture['schedules'] as List).cast<Map>()) s['id']: Map<String, dynamic>.from(s)};
      for (final check in (fixture['is_occurrence'] as List).cast<Map>()) {
        final r = Recurrence.of(byId[check['schedule']]!);
        expect(r.isOccurrence(DateTime.parse(check['date'] as String)), check['is_occurrence'], reason: '${check['schedule']} ${check['date']}');
      }
    });
  });

  test('Wealth summary matches Python', () async {
    final fixture = loadFixture('wealth.json');
    for (final (i, a) in (fixture['accounts'] as List).cast<Map>().indexed) {
      db.execute("INSERT INTO accounts (id, name, account_type, balance_minor, created_at, updated_at) VALUES (?, ?, 'SAVINGS', ?, 'x', 'x')",
          ['acc$i', 'Account $i', minor(a['balance'])]);
    }
    for (final (i, d) in (fixture['debts'] as List).cast<Map>().indexed) {
      db.execute('''INSERT INTO debts (id, debt_name, debt_type, principal_minor, current_outstanding_minor, interest_rate_pct, monthly_emi_minor,
                      created_at, updated_at) VALUES (?, ?, 'OTHER', 1, ?, 10, ?, 'x', 'x')''',
          ['d$i', 'Debt $i', minor(d['current_outstanding']), minor(d['monthly_emi'])]);
    }
    for (final h in (fixture['holdings'] as List).cast<Map>()) {
      final meta = h['meta_data'];
      db.execute('''INSERT INTO assets (id, name, asset_class, sub_type, invested_minor, current_value_minor, quantity, buy_price_minor,
                      current_price_minor, purchase_date, notes, meta_data, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', [
        h['id'], h['name'], h['asset_class'], h['sub_type'], minor(h['invested_amount']), minor(h['current_value']), h['quantity'],
        minor(h['buy_price']), minor(h['current_price']), h['purchase_date'], h['notes'],
        meta == null ? '{}' : (meta is String ? meta : jsonEncode(meta)), h['created_at'], h['updated_at'],
      ]);
    }
    // Income from holdings is phone-only (not in the backend): leave it out.
    final summary = await LocalAssetsService(db).summary();
    summary.remove('passive_income');
    for (final c in (summary['asset_classes'] as List).cast<Map>()) {
      for (final i in (c['items'] as List).cast<Map>()) {
        i.remove('income');
      }
    }
    expectMatchesPython(summary, fixture['output']);
  });
}
