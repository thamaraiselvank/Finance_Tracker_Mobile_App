/// Statement and holdings import, on the phone (routers/import_data.py).
///
/// The file is read here (CSV, .xlsx, bank "Excel" web pages, PDF with
/// on-phone OCR for scanned pages); nothing is uploaded. Beyond the backend:
/// - each row gets the type and category Finverse would give the same
///   payment from an SMS (your rules, then built-in own-money rules, then a
///   keyword guess), so Zerodha settlements arrive as own money;
/// - rows already in Money (from SMS, a notification, a screenshot, or an
///   earlier import) are marked and left unticked;
/// - holdings already in Wealth are updated instead of added twice.
library;

import 'dart:typed_data';

import '../capture/categorizer.dart';
import '../import/layout_parser.dart';
import '../import/narration.dart';
import '../import/pdf_reader.dart';
import '../import/statement_parser.dart';
import '../import/table_reader.dart';
import '../services/errors.dart';
import '../services/services.dart';
import 'local_capture.dart';
import 'local_db.dart';
import 'local_money.dart';
import 'local_wealth.dart';
import 'py_round.dart';
import 'validate.dart';

const maxImportBytes = 15 * 1024 * 1024;

/// Days either side of a statement row's date in which an existing payment
/// of the same amount and direction counts as the same one (value dates and
/// SMS dates can differ by a day or two).
const duplicateDays = 2;

class LocalImportService implements ImportService {
  LocalImportService(this._db, {StatementPdfReader pdfReader = const PdfiumStatementReader()})
      : _pdf = pdfReader,
        _capture = LocalCaptureService(_db),
        _assets = LocalAssetsService(_db);

  final LocalDb _db;
  final StatementPdfReader _pdf;
  final LocalCaptureService _capture;
  final LocalAssetsService _assets;

  @override
  Future<Json> parseFile({
    required List<int> bytes,
    required String filename,
    required String importType,
    String? broker,
    String? password,
    String? accountId,
  }) async {
    final ext = filename.contains('.') ? filename.toLowerCase().split('.').last : '';
    if (!const {'csv', 'xlsx', 'xls', 'txt', 'pdf'}.contains(ext)) {
      throw const ServiceException('Unsupported file format. Please choose a CSV, Excel, or PDF file.');
    }
    final stocks = importType == 'stocks';
    if (stocks && ext == 'pdf') throw const ServiceException('PDF files can be imported as bank statements only.');
    if (bytes.length > maxImportBytes) throw const ServiceException('The file is larger than the 15 MB limit.');
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    try {
      if (ext == 'pdf') {
        final result = await _parsePdf(data, filename, password);
        _enrichTransactions(result['preview'] as List<Map<String, dynamic>>, accountId);
        return result;
      }
      final sheets = readSheets(data);
      if (stocks) {
        final b = (broker ?? 'OTHER').toUpperCase();
        final result = b == 'ZERODHA' ? parseZerodhaWorkbook(sheets, filename: filename) : _firstReadable(sheets, (t) => parseStockTable(t, filename: filename, broker: b));
        _markExistingHoldings((result['preview'] as List).cast<Map<String, dynamic>>());
        return result;
      }
      final excel = sniffSheet(data) == SheetFormat.xlsx;
      final result = _firstReadable(sheets, (t) => parseStatementTable(t, filename: filename, excel: excel));
      _enrichTransactions(result['preview'] as List<Map<String, dynamic>>, accountId);
      return result;
    } on UnreadableFileException catch (e) {
      throw ServiceException(e.message);
    }
  }

  /// The first sheet the parser can read (statements are not always on
  /// sheet 1).
  Map<String, dynamic> _firstReadable(Map<String, Table> sheets, Map<String, dynamic> Function(Table) parse) {
    UnreadableFileException? first;
    for (final table in sheets.values) {
      try {
        final result = parse(table);
        if ((result['preview'] as List).isNotEmpty || sheets.length == 1) return result;
      } on UnreadableFileException catch (e) {
        first ??= e;
      }
    }
    throw first ?? const UnreadableFileException('No rows with amounts were found in this file.');
  }

