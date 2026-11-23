import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:finance_tracker_mobile/import/layout_parser.dart';
import 'package:finance_tracker_mobile/import/narration.dart';
import 'package:finance_tracker_mobile/import/pdf_reader.dart';
import 'package:finance_tracker_mobile/import/statement_parser.dart';
import 'package:finance_tracker_mobile/import/table_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' show PdfRect;

/// Words of one text line: (x, text) pairs at height [y], about 7 px per letter.
List<PageWord> line(double y, List<(double, String)> words, {double confidence = 100}) => [
      for (final (x, text) in words) PageWord(text, left: x, top: y, width: text.length * 7.0, height: 14, confidence: confidence),
    ];

/// A minimal .xlsx with inline strings and numbers, written by hand.
Uint8List xlsx(List<List<Object?>> rows) {
  String col(int i) => String.fromCharCode(65 + i);
  final sheet = StringBuffer('<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>');
  for (var r = 0; r < rows.length; r++) {
    sheet.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final v = rows[r][c];
      if (v == null) continue;
      final ref = '${col(c)}${r + 1}';
      sheet.write(v is num ? '<c r="$ref"><v>$v</v></c>' : '<c r="$ref" t="inlineStr"><is><t>$v</t></is></c>');
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData></worksheet>');
  final files = {
    'xl/workbook.xml':
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Account" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="x"/></Relationships>',
    'xl/worksheets/sheet1.xml': sheet.toString(),
  };
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('table reader', () {
    test('CSV: quotes, commas inside quotes, CRLF, BOM', () {
      final rows = readCsv(decodeText(utf8.encode('﻿Date,Narration,Amount\r\n01/11/26,"Swiggy, Bangalore",-450\r\n02/11/26,"He said ""hi""",10\r\n')));
      expect(rows, [
        ['Date', 'Narration', 'Amount'],
        ['01/11/26', 'Swiggy, Bangalore', '-450'],
        ['02/11/26', 'He said "hi"', '10'],
      ]);
    });

    test('CSV with semicolons or tabs', () {
      expect(readCsv('Date;Amount;Note\n1/1/26;1,5;x\n'), [
        ['Date', 'Amount', 'Note'],
        ['1/1/26', '1,5', 'x'],
      ]);
      expect(readCsv('Date\tAmount\n1/1/26\t10\n').first, ['Date', 'Amount']);
    });

    test('.xlsx sheets, with dates as Excel day numbers', () {
      final sheets = readSheets(xlsx([
        ['Statement of account'],
        [],
        ['Date', 'Narration', 'Withdrawal', 'Deposit', 'Balance'],
        [46327, 'UPI-SWIGGY-swiggy@ybl', 450.5, null, 9549.5],
      ]));
      expect(sheets.keys, ['Account']);
      final result = parseStatementTable(sheets['Account']!, filename: 'x.xlsx', excel: true);
      final row = (result['preview'] as List).single as Map;
      expect(row['date'], '2026-11-01');
      expect(row['amount'], 450.5);
      expect(row['type'], 'EXPENSE');
    });

    test('bank "Excel" files that are really web pages', () {
      final html = utf8.encode('<html><table><tr><th>Date</th><th>Narration</th><th>Debit</th><th>Credit</th></tr>'
          '<tr><td>01/11/2026</td><td>ATM&nbsp;WDL</td><td>2,000.00</td><td></td></tr></table></html>');
      final bytes = Uint8List.fromList(html);
      expect(sniffSheet(bytes), SheetFormat.html);
      final row = (parseStatementTable(readSheets(bytes).values.first, filename: 'x.xls')['preview'] as List).single as Map;
      expect([row['description'], row['amount'], row['type']], ['ATM WDL', 2000.0, 'EXPENSE']);
    });

    test('old binary .xls asks to save as .xlsx or CSV', () {
      final bytes = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0]);
      expect(() => readSheets(bytes), throwsA(isA<UnreadableFileException>().having((e) => e.message, 'message', contains('.xlsx or CSV'))));
    });
  });

  group('statement values', () {
    test('dates banks use', () {
      String? d(Object v) {
        final r = parseImportDate(v);
        return r == null ? null : isoDate(r);
      }

      expect(d('15/11/2026'), '2026-11-15');
      expect(d('15-11-26'), '2026-11-15');
      expect(d('15.11.2026'), '2026-11-15');
      expect(d('2026-11-15'), '2026-11-15');
      expect(d('15-Nov-2026'), '2026-11-15');
      expect(d('15 NOV 26'), '2026-11-15');
      expect(d('15 November 2026'), '2026-11-15');
      expect(d('Nov 15, 2026'), '2026-11-15');
      expect(d('11/15/2026'), '2026-11-15'); // can't be day-first
      expect(d('31/02/2026'), isNull);
      expect(d('Opening balance'), isNull);
    });

    test('amounts', () {
      expect(cleanAmount('₹1,234.50'), 1234.5);
      expect(cleanAmount('INR 500 Cr'), 500);
      expect(cleanAmount('(200.00)'), -200);
      expect(cleanAmount('Rs.99'), 99);
      expect(cleanAmount('abc'), 0);
      expect(cellAmount('12,345.00 Cr'), 12345);
      expect(cellAmount('Swiggy'), isNull);
      expect(cellAmount(''), 0);
    });

    test('opening / closing balance lines are skipped', () {
      final result = parseStatementTable([
        ['Date', 'Narration', 'Debit', 'Credit', 'Balance'],
        ['', 'Opening Balance', '', '1,000.00', '1,000.00'],
        ['01/11/2026', 'Coffee', '100', '', '900'],
        ['', 'Closing Balance', '', '', '900'],
      ], filename: 'x.csv');
      expect([for (final r in result['preview'] as List) r['description']], ['Coffee']);
    });
  });

  group('PDF layout', () {
    // An HDFC-style typed statement: two-word headings, a two-line
    // narration, a page footer, and a second page without a heading.
    final header = line(300, [
      (100, 'Date'), (250, 'Narration'), (520, 'Chq./Ref.No.'), (650, 'Value'), (690, 'Dt'), (780, 'Withdrawal'), (856, 'Amt.'),
      (960, 'Deposit'), (1015, 'Amt.'), (1120, 'Closing'), (1175, 'Balance'),
    ]);
    final page1 = [
      ...line(80, [(100, 'HDFC'), (140, 'BANK'), (180, 'Ltd.')]),
      ...line(120, [(100, 'Statement'), (170, 'of'), (190, 'account')]),
      ...header,
      ...line(340, [(100, '01/11/26'), (250, 'UPI-SWIGGY-swiggy@ybl-YESB0000001'), (520, '0000412345678901'), (650, '01/11/26'), (800, '450.00'), (1140, '10,550.00')]),
      ...line(356, [(250, '412345678901-Payment')]),
      ...line(380, [(100, '03/11/26'), (250, 'NEFT'), (290, 'CR-YESB0000001-ZERODHA'), (650, '03/11/26'), (980, '12,345.00'), (1140, '22,895.00')]),
      ...line(396, [(250, 'BROKING'), (310, 'LTD-ZERODHA-YESBN1234')]),
      ...line(900, [(600, 'Page'), (635, '1'), (650, 'of'), (670, '2')]),
    ];
    final page2 = [
      ...line(100, [(100, '05/11/26'), (250, 'ATW-512345XXXXXX1234-S1ANMU12-MUMBAI'), (650, '05/11/26'), (800, '2,000.00'), (1140, '20,895.00')]),
    ];

    test('reads rows, joins wrapped narrations, carries the heading to the next page', () {
      final rows = parseLayoutPages([(words: page1, ocr: false), (words: page2, ocr: false)]);
      expect(rows, hasLength(3));
      expect(rows[0]['description'], 'UPI-SWIGGY-swiggy@ybl-YESB0000001 412345678901-Payment');
      expect([rows[0]['date'], rows[0]['amount'], rows[0]['type'], rows[0]['needs_review']], ['2026-11-01', 450.0, 'EXPENSE', false]);
      expect(rows[1]['description'], 'NEFT CR-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN1234');
      expect([rows[1]['amount'], rows[1]['type']], [12345.0, 'INCOME']);
      expect([rows[2]['date'], rows[2]['amount'], rows[2]['type'], rows[2]['needs_review']], ['2026-11-05', 2000.0, 'EXPENSE', false]);
      expect(rows.every((r) => !(r['description'] as String).contains('Page')), isTrue);
    });

    test('SBI-style "Txn Date" / "Value Date" headings and "15 Nov 2026" dates', () {
      final words = [
        ...line(200, [(100, 'Txn'), (125, 'Date'), (220, 'Value'), (262, 'Date'), (340, 'Description'), (600, 'Ref'), (630, 'No./Cheque'), (800, 'Debit'), (900, 'Credit'), (1000, 'Balance')]),
        ...line(240, [(100, '15'), (118, 'Nov'), (143, '2026'), (220, '15'), (238, 'Nov'), (263, '2026'), (340, 'TO'), (360, 'TRANSFER-UPI/DR/412345/Zomato'), (600, 'TRANSFER'), (800, '320.00'), (1000, '9,680.00')]),
      ];
      final rows = parseLayoutPages([(words: words, ocr: false)]);
      expect(rows.single['date'], '2026-11-15');
      expect(rows.single['description'], 'TO TRANSFER-UPI/DR/412345/Zomato');
      expect([rows.single['amount'], rows.single['type']], [320.0, 'EXPENSE']);
    });

    test('scanned pages with unknown confidence are marked for review', () {
      final words = [...header, ...line(340, [(100, '01/11/26'), (250, 'Coffee'), (800, '120.00')], confidence: -1)];
      final rows = parseLayoutPages([(words: words, ocr: true)]);
      expect(rows.single['needs_review'], isTrue);
    });

    test('PDF characters become words, also where cells have no space between them', () {
      // "Date" then, with a wide gap and no space character, "450.00".
      final text = 'Date450.00';
      final rects = [
        for (var i = 0; i < 4; i++) PdfRect(10.0 + i * 5, 700, 15.0 + i * 5, 690),
        for (var i = 0; i < 6; i++) PdfRect(200.0 + i * 5, 700, 205.0 + i * 5, 690),
      ];
      final words = wordsFromChars(text, rects, 800);
      expect(words.map((w) => w.text), ['Date', '450.00']);
      expect(words.first.top, closeTo(100 * 200 / 72, 0.01));
    });

    test('bank name from the first pages', () {
      expect(detectBank('Statement from HDFC BANK LIMITED for'), 'HDFC Bank');
      expect(detectBank('nothing here'), isNull);
    });
  });

  group('narration names', () {
    test('the other side of common statement narrations', () {
      expect(narrationName('UPI/DR/412345678901/SWIGGY/YESB/swiggy@ybl/Payment'), 'SWIGGY');
      expect(narrationName('UPI-ZOMATO LTD-zomato@hdfcbank-HDFC0000001-412345678901-Payment'), 'ZOMATO LTD');
      expect(narrationName('NEFT CR-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN1234'), 'ZERODHA BROKING LTD');
      expect(narrationName('POS 4321XXXX1234 AMAZON PAY IN'), 'AMAZON PAY IN');
      expect(narrationName('IMPS-412300000002-RAHUL K-SBIN'), 'RAHUL K');
      expect(narrationName('ACH D- BAJAJ FINANCE LTD-123456'), 'BAJAJ FINANCE LTD');
      expect(narrationName('412345678901'), isNull);
    });
  });
}
