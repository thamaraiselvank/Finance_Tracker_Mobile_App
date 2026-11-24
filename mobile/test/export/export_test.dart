import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:finance_tracker_mobile/export/export_data.dart';
import 'package:finance_tracker_mobile/export/export_files.dart';
import 'package:finance_tracker_mobile/import/table_reader.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Services s;
  late String savingsId, cardId;
  final today = DateTime(2026, 11, 24);

  setUp(() async {
    s = localServices(LocalDb.inMemory());
    await s.auth.updateProfile({'full_name': 'Asha'});
    await s.accounts.create({'name': 'HDFC Savings', 'account_type': 'SAVINGS', 'balance': 100000});
    await s.accounts.create({'name': 'ICICI Card', 'account_type': 'CREDIT_CARD', 'balance': 0});
    final accounts = await s.accounts.list();
    savingsId = accounts.firstWhere((a) => a['name'] == 'HDFC Savings')['id'] as String;
    cardId = accounts.firstWhere((a) => a['name'] == 'ICICI Card')['id'] as String;
    Future<void> tx(String type, double amount, String date, String desc, String account, {String? category}) =>
        s.transactions.create({'account_id': account, 'type': type, 'amount': amount, 'date': date, 'description': desc, 'category_id': category});
    await tx('INCOME', 85000, '2026-11-01', 'Salary, November', savingsId, category: '00000000-0000-0000-0000-000000000001');
    await tx('EXPENSE', 1250.5, '2026-11-02', 'Swiggy "late night"', cardId, category: '00000000-0000-0000-0000-000000000011');
    await tx('EXPENSE', 499, '2026-11-03', '=HYPERLINK("x")', savingsId);
    await tx('TRANSFER', 20000, '2026-11-05', 'To Zerodha', savingsId);
    await tx('EXPENSE', 300, '2026-10-30', 'October chai', savingsId);
    await s.assets.create({'name': 'Nifty 50 index fund', 'asset_class': 'MUTUAL_FUND', 'invested_amount': 20000, 'current_value': 23000, 'quantity': 150.25});
    await s.assets.create({'name': 'Gold coin', 'asset_class': 'COMMODITY_GOLD', 'invested_amount': 60000, 'current_value': 75000});
    await s.goals.create({'goal_name': 'House', 'goal_type': 'DOWN_PAYMENT', 'target_amount': 1000000, 'current_amount': 250000, 'target_date': '2030-01-01'});
  });

  ExportOptions novemberOnly(Set<ExportSection> sections, {String type = 'ALL', String? accountId}) =>
      ExportOptions(sections: sections, start: DateTime(2026, 11, 1), end: DateTime(2026, 11, 30), type: type, accountId: accountId);

  group('tables', () {
    test('transactions: period, oldest first, totals leave transfers out', () async {
      final t = (await buildExportTables(s, novemberOnly({ExportSection.transactions}), today: today)).single;
      expect(t.subtitle, '1 Nov 2026 – 30 Nov 2026');
      expect([for (final r in t.rows) r[1]], ['Salary, November', 'Swiggy "late night"', '=HYPERLINK("x")', 'To Zerodha']);
      expect(t.rows.first[2], 'Income');
      expect(t.rows.first[3], 'Salary');
      expect(t.rows.first[5], 'HDFC Savings');
      expect(t.rows.first[6], 85000.0);
      final totals = {for (final (label, value, _) in t.totals) label: value};
      expect(totals['Total income'], 85000.0);
      expect(totals['Total expenses'], 1749.5);
      expect(totals['Net (income − expenses)'], 83250.5);
      expect(totals['Transfers (not counted above)'], 1);
    });

    test('transactions: only transfers, or only one account', () async {
      final transfers = (await buildExportTables(s, novemberOnly({ExportSection.transactions}, type: 'TRANSFER'), today: today)).single;
      expect([for (final r in transfers.rows) r[1]], ['To Zerodha']);
      final card = (await buildExportTables(s, novemberOnly({ExportSection.transactions}, accountId: cardId), today: today)).single;
      expect([for (final r in card.rows) r[1]], ['Swiggy "late night"']);
    });

    test('holdings with totals and net worth; goals', () async {
      final tables = await buildExportTables(s, ExportOptions(sections: {ExportSection.goals, ExportSection.holdings}), today: today);
      expect([for (final t in tables) t.section], [ExportSection.holdings, ExportSection.goals]); // fixed order
      final holdings = tables.first;
      expect(holdings.rows.length, 2);
      final totals = {for (final (label, value, _) in holdings.totals) label: value};
      expect(totals['Total invested'], 80000.0);
      expect(totals['Current value'], 98000.0);
      expect(totals['Gain / loss'], 18000.0);
      final goal = tables.last.rows.single;
      expect(goal[0], 'House');
      expect(goal[3], 250000.0);
      expect(goal[4], 25.0);
    });

    test('every section builds, even when empty', () async {
      final tables = await buildExportTables(localServices(LocalDb.inMemory()), ExportOptions(sections: ExportSection.values.toSet()), today: today);
      expect(tables.length, ExportSection.values.length);
    });
  });

  group('files', () {
    test('Excel: one sheet per section, real numbers and dates, readable back', () async {
      final tables = await buildExportTables(s, novemberOnly({ExportSection.transactions, ExportSection.holdings}), today: today);
      final file = await buildExportFile(tables, ExportFormat.xlsx, currency: 'INR', now: today);
      expect(file.name, 'finverse-export-2026-11-24.xlsx');
      final sheets = readXlsx(file.bytes);
      expect(sheets.keys, ['Transactions', 'Wealth holdings']);
      final tx = sheets['Transactions']!;
      expect(tx.first.take(3), ['Date', 'Description', 'Type']);
      expect(tx[1][1], 'Salary, November');
      expect(num.parse('${tx[1][6]}'), 85000); // stored as a number
      expect(num.parse('${tx[1][0]}'), 46327); // 1 Nov 2026 as an Excel date
      expect(tx[2][1], 'Swiggy "late night"');

      final zip = ZipDecoder().decodeBytes(file.bytes);
      final sheet = utf8.decode(zip.findFile('xl/worksheets/sheet1.xml')!.content);
      expect(sheet, contains('<autoFilter ref="A1:J5"/>'));
      expect(sheet, contains('state="frozen"'));
      final styles = utf8.decode(zip.findFile('xl/styles.xml')!.content);
      expect(styles, contains(r'##\,##\,##0.00')); // lakh grouping for rupees
    });

    test('CSV: Excel-friendly, quoted, formulas defused', () async {
      final tables = await buildExportTables(s, novemberOnly({ExportSection.transactions}), today: today);
      final file = await buildExportFile(tables, ExportFormat.csv, currency: 'INR', now: today);
      expect(file.name, 'finverse-transactions-2026-11-24.csv');
      expect(file.bytes.take(3), [0xEF, 0xBB, 0xBF]);
      final lines = utf8.decode(file.bytes.sublist(3)).split('\r\n');
      expect(lines[0], 'Date,Description,Type,Category,Subcategory,Account,Amount,Notes,Tags,Source');
      expect(lines[1], '2026-11-01,"Salary, November",Income,Salary,,HDFC Savings,85000.00,,,Added by hand');
      expect(lines[2], startsWith('2026-11-02,"Swiggy ""late night""",Expense'));
      expect(lines[3], startsWith('2026-11-03,"\'=HYPERLINK(""x"")",Expense'));
      // The CSV reader used for imports reads it back the same.
      expect(readCsv(utf8.decode(file.bytes))[2][1], 'Swiggy "late night"');
    });

    test('CSV of several sections comes as one zip', () async {
      final tables = await buildExportTables(s, ExportOptions(sections: {ExportSection.goals, ExportSection.accounts}), today: today);
      final file = await buildExportFile(tables, ExportFormat.csv, currency: 'INR', now: today);
      expect(file.name, 'finverse-export-2026-11-24-csv.zip');
      final names = [for (final f in ZipDecoder().decodeBytes(file.bytes).files) f.name];
      expect(names, ['finverse-accounts-2026-11-24.csv', 'finverse-goals-2026-11-24.csv']);
    });

    test('PDF report with the rupee sign and many pages', () async {
      for (var i = 0; i < 120; i++) {
        await s.transactions.create({'account_id': savingsId, 'type': 'EXPENSE', 'amount': 10 + i, 'date': '2026-11-10', 'description': 'Tea $i'});
      }
      final tables = await buildExportTables(s, novemberOnly({ExportSection.transactions, ExportSection.holdings, ExportSection.goals}), today: today);
      final fonts = ReportFonts(_font('Regular'), _font('Bold'));
      final file = await buildExportFile(tables, ExportFormat.pdf, currency: 'INR', now: today, ownerName: 'Asha', fonts: fonts);
      expect(file.name, 'finverse-report-2026-11-24.pdf');
      expect(latin1.decode(file.bytes.sublist(0, 5)), '%PDF-');
      expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(file.bytes)).length, greaterThan(2));
    });
  });
}

ByteData _font(String weight) => ByteData.sublistView(File('assets/fonts/Roboto-$weight.ttf').readAsBytesSync());
