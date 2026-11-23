/// Reads a statement table from words and their positions on a page: the
/// text of a typed PDF (from PDFium) or the words OCR found on a scanned
/// page (ML Kit). Positions are in pixels at 200 dpi, like the backend's
/// Tesseract pass, so its thresholds carry over.
///
/// Port of `_group_ocr_words`, `_ocr_header_columns`,
/// `_find_ocr_statement_header`, `_ocr_cell_text`, `_ocr_cell_amount` and
/// `_parse_ocr_statement_data` from backend/app/services/importer.py, with
/// these changes for typed PDFs: two-word headers ("Value Date", "Withdrawal
/// Amt.", "Closing Balance") are read as one, the header is looked for in
/// the first 60 lines (not 12), more date styles are accepted
/// ("15-Nov-2026"), page footers or lines far from any row are not glued
/// onto a transaction's description, a "Cr" / "Dr" after an amount sets its
/// direction, and one-word narrations with a real name in them
/// ("UPI-SWIGGY-...-Payment") are not flagged as reference numbers.
library;

import 'statement_parser.dart';

/// One word on a page. [confidence] is 0-100, or -1 when unknown.
class PageWord {
  const PageWord(this.text, {required this.left, required this.top, required this.width, required this.height, this.confidence = 100});

  final String text;
  final double left, top, width, height, confidence;
  double get center => left + width / 2;
  double get right => left + width;

  @override
  String toString() => 'PageWord($text @ $left,$top)';
}

typedef Columns = Map<String, double>;

/// `_group_ocr_words`: words whose top is within 10 px of the line's first
/// word form a line, sorted left to right.
List<List<PageWord>> groupLines(Iterable<PageWord> words) {
  final sorted = words.where((w) => w.text.trim().isNotEmpty).toList()
    ..sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
  final lines = <List<PageWord>>[];
  double? lineTop;
  for (final w in sorted) {
    if (lines.isEmpty || w.top - lineTop! > 10) {
      lines.add([w]);
      lineTop = w.top;
    } else {
      lines.last.add(w);
    }
  }
  for (final l in lines) {
    l.sort((a, b) => a.left.compareTo(b.left));
  }
  return lines;
}

const _roles = <String, Set<String>>{
  'date': {'date', 'txn', 'transaction', 'transactiondate', 'txndate', 'trandate', 'postingdate', 'postdate', 'trxndate'},
  'value_date': {'valuedt', 'valuedate'},
  'description': {
    'particular', 'particulars', 'narration', 'description', 'details', 'remarks', 'merchant', 'payee', 'transactionparticulars',
    'transactionnarration', 'transactiondetails', 'transactionremarks',
  },
  'reference': {'ref', 'reference', 'cheque', 'chequeno', 'chq', 'chqno', 'refno', 'chequeref', 'chequerefno', 'chqrefno'},
  'debit': {'debit', 'withdrawal', 'withdrawals', 'dr', 'debitamount'},
  'credit': {'credit', 'deposit', 'deposits', 'cr', 'creditamount'},
  'amount': {'amount', 'transactionamount', 'txnamount'},
  'balance': {'balance', 'closingbalance', 'runningbalance', 'availablebalance'},
};

String? _roleOf(String normalized) {
  if (normalized.isEmpty) return null;
  for (final MapEntry(key: role, value: labels) in _roles.entries) {
    if (labels.contains(normalized) ||
        (role == 'debit' && normalized.startsWith('withdrawal')) ||
        (role == 'credit' && normalized.startsWith('deposit')) ||
        (role == 'balance' && normalized.endsWith('balance'))) {
      return role;
    }
  }
  return null;
}

String _squash(String text) => normalizeHeader(text).replaceAll(' ', '');

/// `_ocr_header_columns`: the x centre of each column heading found.
Columns headerColumns(List<PageWord> words) {
  final positions = <String, List<double>>{};
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (i + 1 < words.length) {
      final next = words[i + 1];
      final sameLine = (next.top - w.top).abs() <= 10;
      final close = next.left - w.right < w.height * 0.8;
      final pairRole = sameLine && close ? _roleOf(_squash(w.text) + _squash(next.text)) : null;
      if (pairRole != null) {
        positions.putIfAbsent(pairRole, () => []).add((w.left + next.right) / 2);
        i++;
        continue;
      }
    }
    final role = _roleOf(_squash(w.text));
    if (role != null) positions.putIfAbsent(role, () => []).add(w.center);
  }
  return {for (final e in positions.entries) e.key: e.value.reduce((a, b) => a + b) / e.value.length};
}

bool _isTableHeader(Columns c) =>
    c.containsKey('date') && c.containsKey('description') && (c.containsKey('debit') || c.containsKey('credit') || c.containsKey('amount'));

