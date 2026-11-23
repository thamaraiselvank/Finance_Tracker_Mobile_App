import 'dart:convert';
import 'dart:io';

import 'package:finance_tracker_mobile/local/local_planning.dart';
import 'package:finance_tracker_mobile/local/tax_estimator.dart';
import 'package:finance_tracker_mobile/services/errors.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

/// The error text the app shows for a Python fixture error.
String expectedMessage(Map error) =>
    error['field'] == null ? error['message'] as String : '${prettyField(error['field'] as String)}: ${error['message']}';

void main() {
  group('calculators match Python', () {
    final cases = (loadFixture('calculators.json')['cases'] as List).cast<Map>();
    for (final (index, c) in cases.indexed) {
      final kind = CalculatorKind.values.byName(c['kind'] as String);
      test('${c['kind']} #$index ${c.containsKey('error') ? '(error)' : ''}', () {
        final input = Map<String, dynamic>.from(c['input'] as Map);
        if (c.containsKey('error')) {
          expect(() => runCalculator(kind, input), throwsA(predicate((e) => e.toString() == expectedMessage(c['error'] as Map))),
              reason: 'expected "${expectedMessage(c['error'] as Map)}"');
        } else {
          expectMatchesPython(runCalculator(kind, input), c['output']);
        }
      });
    }
  });

  group('income tax matches Python', () {
    final fixture = loadFixture('tax.json');
    final rules = TaxRules([jsonDecode(File('assets/tax/india_tax_rules.json').readAsStringSync()) as Map<String, dynamic>]);

    test('bundled rules file is identical to the backend copy', () {
      final app = jsonDecode(File('assets/tax/india_tax_rules.json').readAsStringSync());
      final backend = jsonDecode(File('../backend/app/data/india_tax_rules.json').readAsStringSync());
      expect(app, backend, reason: 'Copy backend/app/data/india_tax_rules.json to mobile/assets/tax/');
    });

    test('rules endpoint', () {
      expectMatchesPython(rules.describe(null), fixture['default_rules']);
      (fixture['rules_by_year'] as Map).forEach((year, expected) => expectMatchesPython(rules.describe(year as String), expected));
    });

    for (final (index, c) in (fixture['estimate_cases'] as List).cast<Map>().indexed) {
      test('estimate #$index ${c['input']}', () {
        final input = Map<String, dynamic>.from(c['input'] as Map);
        if (c.containsKey('error')) {
          expect(() => estimateIndiaTax(rules, TaxInput.parse(input)),
              throwsA(predicate((e) => e.toString() == expectedMessage(c['error'] as Map))),
              reason: 'expected "${expectedMessage(c['error'] as Map)}"');
        } else {
          expectMatchesPython(estimateIndiaTax(rules, TaxInput.parse(input)), c['output']);
        }
      });
    }
  });
}
