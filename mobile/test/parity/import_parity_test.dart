import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_tracker_mobile/import/statement_parser.dart';
import 'package:finance_tracker_mobile/import/table_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parity.dart';

/// Differences from the backend that are on purpose (the backend is wrong
/// here). Each one is checked against the corrected result instead.
const _intended = {
  // pandas dayfirst=True reads "2026-11-01" as 11 January.
  'negative_amounts_no_type',
  // A plain "Debit" column was also taken as the "Type" column, which
  // flagged every debit row for review.
  'debit_and_credit_both',
  'balance_mismatch',
  // A file without a transaction table now says so instead of importing nothing.
  'no_header',
};

const _statementKeys = ['date', 'time', 'description', 'amount', 'type', 'category', 'subcategory', 'needs_review'];
const _holdingKeys = [
  'name', 'asset_class', 'sub_type', 'quantity', 'buy_price', 'invested_amount', 'current_price', 'current_value', 'purchase_date', 'notes',
];

Map<String, dynamic> _pick(Map<String, dynamic> result, List<String> keys) => {
      'success': true,
      'preview': [
        for (final r in result['preview'] as List) {for (final k in keys) k: (r as Map)[k]},
      ],
    };

Map<String, dynamic> _statement(Map<String, dynamic> c) {
  final bytes = Uint8List.fromList(base64Decode(c['content_b64'] as String));
  final sheets = readSheets(bytes);
  try {
    return _pick(
        parseStatementTable(sheets.values.first, filename: c['filename'] as String, excel: sniffSheet(bytes) == SheetFormat.xlsx), _statementKeys);
  } on UnreadableFileException {
    return {'success': false};
  }
}

void main() {
  final fixture = loadFixture('import.json');

  group('bank statements match the backend', () {
    for (final c in (fixture['statement_cases'] as List).cast<Map<String, dynamic>>()) {
      if (_intended.contains(c['name'])) continue;
      test(c['name'] as String, () {
        final diff = diffJson(c['expected'], _statement(c), tolerance: 0.005);
        expect(diff, isEmpty, reason: diff.join('\n'));
      });
    }
  });

  group('holdings match the backend', () {
    for (final c in (fixture['stock_cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final sheets = readSheets(Uint8List.fromList(base64Decode(c['content_b64'] as String)));
        final actual = _pick(parseStockTable(sheets.values.first, filename: c['filename'] as String, broker: c['broker'] as String), _holdingKeys);
        final diff = diffJson(c['expected'], actual, tolerance: 0.005);
        expect(diff, isEmpty, reason: diff.join('\n'));
      });
    }
    for (final c in (fixture['zerodha_cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final sheets = readSheets(Uint8List.fromList(base64Decode(c['content_b64'] as String)));
        final actual = _pick(parseZerodhaWorkbook(sheets, filename: c['filename'] as String), _holdingKeys);
        final diff = diffJson(c['expected'], actual, tolerance: 0.005);
        expect(diff, isEmpty, reason: diff.join('\n'));
      });
    }
  });

  group('intended differences', () {
    Map<String, dynamic> caseNamed(String name) =>
        (fixture['statement_cases'] as List).cast<Map<String, dynamic>>().firstWhere((c) => c['name'] == name);

    test('ISO dates are read as written', () {
      final c = caseNamed('negative_amounts_no_type');
      final expected = jsonDecode(jsonEncode(c['expected'])) as Map<String, dynamic>;
      final rows = (expected['preview'] as List).cast<Map<String, dynamic>>();
      expect([rows[0]['date'], rows[1]['date']], ['2026-01-11', '2026-02-11'], reason: 'the backend bug this fixes');
      rows[0]['date'] = '2026-11-01';
      rows[1]['date'] = '2026-11-02';
      expect(diffJson(expected, _statement(c)), isEmpty);
    });

    test('a Debit column is not the type column', () {
      final both = _statement(caseNamed('debit_and_credit_both'))['preview'] as List;
      expect([for (final r in both) r['needs_review']], [true, false, true]); // both amounts; fine; no description
      final balance = _statement(caseNamed('balance_mismatch'))['preview'] as List;
      // Coffee follows the balance; the other two don't.
      expect([for (final r in balance) r['needs_review']], [false, true, true]);
      // Everything else still matches the backend.
      for (final name in ['debit_and_credit_both', 'balance_mismatch']) {
        final expected = (caseNamed(name)['expected']['preview'] as List).cast<Map<String, dynamic>>();
        final actual = (_statement(caseNamed(name))['preview'] as List).cast<Map<String, dynamic>>();
        for (var i = 0; i < expected.length; i++) {
          expect(diffJson({...expected[i]}..remove('needs_review'), {...actual[i]}..remove('needs_review')), isEmpty);
        }
      }
    });

    test('a file with no transaction table is an error', () {
      final c = caseNamed('no_header');
      expect(c['expected'], {'success': true, 'preview': <Object>[]});
      expect(_statement(c), {'success': false});
    });
  });
}
