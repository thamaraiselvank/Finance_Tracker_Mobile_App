import 'package:finance_tracker_mobile/local/debt_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

void main() {
  final fixture = loadFixture('debts.json');
  final today = DateTime.parse(fixture['today'] as String);

  for (final (index, c) in (fixture['cases'] as List).cast<Map>().indexed) {
    test('${c['strategy']} plan #$index matches Python', () {
      final debts = [for (final d in c['debts'] as List) Map<String, dynamic>.from(d as Map)];
      expectMatchesPython(debtPayoffPlan(debts, c['strategy'] as String, today), c['output']);
    });
  }

  test('adding months clamps to the end of shorter months', () {
    expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
    expect(addMonths(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 29));
    expect(addMonths(DateTime(2026, 11, 23), 14), DateTime(2028, 1, 23));
  });
}