  Future<Map<String, dynamic>> _parsePdf(Uint8List data, String filename, String? password) async {
    final words = await _pdf.read(data, password: password);
    final records = parseLayoutPages(words.pages);
    if (records.length > maxStatementRows) {
      throw const UnreadableFileException('This statement contains more than $maxStatementRows transactions. Please split it into smaller files.');
    }
    if (records.isEmpty) {
      throw const UnreadableFileException(
          'No transactions could be found in this PDF. It needs a table with date, description, and debit/credit or amount columns. '
          'If your bank offers it, download the statement as Excel or CSV instead.');
    }
    final ocrPages = words.pages.where((p) => p.ocr).length;
    return {
      'success': true,
      'filename': filename,
      'detected_bank': detectBank(words.firstPagesText),
      'total_rows_found': records.length,
      'parsed_rows_count': records.length,
      'preview': records,
      if (ocrPages > 0) 'review_notice': '$ocrPages scanned page${ocrPages == 1 ? ' was' : 's were'} read with text recognition. Check amounts and dates before importing.',
    };
  }

  // -------------------------------------------------------------------------
  // Statement rows: type, category, duplicates
  // -------------------------------------------------------------------------

  void _enrichTransactions(List<Map<String, dynamic>> rows, String? accountId) {
    final categories = {for (final c in _db.query('SELECT id, name, type FROM categories')) c['id'] as String: c};
    final matched = <String>{};
    for (final r in rows) {
      final description = (r['description'] as String? ?? '').trim();
      final merchant = narrationName(description);
      if (merchant != null) r['merchant'] = merchant;
      final type = r['type'] as String?;
      if (type != 'INCOME' && type != 'EXPENSE') continue;
      final direction = type == 'INCOME' ? 'IN' : 'OUT';
      r['direction'] = direction;

      final fileCategory = (r['category'] as String?)?.trim();
      final named = fileCategory == null || fileCategory.isEmpty
          ? null
          : _db.queryOne(
              "SELECT id, name, type FROM categories WHERE lower(name) = lower(?) AND type IN (?, 'TRANSFER') ORDER BY is_system DESC LIMIT 1",
              [fileCategory, type]);
      if (named != null) {
        r['type'] = named['type'];
        r['category_id'] = named['id'];
        r['suggest_source'] = 'FILE';
        r['suggest_label'] = 'From your file';
      } else if (fileCategory == null || fileCategory.isEmpty) {
        final s = _capture.suggest(text: description, merchant: merchant, direction: direction);
        if (s['type'] == 'IGNORE') {
          r['skip_reason'] = 'You chose to ignore payments like this';
        } else {
          r['type'] = s['type'];
          r['category_id'] = s['category_id'];
          r['subcategory_id'] = s['subcategory_id'];
          r['suggest_source'] = s['source'];
          r['suggest_label'] = switch (s['source']) {
            'RULE' => 'Learned from your choice',
            'GUESS' => 'Guess · please check',
            _ => s['label'],
          };
        }
      }
      final categoryId = r['category_id'] as String?;
      if (categoryId != null) r['category_name'] = categories[categoryId]?['name'];

      if (accountId != null) {
        final dup = _findExisting(r, accountId, direction, matched);
        if (dup != null) {
          matched.add(dup['id'] as String);
          r['duplicate'] = true;
          r['duplicate_note'] = _duplicateNote(dup);
        }
      }
    }
  }

