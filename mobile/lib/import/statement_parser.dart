/// Bank statement and broker holdings parsing, on the phone.
///
/// Ported from backend/app/services/importer.py (`parse_statement_file`,
/// `parse_stock_file`, `parse_zerodha_holdings_file`); checked against it by
/// test/parity/import_parity_test.dart. Differences, all on purpose:
/// - the table header is searched for in the first 100 rows of CSV files too
///   (bank CSVs often start with account details), and a file with no
///   table is an error instead of an empty import;
/// - "Opening / Closing balance" and "Total" lines are skipped;
/// - ISO dates (2026-11-01) are read as written (pandas' dayfirst made them
///   11 January);
/// - a plain "Debit" column is not also taken as the type column (which
///   flagged every debit row for review);
/// - CSV separators `;` and tab are detected, and bank ".xls" files that
///   are really web pages are read. Old binary .xls files are not.
library;

import 'table_reader.dart';

const maxStatementRows = 5000;

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

bool _isBlank(Object? v) => v == null || (v is String && v.trim().isEmpty) || (v is double && v.isNaN);

/// Text of a cell as pandas would print it (12.0 for a whole Excel number).
String cellText(Object? v) {
  if (v == null) return '';
  if (v is double) return v.toString();
  return v.toString();
}

/// `clean_amount`: "₹1,234.50 Cr" -> 1234.5, "(200)" -> -200, junk -> 0.
double cleanAmount(Object? val) {
  if (_isBlank(val)) return 0.0;
  if (val is num) return val.toDouble();
  var cleaned = val.toString().trim().replaceAll(RegExp(r'\b(?:INR|RS\.?|CR|DR)\b', caseSensitive: false), '');
  cleaned = cleaned.replaceAll(RegExp(r'[₹$\s,]'), '');
  if (cleaned.startsWith('(') && cleaned.endsWith(')')) cleaned = '-${cleaned.substring(1, cleaned.length - 1)}';
  return double.tryParse(cleaned) ?? 0.0;
}

String normalizeHeader(Object? value) =>
    cellText(value).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

int _fullYear(int y) => y >= 100 ? y : (y < 70 ? 2000 + y : 1900 + y);

DateTime? _validDate(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final date = DateTime.utc(y, m, d);
  return date.month == m && date.day == d ? date : null;
}

/// Day-first date parsing, like `pd.to_datetime(value, dayfirst=True)` for
/// the formats Indian banks use. Excel serial numbers only when
/// [excelSerial]. Returns null when it isn't a date.
DateTime? parseImportDate(Object? value, {bool excelSerial = false}) {
  if (_isBlank(value)) return null;
  if (value is DateTime) return DateTime.utc(value.year, value.month, value.day);
  if (value is num) {
    if (excelSerial && value >= 0 && value <= 2958465) {
      final d = DateTime.utc(1899, 12, 30).add(Duration(days: value.floor()));
      return DateTime.utc(d.year, d.month, d.day);
    }
    value = cellText(value);
  }
  final s = value.toString().trim();

  // 2026-11-15, 2026/11/15, 2026-11-15T10:30:00
  var m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:$|[ T])').firstMatch(s);
  if (m != null) return _validDate(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));

  // 15/11/2026, 15-11-26, 15.11.2026 (day first; month first only if the
  // first number can't be a month, as pandas does)
  m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})(?:$|[ T,])').firstMatch(s);
  if (m != null) {
    final a = int.parse(m[1]!), b = int.parse(m[2]!), y = _fullYear(int.parse(m[3]!));
    return _validDate(y, b, a) ?? _validDate(y, a, b);
  }

  // 15-Nov-2026, 15 Nov 26, 15-NOV-26, 15 November 2026
  m = RegExp(r'^(\d{1,2})[-/ .]?([A-Za-z]{3,9})[-/ .,]+(\d{2,4})(?:$|[ T,])').firstMatch(s);
  if (m != null) {
    final month = _months[m[2]!.toLowerCase().substring(0, 3)];
    if (month != null) return _validDate(_fullYear(int.parse(m[3]!)), month, int.parse(m[1]!));
  }

  // Nov 15, 2026 / November 15 2026
  m = RegExp(r'^([A-Za-z]{3,9})[ .-]+(\d{1,2}),?[ -]+(\d{2,4})(?:$|[ T,])').firstMatch(s);
  if (m != null) {
    final month = _months[m[1]!.toLowerCase().substring(0, 3)];
    if (month != null) return _validDate(_fullYear(int.parse(m[3]!)), month, int.parse(m[2]!));
  }
  return null;
}

