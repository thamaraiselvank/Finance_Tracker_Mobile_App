/// Reads the cells of CSV and Excel (.xlsx) files on the phone, with no
/// server and no native code: CSV by hand, .xlsx by unzipping it and reading
/// its XML.
///
/// Cell values are `String`, `double` (Excel numbers; dates are Excel serial
/// day numbers, as pandas sees them with `header=None`) or `bool`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A file the importer can't read, with a message for the user.
class UnreadableFileException implements Exception {
  const UnreadableFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef Table = List<List<Object?>>;

/// Decodes [bytes] as UTF-8 (BOM removed), falling back to Latin-1 for old
/// bank exports.
String decodeText(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('﻿') ? text.substring(1) : text;
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Parses CSV text (RFC 4180 quotes). The separator is the one of `,` `;`
/// tab that splits the first lines most consistently; comma wins ties, as
/// pandas tries `,` first.
Table readCsv(String text) {
  final separator = _guessSeparator(text);
  final rows = <List<Object?>>[];
  var row = <Object?>[];
  final cell = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == separator) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <Object?>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

String _guessSeparator(String text) {
  final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty).take(20).toList();
  if (lines.isEmpty) return ',';
  var best = ',';
  var bestScore = 0;
  for (final sep in const [',', ';', '\t']) {
    final counts = lines.map((l) => _countOutsideQuotes(l, sep)).toList();
    // Lines with the most common non-zero count.
    final freq = <int, int>{};
    for (final c in counts) {
      if (c > 0) freq[c] = (freq[c] ?? 0) + 1;
    }
    if (freq.isEmpty) continue;
    final score = freq.values.reduce((a, b) => a > b ? a : b);
    if (score > bestScore) {
      best = sep;
      bestScore = score;
    }
  }
  return best;
}

int _countOutsideQuotes(String line, String sep) {
  var n = 0;
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '"') quoted = !quoted;
    if (!quoted && line[i] == sep) n++;
  }
  return n;
}

/// Some banks' ".xls" downloads are really web pages with a table. Reads the
/// rows of every table in [html], one after another.
Table readHtmlTable(String html) {
  String clean(String cell) => cell
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return [
    for (final tr in RegExp(r'<tr\b[^>]*>(.*?)</tr>', caseSensitive: false, dotAll: true).allMatches(html))
      [for (final td in RegExp(r'<t[dh]\b[^>]*>(.*?)</t[dh]>', caseSensitive: false, dotAll: true).allMatches(tr[1]!)) clean(td[1]!)],
  ];
}

/// What an uploaded "spreadsheet" really is.
enum SheetFormat { xlsx, oldXls, html, text }

SheetFormat sniffSheet(Uint8List bytes) {
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) return SheetFormat.xlsx;
  if (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) return SheetFormat.oldXls;
  final head = decodeText(bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes).toLowerCase();
  if (head.contains('<table') || head.contains('<html')) return SheetFormat.html;
  return SheetFormat.text;
}

/// The sheets of a CSV / Excel / HTML-table file. CSV and HTML files have a
/// single sheet.
Map<String, Table> readSheets(Uint8List bytes) => switch (sniffSheet(bytes)) {
      SheetFormat.xlsx => readXlsx(bytes),
      SheetFormat.oldXls => throw const UnreadableFileException(
          'Old Excel 97-2003 (.xls) files can’t be read on the phone. Open it in Excel or Google Sheets, save it as .xlsx or CSV, and import that.'),
      SheetFormat.html => {'Sheet1': readHtmlTable(decodeText(bytes))},
      SheetFormat.text => {'Sheet1': readCsv(decodeText(bytes))},
    };

/// Reads every sheet of an .xlsx workbook, in workbook order.
Map<String, Table> readXlsx(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const UnreadableFileException('This Excel file could not be opened. Save it again as .xlsx or CSV and try again.');
  }
  XmlDocument? xml(String path) {
    final file = zip.findFile(path);
    if (file == null) return null;
    return XmlDocument.parse(decodeText(file.content));
  }

  final workbook = xml('xl/workbook.xml');
  if (workbook == null) {
    throw const UnreadableFileException('This Excel file could not be opened. Save it again as .xlsx or CSV and try again.');
  }
  final shared = <String>[
    for (final si in xml('xl/sharedStrings.xml')?.findAllElements('si') ?? const <XmlElement>[])
      si.findAllElements('t').map((t) => t.innerText).join(),
  ];
  final targets = <String, String>{
    for (final rel in xml('xl/_rels/workbook.xml.rels')?.findAllElements('Relationship') ?? const <XmlElement>[])
      rel.getAttribute('Id')!: rel.getAttribute('Target')!,
  };

  final sheets = <String, Table>{};
  var index = 0;
  for (final sheet in workbook.findAllElements('sheet')) {
    index++;
    final name = sheet.getAttribute('name') ?? 'Sheet$index';
    final relId = sheet.attributes.where((a) => a.name.local == 'id').firstOrNull?.value;
    var target = targets[relId] ?? 'worksheets/sheet$index.xml';
    target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    final doc = xml(target);
    if (doc == null) continue;
    sheets[name] = _readSheet(doc, shared);
  }
  return sheets;
}

Table _readSheet(XmlDocument doc, List<String> shared) {
  final rows = <List<Object?>>[];
  for (final row in doc.findAllElements('row')) {
    final rowNumber = int.tryParse(row.getAttribute('r') ?? '') ?? rows.length + 1;
    while (rows.length < rowNumber - 1) {
      rows.add(<Object?>[]);
    }
    final cells = <Object?>[];
    for (final c in row.findElements('c')) {
      final ref = c.getAttribute('r');
      final col = ref == null ? cells.length : _columnIndex(ref);
      while (cells.length < col) {
        cells.add(null);
      }
      cells.add(_cellValue(c, shared));
    }
    rows.add(cells);
  }
  return rows;
}

int _columnIndex(String ref) {
  var n = 0;
  for (final unit in ref.codeUnits) {
    if (unit < 65 || unit > 90) break;
    n = n * 26 + (unit - 64);
  }
  return n - 1;
}

Object? _cellValue(XmlElement c, List<String> shared) {
  final type = c.getAttribute('t');
  final v = c.getElement('v')?.innerText;
  switch (type) {
    case 's':
      final i = int.tryParse(v ?? '');
      return i != null && i < shared.length ? shared[i] : null;
    case 'inlineStr':
      return c.findAllElements('t').map((t) => t.innerText).join();
    case 'str':
      return v;
    case 'b':
      return v == '1';
    case 'e':
      return null;
    default:
      if (v == null || v.isEmpty) return null;
      return double.tryParse(v) ?? v;
  }
}