  Row? _findExisting(Map<String, dynamic> r, String accountId, String direction, Set<String> matched) {
    final date = r['date'] as String?;
    final amount = (r['amount'] as num?)?.toDouble() ?? 0;
    if (date == null || amount <= 0) return null;
    final d = DateTime.parse(date);
    final candidates = _db.query(
      '''SELECT id, source, status, date, description FROM transactions
         WHERE amount_minor = ? AND status IN ('CONFIRMED', 'PENDING')
           AND (account_id = ? OR account_id IS NULL)
           AND date BETWEEN ? AND ?
           AND (CASE WHEN type = 'INCOME' THEN 'IN' WHEN type = 'EXPENSE' THEN 'OUT' ELSE direction END) = ?
         ORDER BY abs(julianday(date) - julianday(?)), created_at''',
      [
        toMinor(amount),
        accountId,
        dateOnly(d.subtract(const Duration(days: duplicateDays))),
        dateOnly(d.add(const Duration(days: duplicateDays))),
        direction,
        date,
      ],
    );
    for (final c in candidates) {
      if (!matched.contains(c['id'])) return c;
    }
    return null;
  }

  String _duplicateNote(Row t) {
    final status = t['status'] == 'PENDING' ? 'Waiting in your review inbox' : 'Already in Money';
    final how = switch (t['source']) {
      'SMS' => 'from SMS',
      'UPI_NOTIFICATION' => 'from a payment notification',
      'SHARE' => 'from a screenshot',
      'IMPORT' => 'from an earlier import',
      _ => null,
    };
    return [status, ?how].join(' ');
  }