/// "10:30", "10:30:15", "4:05 PM" -> "HH:MM:SS".
String? parseTimeString(Object? value) {
  if (_isBlank(value)) return null;
  final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?').firstMatch(value.toString());
  if (m == null) return null;
  var h = int.parse(m[1]!);
  final min = int.parse(m[2]!), sec = int.tryParse(m[3] ?? '') ?? 0;
  final ampm = m[4]?.toLowerCase();
  if (ampm == 'pm' && h < 12) h += 12;
  if (ampm == 'am' && h == 12) h = 0;
  if (h > 23 || min > 59 || sec > 59) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(h)}:${two(min)}:${two(sec)}';
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `coerce_transaction_type`.
String? coerceTransactionType(Object? value) {
  if (_isBlank(value)) return null;
  final n = cellText(value).trim().toUpperCase();
  if (n.isEmpty) return null;
  if (const {'INCOME', 'CREDIT', 'CR', 'CREDITED', 'DEPOSIT', 'RECEIVED'}.contains(n)) return 'INCOME';
  if (const {'EXPENSE', 'DEBIT', 'DR', 'DEBITED', 'WITHDRAWAL', 'PAID', 'SPENT', 'PAYMENT', 'OUTFLOW'}.contains(n)) return 'EXPENSE';
  if (n.contains('INCOME') || n.contains('CREDIT') || n.contains('DEPOSIT')) return 'INCOME';
  if (n.contains('EXPENSE') || n.contains('DEBIT') || n.contains('WITHDRAWAL')) return 'EXPENSE';
  return null;
}

// ---------------------------------------------------------------------------
// Columns
// ---------------------------------------------------------------------------

/// `match_column`: exact alias first, then prefix either way.
int? matchColumn(List<String> columns, List<String> aliases) {
  final normalized = <String, int>{};
  for (var i = 0; i < columns.length; i++) {
    final n = normalizeHeader(columns[i]);
    if (n.isNotEmpty) normalized[n] = i;
  }
  for (final alias in aliases) {
    final target = normalizeHeader(alias);
    if (normalized.containsKey(target)) return normalized[target];
  }
  for (final alias in aliases) {
    final target = normalizeHeader(alias);
    for (final MapEntry(:key, :value) in normalized.entries) {
      if (key == target || key.startsWith(target) || target.startsWith(key)) return value;
    }
  }
  return null;
}

/// `detect_column_mappings`: column index for each role. Unlike the backend,
/// a column already used for amounts is never also the type column (the
/// alias "debit credit" prefix-matched a plain "Debit" column there, which
/// flagged every debit row for review).
Map<String, int?> detectColumnMappings(List<String> columns) {
  final m = _detectColumnMappings(columns);
  final type = m['type'];
  if (type != null && (type == m['debit'] || type == m['credit'] || type == m['amount'])) m['type'] = null;
  return m;
}

