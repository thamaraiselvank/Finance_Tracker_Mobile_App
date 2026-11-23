import 'package:finance_tracker_mobile/local/assessment.dart';
import 'package:finance_tracker_mobile/services/errors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

void main() {
  for (final (index, c) in (loadFixture('assessment.json')['cases'] as List).cast<Map>().indexed) {
    test('check-up #$index matches Python', () {
      final input = Map<String, dynamic>.from(c['input'] as Map);
      if (c.containsKey('error')) {
        final e = c['error'] as Map;
        final expected = e['field'] == null ? e['message'] : '${prettyField(e['field'] as String)}: ${e['message']}';
        expect(() => offlineAssessment(input), throwsA(predicate((err) => err.toString() == expected)), reason: 'expected "$expected"');
        return;
      }
      final result = offlineAssessment(input);
      final expected = Map<String, dynamic>.from(c['output'] as Map);
      expectMatchesPython({for (final k in ['score', 'rating', 'data_confidence', 'pillar_scores', 'recommendations']) k: result[k]}, expected);
      expect(result['disclaimer'], isNotEmpty);
    });
  }
}
