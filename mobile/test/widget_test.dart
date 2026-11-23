import 'package:flutter_test/flutter_test.dart';

import 'package:finance_tracker_mobile/core/format.dart';

void main() {
  test('Money formats INR with Indian grouping and no decimals', () {
    expect(Money('INR').format(1234567.4), '₹12,34,567');
  });

  test('Money.compact uses lakh / crore for INR', () {
    expect(Money('INR').compact(250000), '₹2.5L');
    expect(Money('INR').compact(32000000), '₹3.2Cr');
    expect(Money('USD').compact(1500), r'$1.5K');
  });

  test('hidden amounts are masked', () {
    expect(Money('INR').format(500, hidden: true), '₹ ••••');
  });

  test('JSON number helpers tolerate strings and nulls', () {
    expect(toDouble('12.5'), 12.5);
    expect(toDouble(null), 0);
    expect(toInt('7'), 7);
    expect(humanize('CREDIT_CARD'), 'Credit Card');
  });

  test('amount in words uses lakh / crore for INR', () {
    expect(amountInWords('1000', 'INR'), 'One thousand rupees');
    expect(amountInWords('150000', 'INR'), 'One lakh fifty thousand rupees');
    expect(amountInWords('25000000', 'INR'), 'Two crore fifty lakh rupees');
    expect(amountInWords('1', 'INR'), 'One rupee');
    expect(amountInWords('1500.50', 'INR'), 'One thousand five hundred rupees and fifty paise');
    expect(amountInWords('0', 'INR'), 'Zero rupees');
    expect(amountInWords('', 'INR'), isNull);
    expect(amountInWords('abc', 'INR'), isNull);
  });

  test('amount in words uses million for other currencies', () {
    expect(amountInWords('2500000', 'USD'), 'Two million five hundred thousand dollars');
    expect(amountInWords('999', 'GBP'), 'Nine hundred ninety nine pounds');
  });

  test('helper line shows formatted value and words', () {
    expect(amountHelperText('150000', 'INR'), '₹1,50,000 · One lakh fifty thousand rupees');
    expect(currencyForSymbol('₹'), 'INR');
  });
}