Map<String, int?> _detectColumnMappings(List<String> columns) => {
      'date': matchColumn(columns, ['Date', 'date', 'transaction date', 'txn date', 'tran date', 'value date', 'value dt', 'posting date', 'date time', 'transaction datetime']),
      'time': matchColumn(columns, ['Time', 'time', 'transaction time', 'txn time', 'posted time']),
      'description': matchColumn(columns, ['Note', 'Notes', 'note', 'notes', 'Description', 'description', 'narration', 'transaction remarks', 'transaction details', 'txn details', 'particulars', 'remarks', 'details', 'memo', 'payee', 'merchant']),
      'amount': matchColumn(columns, ['Amount', 'amount', 'INR', 'transaction amount', 'txn amount', 'net amount', 'total', 'debit credit amount', 'amount inr']),
      'debit': matchColumn(columns, ['Debit', 'debit', 'withdrawal', 'withdrawals', 'dr', 'expense amount', 'debit amount']),
      'credit': matchColumn(columns, ['Credit', 'credit', 'deposit', 'deposits', 'cr', 'income amount', 'credit amount']),
      'balance': matchColumn(columns, ['Closing Balance', 'Available Balance', 'Running Balance', 'Balance']),
      'category': matchColumn(columns, ['Category', 'category', 'category name', 'tag', 'classification', 'type of transaction']),
      'subcategory': matchColumn(columns, ['Subcategory', 'Sub Category', 'subcategory', 'sub category', 'sub category name', 'sub category name', 'bucket', 'label']),
      'type': matchColumn(columns, ['Income/Expense', 'Income Expense', 'income expense', 'income/expense', 'Type', 'type', 'txn type', 'entry type', 'transaction type', 'dr cr', 'debit credit']),
      'account': matchColumn(columns, ['Account', 'account', 'account name', 'bank account', 'cash', 'wallet']),
    };

/// `_excel_header_values`: blank headers become "Unnamed: i", repeats get ".1".
List<String> headerValues(List<Object?> row) {
  final seen = <String, int>{};
  return [
    for (var i = 0; i < row.length; i++)
      () {
        var h = cellText(row[i]).trim();
        if (h.isEmpty) h = 'Unnamed: $i';
        final n = seen[h] ?? 0;
        seen[h] = n + 1;
        return n > 0 ? '$h.$n' : h;
      }(),
  ];
}

bool _isTransactionHeader(Map<String, int?> m) =>
    m['date'] != null && m['description'] != null && (m['amount'] != null || m['debit'] != null || m['credit'] != null);

// ---------------------------------------------------------------------------
// Bank statements
// ---------------------------------------------------------------------------

final _summaryLine = RegExp(r'^\s*(?:opening|closing|brought forward|carried forward|b/f|c/f)\b|^\s*(?:grand\s+)?total\b', caseSensitive: false);

