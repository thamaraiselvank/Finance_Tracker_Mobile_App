import 'package:finance_tracker_mobile/local/health_engine.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/local_plans.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

void main() {
  List<Map<String, dynamic>> rows(Object? list) => [for (final r in list as List) Map<String, dynamic>.from(r as Map)];

  for (final c in (loadFixture('health.json')['cases'] as List).cast<Map>()) {
    test('health check "${c['name']}" matches Python', () {
      final result = computeFinancialHealth(
        user: Map<String, dynamic>.from(c['user'] as Map),
        tx: Map<String, dynamic>.from(c['tx'] as Map),
        assets: rows(c['assets']),
        accounts: rows(c['accounts']),
        debts: rows(c['debts']),
        policies: rows(c['policies']),
      );
      expectMatchesPython(result, c['output']);
    });
  }

  test('the health check reads the data on the phone', () async {
    final db = LocalDb.inMemory();
    addTearDown(db.close);
    final today = DateTime(2026, 11, 23);
    await LocalProfileService(db).updateProfile({'monthly_income': 100000, 'monthly_expense': 50000});
    await LocalAccountsService(db).create({'name': 'Bank', 'account_type': 'SAVINGS', 'balance': 300000});
    await LocalInsuranceService(db, today: () => today)
        .create({'policy_name': 'Term', 'policy_type': 'TERM_LIFE', 'sum_insured': 20000000, 'annual_premium': 15000});
    final h = await LocalEssentialsService(db, today: () => today).healthCheck();
    expect(h['emergency_runway_months'], 6.0); // 3,00,000 / 50,000
    expect(h['savings_rate_pct'], 50.0);
    expect(h['term_cover_status'], 'Good');
    expect(h['health_cover_status'], 'Risky');
  });
}