/// `_find_ocr_statement_header`: index of the header's last line and its
/// columns, or (null, {}).
(int?, Columns) findHeader(List<List<PageWord>> lines, {int searchLines = 60}) {
  for (var i = 0; i < lines.length && i < searchLines; i++) {
    for (var size = 1; size <= 4; size++) {
      final end = i + size < lines.length ? i + size : lines.length;
      // Words of a multi-line header, in reading order per line.
      final words = [for (final l in lines.sublist(i, end)) ...l];
      final columns = headerColumns(words);
      if (_isTableHeader(columns)) return (end - 1, columns);
    }
  }
  return (null, {});
}

/// `_ocr_cell_text`: words between the midpoints to the neighbouring columns.
String cellTextAt(List<PageWord> words, String role, Columns columns) {
  final ordered = columns.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
  final index = ordered.indexWhere((e) => e.key == role);
  if (index < 0) return '';
  final center = ordered[index].value;
  final left = index > 0 ? (ordered[index - 1].value + center) / 2 : double.negativeInfinity;
  final right = index + 1 < ordered.length ? (center + ordered[index + 1].value) / 2 : double.infinity;
  return words.where((w) => left <= w.center && w.center < right).map((w) => w.text).join(' ').trim();
}

/// `_ocr_cell_amount`: 0 for an empty cell, null if it isn't a number.
double? cellAmount(String value) {
  var cleaned = value.replaceAll(RegExp(r'\b(?:INR|RS\.?)\b', caseSensitive: false), '');
  cleaned = cleaned.replaceAll('₹', '').replaceAll(',', '').replaceAll(' ', '');
  // A trailing Cr / Dr marker in the balance column ("12,345.00 Cr").
  cleaned = cleaned.replaceAll(RegExp(r'(?:cr|dr)\.?$', caseSensitive: false), '');
  if (cleaned.isEmpty || cleaned == '-' || cleaned == '—') return 0.0;
  if (!RegExp(r'^\(?-?\d+(?:\.\d{1,2})?\)?$').hasMatch(cleaned)) return null;
  return cleanAmount(cleaned);
}

final _datePattern = RegExp(
  r'(?<!\d)(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}|\d{1,2}[\s-][A-Za-z]{3,9}[\s-,]+\d{2,4})(?!\d)',
);
final _openingBalance = RegExp(r'\bopening\s+balance\b', caseSensitive: false);
final _pageNoise = RegExp(
  r'\bpage\s*\d+(\s*of\s*\d+)?\b|computer[- ]generated|system[- ]generated|does not require (a )?signature|end of statement|'
  r'^\s*(closing|opening)\s+balance\b|statement summary|^\s*\*+',
  caseSensitive: false,
);

/// Lines further than this from a transaction's date line (about four lines
/// of text at 200 dpi) don't belong to it.
const _maxRowSpan = 70.0;