/// Rows of a statement table -> preview records (`parse_statement_file`).
Map<String, dynamic> parseStatementTable(Table rows, {required String filename, bool excel = false}) {
  final nonEmpty = rows.where((r) => r.any((c) => !_isBlank(c))).toList();
  if (nonEmpty.isEmpty) throw const UnreadableFileException('This file is empty.');

  var headerAt = -1;
  for (var i = 0; i < nonEmpty.length && i < 100; i++) {
    if (_isTransactionHeader(detectColumnMappings(headerValues(nonEmpty[i])))) {
      headerAt = i;
      break;
    }
  }
  if (headerAt < 0) {
    throw const UnreadableFileException(
        'Could not find the transaction table. The file needs date, description, and amount or debit/credit columns.');
  }
  final headers = headerValues(nonEmpty[headerAt]);
  final mapping = detectColumnMappings(headers);
  final body = nonEmpty.sublist(headerAt + 1);

  Object? cell(List<Object?> row, String role) {
    final i = mapping[role];
    return i == null || i >= row.length ? null : row[i];
  }

  final records = <Map<String, dynamic>>[];
  for (var idx = 0; idx < body.length; idx++) {
    final row = body[idx];
    final typeRaw = cell(row, 'type');
    final explicitType = coerceTransactionType(typeRaw);
    final typeUnrecognized = !_isBlank(typeRaw) && explicitType == null;

    Object? dateRaw = cell(row, 'date');
    Object? timeRaw = cell(row, 'time');
    if (dateRaw is String && dateRaw.trim().contains(' ') && _isBlank(timeRaw)) {
      final t = dateRaw.trim();
      final space = t.indexOf(' ');
      // "15 Nov 2026" has spaces but no time: only split "date time".
      if (RegExp(r'\d{1,2}:\d{2}').hasMatch(t.substring(space + 1))) {
        final timePart = RegExp(r'\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AaPp][Mm])?').firstMatch(t)!;
        timeRaw = timePart[0];
        dateRaw = t.substring(0, timePart.start).trim();
      }
    }
    final rowDate = parseImportDate(dateRaw, excelSerial: excel);
    final rowTime = _isBlank(timeRaw) ? null : parseTimeString(timeRaw);

    var amount = 0.0;
    var txType = explicitType;
    var needsReview = rowDate == null || typeUnrecognized;
    final debit = mapping['debit'] != null ? cleanAmount(cell(row, 'debit')) : 0.0;
    final credit = mapping['credit'] != null ? cleanAmount(cell(row, 'credit')) : 0.0;
    final amountRaw = cell(row, 'amount');

    if (debit > 0 && credit <= 0) {
      amount = debit;
      txType = explicitType ?? 'EXPENSE';
      if (explicitType != null && explicitType != 'EXPENSE') needsReview = true;
    } else if (credit > 0 && debit <= 0) {
      amount = credit;
      txType = explicitType ?? 'INCOME';
      if (explicitType != null && explicitType != 'INCOME') needsReview = true;
    } else if (debit > 0 && credit > 0) {
      needsReview = true;
    } else if (!_isBlank(amountRaw)) {
      final marker = cellText(amountRaw).trim().toUpperCase();
      amount = cleanAmount(amountRaw);
      if (amount < 0) {
        amount = amount.abs();
        if (explicitType == null) {
          txType = 'EXPENSE';
        } else if (explicitType != 'EXPENSE') {
          needsReview = true;
        }
      } else if (explicitType == null && RegExp(r'\bCR(?:EDIT)?\b').hasMatch(marker)) {
        txType = 'INCOME';
      } else if (explicitType == null && RegExp(r'\bDR(?:EBIT)?\b').hasMatch(marker)) {
        txType = 'EXPENSE';
      } else if (explicitType != null) {
        txType = explicitType;
      } else {
        txType = null;
        needsReview = true;
      }
    }
    if (amount <= 0 && !(debit > 0 && credit > 0)) continue;

    String? text(String role) {
      final v = cell(row, role);
      if (_isBlank(v)) return null;
      final s = cellText(v).trim();
      return s.isEmpty ? null : s;
    }

    final category = text('category');
    final subcategory = text('subcategory');
    var description = text('description');
    if (description == null) {
      if (category != null && subcategory != null && category.toLowerCase() != subcategory.toLowerCase()) {
        description = '$category | $subcategory';
      } else {
        description = category ?? subcategory ?? '';
      }
    }
    if (description.trim().isEmpty) needsReview = true;
    if (rowDate == null && _summaryLine.hasMatch(description)) continue;

    final raw = <String, String?>{
      for (var i = 0; i < headers.length; i++) headers[i]: i < row.length && !_isBlank(row[i]) ? cellText(row[i]) : null,
    };
    final balance = cell(row, 'balance');
    records.add({
      'row_index': idx,
      'date': rowDate == null ? null : isoDate(rowDate),
      'time': rowTime,
      'description': description,
      'amount': _round2(amount),
      'type': txType,
      'category': category,
      'subcategory': subcategory,
      'needs_review': needsReview,
      'raw_data': {...raw, if (!_isBlank(balance)) 'balance': cellText(balance)},
    });
  }

  reconcileBalanceDirections(records);
  if (records.length > maxStatementRows) {
    throw const UnreadableFileException('This statement contains more than $maxStatementRows transactions. Please split it into smaller files.');
  }
  return {
    'success': true,
    'filename': filename,
    'total_rows_found': body.length,
    'parsed_rows_count': records.length,
    'detected_mappings': {for (final e in mapping.entries) e.key: e.value == null ? null : headers[e.value!]},
    'available_columns': headers,
    'preview': records,
  };
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// `_reconcile_balance_directions`: the running balance tells whether money
/// came in or went out; rows that disagree are flagged for review.
void reconcileBalanceDirections(List<Map<String, dynamic>> records) {
  double? previous;
  for (final r in records) {
    final balanceValue = (r['raw_data'] as Map?)?['balance'];
    final current = balanceValue == null || balanceValue == '' ? null : cleanAmount(balanceValue);
    final amount = (r['amount'] as num).toDouble();
    if (current != null && previous != null && amount > 0) {
      final delta = _round2(current - previous);
      final tolerance = amount * 0.001 > 0.02 ? amount * 0.001 : 0.02;
      if ((delta.abs() - amount).abs() <= tolerance) {
        final balanceType = delta > 0 ? 'INCOME' : 'EXPENSE';
        if (r['type'] == null) {
          r['type'] = balanceType;
        } else if (r['type'] != balanceType) {
          r['needs_review'] = true;
        }
      } else {
        r['needs_review'] = true;
      }
    }
    if (current != null) previous = current;
  }
}

// ---------------------------------------------------------------------------
// Broker holdings
// ---------------------------------------------------------------------------

Map<String, int?> detectStockColumnMappings(List<String> columns) => {
      'name': matchColumn(columns, ['Stock Name', 'Company Name', 'Scrip Name', 'Instrument', 'Trading Symbol', 'Tradingsymbol', 'Symbol', 'Security Name', 'Name']),
      'isin': matchColumn(columns, ['ISIN', 'ISIN Code']),
      'quantity': matchColumn(columns, ['Quantity', 'Quantity Available', 'Qty', 'Holdings Quantity', 'Units']),
      'buy_price': matchColumn(columns, ['Buy Average', 'Average Buy Price', 'Average Price', 'Avg Price', 'Buy Price', 'Average Cost']),
      'invested_amount': matchColumn(columns, ['Buy Value', 'Invested Amount', 'Invested Value', 'Total Buy Value', 'Cost Value', 'Average Cost Value']),
      'current_price': matchColumn(columns, ['Current Price', 'LTP', 'Last Price', 'Market Price', 'Closing Price', 'Previous Closing Price', 'CMP']),
      'current_value': matchColumn(columns, ['Current Value', 'Market Value', 'Present Value', 'Valuation', 'Total Value']),
      'purchase_date': matchColumn(columns, ['Purchase Date', 'Buy Date', 'Trade Date']),
      'exchange': matchColumn(columns, ['Exchange', 'Exchange Segment']),
    };

String _title(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

/// `parse_stock_file`. The header row is the first one with a name or ISIN
/// column plus quantity or value (the backend used row 1 only).
Map<String, dynamic> parseStockTable(Table rows, {required String filename, String broker = 'OTHER'}) {
  final nonEmpty = rows.where((r) => r.any((c) => !_isBlank(c))).toList();
  if (nonEmpty.isEmpty) throw const UnreadableFileException('This file is empty.');
  var headerAt = 0;
  for (var i = 0; i < nonEmpty.length && i < 100; i++) {
    final m = detectStockColumnMappings(headerValues(nonEmpty[i]));
    if ((m['name'] != null || m['isin'] != null) && (m['quantity'] != null || m['current_value'] != null || m['invested_amount'] != null)) {
      headerAt = i;
      break;
    }
  }
  final headers = headerValues(nonEmpty[headerAt]);
  final mapping = detectStockColumnMappings(headers);
  final body = nonEmpty.sublist(headerAt + 1);

  Object? cell(List<Object?> row, String role) {
    final i = mapping[role];
    return i == null || i >= row.length ? null : row[i];
  }

  final records = <Map<String, dynamic>>[];
  for (var idx = 0; idx < body.length; idx++) {
    final row = body[idx];
    var name = _isBlank(cell(row, 'name')) ? '' : cellText(cell(row, 'name')).trim();
    final isin = _isBlank(cell(row, 'isin')) ? '' : cellText(cell(row, 'isin')).trim();
    if (name.isEmpty) name = isin.isNotEmpty ? isin : 'Imported holding #${idx + 1}';
    if (const {'total', 'grand total'}.contains(name.toLowerCase())) continue;

    double num(String role, double fallback) => mapping[role] != null && !_isBlank(cell(row, role)) ? cleanAmount(cell(row, role)) : fallback;
    final quantity = num('quantity', 1.0);
    final buyPrice = num('buy_price', 0.0);
    final currentPrice = num('current_price', 0.0);
    var invested = num('invested_amount', buyPrice * quantity);
    var current = num('current_value', currentPrice * quantity);
    if (quantity <= 0 && invested <= 0 && current <= 0) continue;
    if (invested == 0 && buyPrice != 0) invested = buyPrice * quantity;
    if (current == 0 && currentPrice != 0) current = currentPrice * quantity;

    final exchange = _isBlank(cell(row, 'exchange')) ? null : cellText(cell(row, 'exchange')).trim();
    final purchase = mapping['purchase_date'] != null ? parseImportDate(cell(row, 'purchase_date')) : null;
    records.add({
      'row_index': idx,
      'name': name,
      'asset_class': 'EQUITY',
      'sub_type': 'Stock',
      'quantity': (quantity * 1e6).roundToDouble() / 1e6,
      'buy_price': _round2(buyPrice),
      'invested_amount': _round2(invested),
      'current_price': _round2(currentPrice),
      'current_value': _round2(current),
      'purchase_date': purchase == null ? null : isoDate(purchase),
      'notes': 'Imported from ${_title(broker)}${exchange != null ? ' ($exchange)' : ''}',
      'meta_data': {
        'broker': broker,
        'isin': isin,
        'exchange': exchange,
        'raw_data': {for (var i = 0; i < headers.length; i++) headers[i]: i < row.length && !_isBlank(row[i]) ? cellText(row[i]) : null},
      },
    });
  }
  return {
    'success': true,
    'filename': filename,
    'broker': broker,
    'total_rows_found': body.length,
    'parsed_rows_count': records.length,
    'detected_mappings': {for (final e in mapping.entries) e.key: e.value == null ? null : headers[e.value!]},
    'available_columns': headers,
    'preview': records.take(100).toList(),
  };
}

/// `parse_zerodha_holdings_file`: Equity and Mutual Fund sheets of a
/// Zerodha Console workbook.
Map<String, dynamic> parseZerodhaWorkbook(Map<String, Table> sheets, {required String filename}) {
  const headerAliases = {
    'isin', 'quantity', 'qty', 'average price', 'avg price', 'current value', 'invested value', 'scheme name', 'scheme', 'symbol',
    'tradingsymbol', 'instrument',
  };
  final records = <Map<String, dynamic>>[];
  final sheetsUsed = <String>[];
  final seen = <String>{};
  var recognized = 0;

  for (final MapEntry(key: sheetName, value: raw) in sheets.entries) {
    var headerAt = -1;
    for (var i = 0; i < raw.length && i < 100; i++) {
      final values = {for (final v in raw[i]) if (!_isBlank(v)) normalizeHeader(v)};
      final hasQuantity = values.any((v) => v == 'quantity' || v.startsWith('quantity ') || v == 'qty');
      final hasPrice = values.any((v) => const {'average price', 'avg price', 'current value', 'invested value', 'previous closing price', 'closing price'}.contains(v));
      if (values.intersection(headerAliases).length >= 2 && hasQuantity && hasPrice) {
        headerAt = i;
        break;
      }
    }
    if (headerAt < 0) continue;
    final headers = [
      for (var i = 0; i < raw[headerAt].length; i++) _isBlank(raw[headerAt][i]) ? 'column_$i' : cellText(raw[headerAt][i]).trim(),
    ];
    final normalizedSheet = normalizeHeader(sheetName);
    final topText = [for (final r in raw.take(5)) for (final v in r) normalizeHeader(v)];
    final mutual = const {'mf', 'mutual fund', 'mutual funds', 'mutualfunds'}.contains(normalizedSheet) ||
        normalizedSheet.contains('mutual') ||
        topText.any((t) => t.contains('mutual'));
    final assetClass = mutual ? 'MUTUAL_FUND' : 'EQUITY';
    recognized++;

    final m = detectStockColumnMappings(headers);
    final nameCol = m['name'] ?? matchColumn(headers, ['Scheme Name', 'Scheme', 'Fund Name', 'Company', 'Company Name', 'Scrip', 'Instrument Name']);
    final isinCol = m['isin'];
    final qtyCol = m['quantity'];
    final buyCol = m['buy_price'] ?? matchColumn(headers, ['Average Price', 'Avg Buy Price', 'Average Cost']);
    final investedCol = m['invested_amount'] ?? matchColumn(headers, ['Invested Value', 'Investment Value', 'Cost Value']);
    final priceCol = m['current_price'] ?? matchColumn(headers, ['Closing Price', 'Current NAV', 'NAV', 'LTP']);
    final valueCol = m['current_value'] ?? matchColumn(headers, ['Current Value', 'Market Value', 'Present Value']);

    for (var r = headerAt + 1; r < raw.length; r++) {
      final row = raw[r];
      if (row.every(_isBlank)) continue;
      Object? at(int? i) => i == null || i >= row.length ? null : row[i];
      final name = _isBlank(at(nameCol)) ? '' : cellText(at(nameCol)).trim();
      final isin = _isBlank(at(isinCol)) ? '' : cellText(at(isinCol)).trim();
      if (name.isEmpty || const {'total', 'grand total', 'nan'}.contains(name.toLowerCase())) continue;
      double num(int? i, double fallback) => i != null && !_isBlank(at(i)) ? cleanAmount(at(i)) : fallback;
      final quantity = num(qtyCol, 1.0);
      final buyPrice = num(buyCol, 0.0);
      var invested = num(investedCol, buyPrice * quantity);
      final currentPrice = num(priceCol, 0.0);
      var current = num(valueCol, currentPrice * quantity);
      if (current == 0 && currentPrice != 0 && quantity != 0) current = currentPrice * quantity;
      if (invested == 0 && buyPrice != 0 && quantity != 0) invested = buyPrice * quantity;
      if (quantity <= 0 && invested <= 0 && current <= 0) continue;
      final key = isin.isNotEmpty ? isin : name.toLowerCase();
      if (!seen.add(key)) continue;
      records.add({
        'row_index': r,
        'name': name,
        'asset_class': assetClass,
        'sub_type': assetClass == 'MUTUAL_FUND' ? 'Mutual Fund' : 'Stock',
        'quantity': (quantity * 1e6).roundToDouble() / 1e6,
        'buy_price': _round2(buyPrice),
        'invested_amount': _round2(invested),
        'current_price': _round2(currentPrice),
        'current_value': _round2(current),
        'purchase_date': null,
        'notes': 'Imported from Zerodha Console',
        'meta_data': {
          'broker': 'ZERODHA',
          'isin': isin,
          'source_sheet': sheetName,
          'raw_data': {for (var i = 0; i < headers.length; i++) headers[i]: i < row.length && !_isBlank(row[i]) ? cellText(row[i]) : null},
        },
      });
    }
    sheetsUsed.add(sheetName);
  }
  if (records.isEmpty && recognized == 0) {
    throw const UnreadableFileException('No Equity or Mutual Fund holdings were found in the Zerodha workbook.');
  }
  if (records.isEmpty) {
    throw const UnreadableFileException('Zerodha sheets were found, but no holding rows contained quantity and value data.');
  }
  return {
    'success': true,
    'filename': filename,
    'broker': 'ZERODHA',
    'sheets_used': sheetsUsed,
    'total_rows_found': records.length,
    'parsed_rows_count': records.length,
    'preview': records.take(100).toList(),
  };
}
