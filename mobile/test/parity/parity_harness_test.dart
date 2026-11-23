import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

/// Checks the parity tooling itself. The per-service parity tests are added
/// as each backend service is ported to Dart.
void main() {
  group('diffJson', () {
    test('equal structures have no differences', () {
      expect(diffJson({'a': 1, 'b': [1.5, 'x', true, null]}, {'a': 1.0, 'b': [1.5, 'x', true, null]}), isEmpty);
    });

    test('reports the path of a changed number', () {
      expect(diffJson({'rows': [{'emi': 100.0}]}, {'rows': [{'emi': 100.01}]}), ['\$.rows[0].emi: expected 100.0, got 100.01']);
    });

    test('tolerance allows small rounding differences', () {
      expect(diffJson(100.0, 100.01, tolerance: 0.01), isEmpty);
      expect(diffJson(100.0, 100.02, tolerance: 0.01), isNotEmpty);
    });

    test('reports missing, extra keys and list length', () {
      final diffs = diffJson({'a': 1, 'list': [1, 2]}, {'b': 2, 'list': [1]});
      expect(diffs, containsAll([
        '\$.a: missing (expected 1)',
        '\$.b: unexpected extra key (2)',
        '\$.list: expected 2 items, got 1',
      ]));
    });

    test('type mismatches are differences', () {
      expect(diffJson({'ok': true}, {'ok': 'true'}), isNotEmpty);
      expect(diffJson(null, 0), isNotEmpty);
    });
  });

  group('fixtures', () {
    void expectWellFormed(List cases) {
      expect(cases, isNotEmpty);
      for (final c in cases.cast<Map>()) {
        expect(c['input'], isA<Map>());
        expect(c.containsKey('output') != c.containsKey('error'), isTrue, reason: 'each case has output or error: $c');
      }
    }

    test('calculators.json is well formed', () {
      final f = loadFixture('calculators.json');
      final cases = f['cases'] as List;
      expectWellFormed(cases);
      expect(cases.map((c) => c['kind']).toSet(), {'sip', 'lumpsum', 'emi', 'cagr', 'fire'});
    });

    test('tax.json is well formed', () {
      final f = loadFixture('tax.json');
      expectWellFormed(f['estimate_cases'] as List);
      expect((f['rules_by_year'] as Map), contains((f['default_rules'] as Map)['tax_year']));
    });
  });
}
