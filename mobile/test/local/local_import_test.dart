import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_tracker_mobile/capture/categorizer.dart';
import 'package:finance_tracker_mobile/import/layout_parser.dart';
import 'package:finance_tracker_mobile/import/pdf_reader.dart';
import 'package:finance_tracker_mobile/import/table_reader.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/services/errors.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePdf implements StatementPdfReader {
  _FakePdf(this.words, {this.password});
  final List<PageWord> words;
  final String? password;
  String? gotPassword;

  @override
  Future<PdfWords> read(Uint8List bytes, {String? password}) async {
    gotPassword = password;
    if (this.password != null && password != this.password) throw const UnreadableFileException('This PDF is locked.');
    return PdfWords([(words: words, ocr: false)], 'ICICI Bank statement');
  }
}

List<PageWord> _line(double y, List<(double, String)> words) =>
    [for (final (x, t) in words) PageWord(t, left: x, top: y, width: t.length * 7.0, height: 14)];

const _statement = '''
Date,Narration,Withdrawal Amt.,Deposit Amt.,Closing Balance
01/11/26,UPI-SWIGGY-swiggy@ybl-YESB0000001-412345678901-Payment,450.00,,9550.00
03/11/26,NEFT CR-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN1234,,"12,345.00",21895.00
05/11/26,ATW-512345XXXXXX1234-S1ANMU12-MUMBAI,2000.00,,19895.00
07/11/26,SALARY NOV ACME PVT LTD,,85000.00,104895.00
08/11/26,POS 4321XXXX1234 AMAZON PAY IN,999.00,,103896.00
09/11/26,UPI-SPAM SHOP-spam@ybl-Payment,10.00,,103886.00
''';