/// `_parse_ocr_statement_data` for one page. [inherited] are the columns
/// found on an earlier page, for pages without their own header.
List<Map<String, dynamic>> parseLayoutPage(List<List<PageWord>> lines, {Columns? inherited, bool fromOcr = false}) {
  final (headerEnd, detected) = findHeader(lines, searchLines: fromOcr ? 12 : 60);
  final columns = detected.isNotEmpty ? detected : (inherited ?? const {});
  if (columns.isEmpty) return [];
  final bodyStart = (headerEnd ?? -1) + 1;
  final body = [for (var i = bodyStart; i < lines.length; i++) (i, lines[i])];
  bool hasAmount(List<PageWord> l) =>
      const ['debit', 'credit', 'amount'].any((r) => columns.containsKey(r) && cellTextAt(l, r, columns).isNotEmpty);
  String lineText(List<PageWord> l) => l.map((w) => w.text).join(' ');

  final anchors = <({int row, String date, double top, List<List<PageWord>> lines})>[];
  for (final (n, l) in body) {
    final m = _datePattern.firstMatch(cellTextAt(l, 'date', columns));
    if (m != null) anchors.add((row: n, date: m[0]!, top: l.first.top, lines: []));
  }

  final groups = <({int row, String? date, List<List<PageWord>> lines})>[];
  if (anchors.isNotEmpty) {
    var nearest = 0;
    for (final (_, l) in body) {
      final description = cellTextAt(l, 'description', columns);
      final hasDate = _datePattern.hasMatch(cellTextAt(l, 'date', columns));
      final top = l.first.top;
      if (!hasDate && !hasAmount(l) && (_openingBalance.hasMatch(description) || _pageNoise.hasMatch(lineText(l)))) continue;
      while (nearest + 1 < anchors.length && (top - anchors[nearest + 1].top).abs() < (top - anchors[nearest].top).abs()) {
        nearest++;
      }
      if (!hasDate && (top - anchors[nearest].top).abs() > _maxRowSpan) continue;
      anchors[nearest].lines.add(l);
    }
    for (final a in anchors) {
      groups.add((row: a.row, date: a.date, lines: a.lines));
    }
  } else {
    var prefix = <List<PageWord>>[];
    List<List<PageWord>>? active;
    for (final (n, l) in body) {
      final description = cellTextAt(l, 'description', columns);
      final amountHere = hasAmount(l);
      if (_openingBalance.hasMatch(description) && !amountHere) {
        prefix = [];
        continue;
      }
      if (amountHere && (description.isNotEmpty || prefix.isNotEmpty)) {
        active = [...prefix, l];
        groups.add((row: n, date: null, lines: active));
        prefix = [];
      } else if (active != null) {
        active.add(l);
      } else {
        prefix.add(l);
      }
    }
  }

  final records = <Map<String, dynamic>>[];
  for (final g in groups) {
    final words = [for (final l in g.lines) ...l];
    final rowDate = parseImportDate(g.date);
    var description = cellTextAt(words, 'description', columns).replaceAll(RegExp(r'\s+'), ' ');
    description = description.replaceAll(RegExp(r'^[ :\-|]+|[ :\-|]+$'), '');
    if (description.isEmpty) continue;

    final debitText = cellTextAt(words, 'debit', columns);
    final creditText = cellTextAt(words, 'credit', columns);
    final amountText = cellTextAt(words, 'amount', columns);
    final balanceText = cellTextAt(words, 'balance', columns);
    final debit = columns.containsKey('debit') ? cellAmount(debitText) : 0.0;
    final credit = columns.containsKey('credit') ? cellAmount(creditText) : 0.0;
    final generic = amountText.isNotEmpty ? cellAmount(amountText) : 0.0;
    // "1,234.00 Dr" / "Cr" in a single amount column.
    String? marked;
    if (amountText.isNotEmpty && generic != null && generic > 0) {
      if (RegExp(r'\bdr\.?$', caseSensitive: false).hasMatch(amountText.trim())) marked = 'EXPENSE';
      if (RegExp(r'\bcr\.?$', caseSensitive: false).hasMatch(amountText.trim())) marked = 'INCOME';
    }
    final balance = balanceText.isNotEmpty ? cellAmount(balanceText) : null;

    String? type;
    var amount = 0.0;
    if (debit != null && debit > 0 && credit == 0) {
      (type, amount) = ('EXPENSE', debit);
    } else if (credit != null && credit > 0 && debit == 0) {
      (type, amount) = ('INCOME', credit);
    } else if (generic != null && generic != 0) {
      amount = generic.abs();
      if (generic < 0) type = 'EXPENSE';
      type ??= marked;
    } else if (debit != null && credit != null) {
      amount = debit + credit;
    }

    final confidences = [for (final w in words) if (w.confidence >= 0) w.confidence];
    final lowConfidence = confidences.isEmpty || confidences.reduce((a, b) => a + b) / confidences.length < 65;
    // Only a reference number, no name: the description was probably read
    // from the wrong column. (The backend also flagged one-word narrations
    // such as "UPI-SWIGGY-...-Payment", which typed PDFs are full of.)
    final referenceLike = RegExp(r'^[A-Za-z0-9/-]{10,}$').hasMatch(description) && !RegExp(r'[A-Za-z]{4,}').hasMatch(description);
    records.add({
      'row_index': g.row,
      'date': rowDate == null ? null : isoDate(rowDate),
      'time': null,
      'description': description.length > 255 ? description.substring(0, 255) : description,
      'amount': (amount * 100).roundToDouble() / 100,
      'type': type,
      'category': null,
      'subcategory': null,
      'needs_review': rowDate == null || type == null || amount <= 0 || lowConfidence || referenceLike,
      'raw_data': {'ocr_line': words.map((w) => w.text).join(' '), 'balance': balance},
    });
  }
  return records;
}

/// Reads all pages: each page uses its own header, or the last one seen.
List<Map<String, dynamic>> parseLayoutPages(List<({List<PageWord> words, bool ocr})> pages) {
  final records = <Map<String, dynamic>>[];
  Columns? columns;
  for (final page in pages) {
    final lines = groupLines(page.words);
    final (_, found) = findHeader(lines, searchLines: page.ocr ? 12 : 60);
    if (found.isNotEmpty) columns = found;
    records.addAll(parseLayoutPage(lines, inherited: columns, fromOcr: page.ocr));
  }
  reconcileBalanceDirections(records);
  return records;
}

const _bankNames = [
  'State Bank of India', 'HDFC Bank', 'ICICI Bank', 'Axis Bank', 'Kotak Mahindra Bank', 'Punjab National Bank', 'Bank of Baroda',
  'Canara Bank', 'Union Bank of India', 'IDFC FIRST Bank', 'Yes Bank', 'IndusInd Bank', 'Federal Bank', 'Indian Bank', 'Bank of India',
  'AU Small Finance Bank', 'RBL Bank', 'South Indian Bank', 'Karur Vysya Bank', 'City Union Bank', 'Indian Overseas Bank',
];

/// The bank named in the statement's first pages, if any.
String? detectBank(String text) {
  final lower = text.toLowerCase();
  for (final bank in _bankNames) {
    if (lower.contains(bank.toLowerCase())) return bank;
  }
  return null;
}