  void _markExistingHoldings(List<Map<String, dynamic>> rows) {
    for (final r in rows) {
      final isin = ((r['meta_data'] as Map?)?['isin'] as String?)?.trim() ?? '';
      final existing = _db.queryOne(
        '''SELECT id FROM assets
           WHERE (? <> '' AND json_extract(meta_data, '\$.isin') = ?) OR lower(name) = lower(?)
           ORDER BY created_at LIMIT 1''',
        [isin, isin, r['name']],
      );
      if (existing != null) {
        r['existing_asset_id'] = existing['id'];
        r['updates_existing'] = true;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Saving
  // -------------------------------------------------------------------------

  @override
  Future<Json> commitTransactions(String accountId, List<Json> transactions) async {
    if (transactions.isEmpty) throw const ServiceException('No transactions provided for import.');
    var count = 0;
    _db.transaction(() {
      requireAccount(_db, accountId);
      for (final item in transactions) {
        final type = (item['type'] as String? ?? '').toUpperCase();
        if (!const {'INCOME', 'EXPENSE', 'TRANSFER'}.contains(type)) {
          throw ValidationException('type', 'Each imported transaction must be income, spending or own money.');
        }
        final direction = switch (type) {
          'INCOME' => 'IN',
          'EXPENSE' => 'OUT',
          _ => (item['direction'] as String?)?.toUpperCase(),
        };
        if (direction != 'IN' && direction != 'OUT') {
          throw ValidationException('direction', 'Say whether own money came in or went out.');
        }
        final date = parseImportDate(item['date']);
        if (date == null) throw ValidationException('date', 'Each imported transaction must have a valid date.');
        final amount = readNumber(item, 'amount', required: true, gt: 0)!;
        final description = (item['description'] as String? ?? '').trim();
        if (description.isEmpty) throw ValidationException('description', 'Each imported transaction must have a description.');

        final category = _resolveCategory(type, item);
        final subcategoryId = _resolveSubcategory(category?['id'] as String?, item);
        final notes = (item['notes'] as String?)?.trim();
        final merchant = narrationName(description);
        final amountMinor = toMinor(amount);
        _db.execute(
          '''INSERT INTO transactions (id, account_id, category_id, subcategory_id, type, amount_minor, date, description, notes,
               source, status, merchant, merchant_key, direction, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'IMPORT', 'CONFIRMED', ?, ?, ?, ?)''',
          [
            newId(),
            accountId,
            category?['id'],
            subcategoryId,
            type,
            amountMinor,
            isoDate(date),
            description,
            notes == null || notes.isEmpty || notes.toLowerCase() == (category?['name'] as String?)?.toLowerCase() ? null : notes,
            merchant,
            merchant == null ? null : merchantKey(merchant),
            direction,
            nowTimestamp(),
          ],
        );
        applyToBalance(_db, accountId, type, amountMinor, direction);
        count++;
      }
    });
    return {
      'success': true,
      'imported_count': count,
      'message': 'Imported $count transaction${count == 1 ? '' : 's'}.',
    };
  }

  /// The chosen category if it fits the type; else one with the given name
  /// (created if missing, as the backend does); else Other Income / Other
  /// Expenses, or Own account transfer for own money.
  Row? _resolveCategory(String type, Json item) {
    final id = item['category_id'] as String?;
    if (id != null && id.isNotEmpty) {
      final row = _db.queryOne('SELECT id, name, type FROM categories WHERE id = ?', [id]);
      if (row != null && row['type'] == type) return row;
    }
    for (final field in const ['category', 'notes']) {
      final name = (item[field] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      final row = _db.queryOne(
          'SELECT id, name, type FROM categories WHERE lower(name) = lower(?) AND type = ? ORDER BY is_system DESC LIMIT 1', [name, type]);
      if (row != null) return row;
      if (field == 'notes') break; // notes are only used to find an existing category
      final newRow = {'id': newId(), 'name': name, 'type': type};
      _db.execute(
        "INSERT INTO categories (id, name, type, icon, color, is_system, created_at) VALUES (?, ?, ?, 'Tag', '#10B981', 0, ?)",
        [newRow['id'], name, type, nowTimestamp()],
      );
      return newRow;
    }
    final fallback = switch (type) {
      'INCOME' => CategoryIds.otherIncome,
      'TRANSFER' => CategoryIds.ownTransfer,
      _ => '00000000-0000-0000-0000-000000000020', // Other Expenses
    };
    return _db.queryOne('SELECT id, name, type FROM categories WHERE id = ?', [fallback]);
  }

  String? _resolveSubcategory(String? categoryId, Json item) {
    if (categoryId == null) return null;
    final id = item['subcategory_id'] as String?;
    if (id != null && _db.queryOne('SELECT id FROM subcategories WHERE id = ? AND category_id = ?', [id, categoryId]) != null) return id;
    final name = (item['subcategory'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;
    final existing = _db.queryOne('SELECT id FROM subcategories WHERE category_id = ? AND lower(name) = lower(?)', [categoryId, name]);
    if (existing != null) return existing['id'] as String;
    final newSub = newId();
    _db.execute('INSERT INTO subcategories (id, category_id, name, created_at) VALUES (?, ?, ?, ?)', [newSub, categoryId, name, nowTimestamp()]);
    return newSub;
  }

  @override
  Future<Json> commitAssets(List<Json> assets) async {
    if (assets.isEmpty) throw const ServiceException('No holdings provided for import.');
    var added = 0, updated = 0;
    for (final a in assets) {
      if ((a['name'] as String? ?? '').trim().isEmpty) throw ValidationException('name', 'Each holding needs a name.');
    }
    for (final a in assets) {
      final existing = a['existing_asset_id'] as String?;
      if (existing != null && _db.queryOne('SELECT id FROM assets WHERE id = ?', [existing]) != null) {
        await _assets.update(existing, {
          for (final k in const ['quantity', 'buy_price', 'invested_amount', 'current_price', 'current_value', 'meta_data'])
            if (a[k] != null) k: a[k],
        });
        updated++;
      } else {
        await _assets.create({...a, 'asset_class': (a['asset_class'] as String? ?? 'EQUITY').toUpperCase()});
        added++;
      }
    }
    final parts = [
      if (added > 0) 'added $added holding${added == 1 ? '' : 's'}',
      if (updated > 0) 'updated $updated already in Wealth',
    ];
    final message = parts.join(', ');
    return {
      'success': true,
      'imported_count': added + updated,
      'added_count': added,
      'updated_count': updated,
      'message': '${message[0].toUpperCase()}${message.substring(1)}.',
    };
  }
}
