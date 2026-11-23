import 'package:finance_tracker_mobile/local/py_round.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

void main() {
  test('pyRound matches Python round() for every saved case', () {
    final cases = (loadFixture('py_round.json')['cases'] as List).cast<Map>();
    final failures = <String>[];
    for (final c in cases) {
      final x = (c['x'] as num).toDouble();
      final digits = c['digits'] as int;
      final expected = (c['result'] as num).toDouble();
      final actual = pyRound(x, digits);
      if (actual != expected) failures.add('round($x, $digits): Python $expected, Dart $actual');
    }
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });

  test('exact ties go to the even digit like Python', () {
    expect(pyRound(0.125, 2), 0.12);
    expect(pyRound(0.375, 2), 0.38);
    expect(pyRound(2.5), 2.0);
    expect(pyRound(-2.5), -2.0);
    // 2.675 is really 2.67499999… in binary, so it is not a tie.
    expect(pyRound(2.675, 2), 2.67);
  });

  test('money converts to whole minor units without drift', () {
    expect(toMinor(0.29), 29);
    expect(toMinor(1234.56), 123456);
    expect(toMinor(0.1 + 0.2), 30);
    expect(fromMinor(123457), 1234.57);
  });
}