void main() {
  late LocalDb db;
  late Services services;
  late String accountId;

  Future<Json> parse(String csv, {String filename = 'statement.csv'}) => services.imports.parseFile(
        bytes: utf8.encode(csv),
        filename: filename,
        importType: 'transactions',
        accountId: accountId,
      );

  Map<String, dynamic> row(Json result, String contains) =>
      (result['preview'] as List).cast<Map<String, dynamic>>().firstWhere((r) => (r['description'] as String).contains(contains));

  setUp(() async {
    db = LocalDb.inMemory();
    services = localServices(db);
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 10000});
    accountId = (await services.accounts.list()).single['id'] as String;
  });
  tearDown(() => db.close());

  test('rows get the same type and category as SMS payments would', () async {
    final now = DateTime.now().toIso8601String();
    // The user taught Finverse that Amazon Pay is Entertainment, and to ignore "spam shop".
    db.execute(
      "INSERT INTO capture_rules (id, match_kind, match_value, direction, type, category_id, auto_add, label, hits, created_at, updated_at) "
      "VALUES ('r1', 'PARTY', 'amazon pay in', 'OUT', 'EXPENSE', ?, 0, 'Amazon', 1, ?, ?), "
      "('r2', 'PARTY', 'spam shop', 'OUT', 'IGNORE', NULL, 0, 'Spam', 1, ?, ?)",
      [CategoryIds.entertainment, now, now, now, now],
    );
    final result = await parse(_statement);

    final zerodha = row(result, 'ZERODHA');
    expect([zerodha['type'], zerodha['direction'], zerodha['category_id'], zerodha['suggest_label']],
        ['TRANSFER', 'IN', CategoryIds.brokerFunds, 'Built-in: broker funds']);
    expect(zerodha['category_name'], 'Broker funds');
    final atm = row(result, 'ATW-');
    expect([atm['type'], atm['direction'], atm['category_id']], ['TRANSFER', 'OUT', CategoryIds.cashWithdrawal]);
    final salary = row(result, 'SALARY');
    expect([salary['type'], salary['category_id']], ['INCOME', CategoryIds.salary]);
    final swiggy = row(result, 'SWIGGY');
    expect([swiggy['type'], swiggy['category_id'], swiggy['suggest_label']], ['EXPENSE', CategoryIds.food, 'Guess · please check']);
    final amazon = row(result, 'AMAZON');
    expect([amazon['merchant'], amazon['category_id'], amazon['suggest_label']], ['AMAZON PAY IN', CategoryIds.entertainment, 'Learned from your choice']);
    expect(row(result, 'SPAM')['skip_reason'], 'You chose to ignore payments like this');
  });

  test('payments already in Money are marked, once each', () async {
    await services.transactions.create({'account_id': accountId, 'type': 'EXPENSE', 'amount': 450, 'date': '2026-11-02', 'description': 'Swiggy'});
    final result = await parse(_statement);
    expect(row(result, 'SWIGGY')['duplicate'], isTrue);
    expect(row(result, 'SWIGGY')['duplicate_note'], 'Already in Money');
    expect(row(result, 'ZERODHA')['duplicate'], isNull);

    // Two identical rows match one existing payment only once.
    final twice = await parse('Date,Narration,Debit,Credit\n02/11/2026,Swiggy,450,\n02/11/2026,Swiggy,450,\n');
    expect([for (final r in twice['preview'] as List) r['duplicate']], [true, null]);
  });

  test('a pending SMS payment in the review inbox counts as already there', () async {
    await services.capture!.ingest([
      CapturedMessage(source: 'SMS', sender: 'AX-HDFCBK', body: 'Rs.450.00 debited from a/c XX1234 on 01-11-26 to VPA swiggy@ybl', receivedAt: DateTime(2026, 11, 1, 13)),
    ]);
    final result = await parse(_statement);
    expect(row(result, 'SWIGGY')['duplicate_note'], 'Waiting in your review inbox from SMS');
  });

  test('importing saves rows, moves balances, and own money is not income or spending', () async {
    final preview = await parse(_statement);
    final rows = [
      for (final r in (preview['preview'] as List).cast<Map<String, dynamic>>())
        if (r['skip_reason'] == null)
          {
            'date': r['date'],
            'description': r['description'],
            'amount': r['amount'],
            'type': r['type'],
            'direction': ?r['direction'],
            'category_id': ?r['category_id'],
            'notes': ?r['category_name'],
          },
    ];
    final res = await services.imports.commitTransactions(accountId, rows) as Map;
    expect(res['message'], 'Imported 6 transactions.');

    // 10000 - 450 + 12345 - 2000 + 85000 - 999 - 10
    expect((await services.accounts.list()).single['balance'], 103886.0);
    final saved = db.query("SELECT type, direction, source, status, notes FROM transactions WHERE description LIKE '%ZERODHA%'").single;
    expect(saved, {'type': 'TRANSFER', 'direction': 'IN', 'source': 'IMPORT', 'status': 'CONFIRMED', 'notes': null});
    final summary = await services.transactions.summary(start: DateTime(2026, 11, 1), end: DateTime(2026, 11, 30));
    expect(summary['total_income'], 85000.0);
    expect(summary['total_expense'], 450.0 + 999.0 + 10.0);

    // Reading the same statement again finds every row already in Money.
    final again = await parse(_statement);
    expect((again['preview'] as List).every((r) => r['duplicate'] == true), isTrue);
  });

  test('category names from the file are used, and new ones created', () async {
    final preview = await parse('Date,Note,Amount,Income/Expense,Category,Subcategory\n'
        '15-11-2026,Lunch,-250,Expense,Food & Groceries,Restaurants\n'
        '17-11-2026,Birthday gift,500,Income,Gifts,\n');
    final lunch = row(preview, 'Lunch');
    expect([lunch['category_id'], lunch['suggest_label']], [CategoryIds.food, 'From your file']);
    expect(row(preview, 'gift')['category_id'], isNull);

    await services.imports.commitTransactions(accountId, [
      for (final r in (preview['preview'] as List).cast<Map<String, dynamic>>())
        {
          'date': r['date'],
          'description': r['description'],
          'amount': r['amount'],
          'type': r['type'],
          'category_id': ?r['category_id'],
          'category': r['category'],
          'subcategory': r['subcategory'],
        },
    ]);
    final saved = db.query('''SELECT t.description, c.name AS category, s.name AS sub FROM transactions t
        JOIN categories c ON c.id = t.category_id LEFT JOIN subcategories s ON s.id = t.subcategory_id ORDER BY t.date''');
    expect(saved, [
      {'description': 'Lunch', 'category': 'Food & Groceries', 'sub': 'Restaurants'},
      {'description': 'Birthday gift', 'category': 'Gifts', 'sub': null},
    ]);
  });

  test('a category that does not fit the type falls back; own money needs a direction', () async {
    await services.imports.commitTransactions(accountId, [
      {'date': '2026-11-01', 'description': 'Odd', 'amount': 10, 'type': 'EXPENSE', 'category_id': CategoryIds.salary},
    ]);
    expect(db.queryOne("SELECT c.name FROM transactions t JOIN categories c ON c.id = t.category_id WHERE description = 'Odd'")!['name'],
        'Other Expenses');
    expect(
      () => services.imports.commitTransactions(accountId, [
        {'date': '2026-11-01', 'description': 'Move', 'amount': 10, 'type': 'TRANSFER'},
      ]),
      throwsA(isA<ValidationException>()),
    );
  });

  test('typed PDF statements, with a password', () async {
    final pdf = _FakePdf(password: 'secret', [
      ..._line(100, [(100, 'Date'), (250, 'Particulars'), (700, 'Withdrawals'), (850, 'Deposits'), (1000, 'Balance')]),
      ..._line(140, [(100, '01-11-2026'), (250, 'UPI/DR/412345678901/ZOMATO/YESB/zomato@ybl'), (700, '320.00'), (1000, '9,680.00')]),
    ]);
    final s = localServices(db, pdfReader: pdf);
    Future<Json> read(String? password) =>
        s.imports.parseFile(bytes: [1, 2, 3], filename: 'statement.PDF', importType: 'transactions', password: password, accountId: accountId);

    expect(() => read(null), throwsA(isA<ServiceException>().having((e) => e.message, 'message', 'This PDF is locked.')));
    final result = await read('secret');
    expect(pdf.gotPassword, 'secret');
    expect(result['detected_bank'], 'ICICI Bank');
    final r = (result['preview'] as List).single as Map;
    expect([r['date'], r['amount'], r['type'], r['merchant'], r['category_id']], ['2026-11-01', 320.0, 'EXPENSE', 'ZOMATO', CategoryIds.food]);
  });

  test('unsupported files say what to do', () async {
    expect(() => services.imports.parseFile(bytes: [1], filename: 'a.docx', importType: 'transactions'), throwsA(isA<ServiceException>()));
    expect(
      () => services.imports.parseFile(bytes: [0xD0, 0xCF, 0x11, 0xE0, 0], filename: 'a.xls', importType: 'transactions'),
      throwsA(isA<ServiceException>().having((e) => e.message, 'message', contains('save it as .xlsx or CSV'))),
    );
    expect(() => services.imports.parseFile(bytes: [1], filename: 'a.pdf', importType: 'stocks'), throwsA(isA<ServiceException>()));
  });

  test('holdings: importing again updates the ones already in Wealth', () async {
    const groww = 'Stock Name,ISIN,Quantity,Average buy price,Buy value,Closing price\n'
        'Infosys Ltd,INE009A01021,10,1450.5,14505,1520.25\n'
        'HDFC Bank Ltd,INE040A01034,5,1600,8000,1700\n';
    Future<Json> read(String csv) => services.imports.parseFile(bytes: utf8.encode(csv), filename: 'h.csv', importType: 'stocks', broker: 'GROWW');
    List<Json> rows(Json r) => [
          for (final h in (r['preview'] as List).cast<Map<String, dynamic>>()) Map<String, dynamic>.from(h)..remove('row_index'),
        ];

    final first = await read(groww);
    expect((first['preview'] as List).every((r) => r['updates_existing'] == null), isTrue);
    expect((await services.imports.commitAssets(rows(first)) as Map)['message'], 'Added 2 holdings.');

    final second = await read(groww.replaceFirst('Infosys Ltd,INE009A01021,10', 'Infosys Ltd,INE009A01021,12'));
    expect((second['preview'] as List).every((r) => r['updates_existing'] == true), isTrue);
    expect((await services.imports.commitAssets(rows(second)) as Map)['message'], 'Updated 2 already in Wealth.');
    final assets = db.query('SELECT name, quantity FROM assets');
    expect(assets, hasLength(2));
    expect(assets.firstWhere((a) => a['name'] == 'Infosys Ltd')['quantity'], 12.0);
  });
}
