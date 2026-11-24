/// Turns [ExportTable]s into files: Excel (.xlsx), CSV and PDF.
///
/// Everything happens on the phone; nothing is sent anywhere.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import 'export_data.dart';

enum ExportFormat {
  xlsx('Excel', 'xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
  csv('CSV', 'csv', 'text/csv'),
  pdf('PDF', 'pdf', 'application/pdf');

  const ExportFormat(this.label, this.extension, this.mimeType);
  final String label;
  final String extension;
  final String mimeType;
}

class ExportFile {
  const ExportFile(this.name, this.bytes, this.mimeType);
  final String name;
  final Uint8List bytes;
  final String mimeType;
}

/// Fonts for the PDF report (Roboto, bundled: it has the ₹ sign).
class ReportFonts {
  const ReportFonts(this.regular, this.bold);
  final ByteData regular;
  final ByteData bold;
}

/// Builds the export file. Several CSV tables come as one .zip.
Future<ExportFile> buildExportFile(
  List<ExportTable> tables,
  ExportFormat format, {
  required String currency,
  required DateTime now,
  String? ownerName,
  ReportFonts? fonts,
}) async {
  final date = _iso(now);
  final base = tables.length == 1 ? 'finverse-${_slug(tables.single.title)}-$date' : 'finverse-export-$date';
  switch (format) {
    case ExportFormat.xlsx:
      return ExportFile('$base.xlsx', buildXlsx(tables, currency: currency), format.mimeType);
    case ExportFormat.pdf:
      if (fonts == null) throw ArgumentError('fonts are needed for PDF');
      final name = tables.length == 1 ? base : 'finverse-report-$date';
      return ExportFile('$name.pdf', await buildPdf(tables, currency: currency, now: now, ownerName: ownerName, fonts: fonts), format.mimeType);
    case ExportFormat.csv:
      if (tables.length == 1) return ExportFile('$base.csv', buildCsv(tables.single), format.mimeType);
      final zip = Archive();
      for (final t in tables) {
        final bytes = buildCsv(t);
        zip.addFile(ArchiveFile('finverse-${_slug(t.title)}-$date.csv', bytes.length, bytes));
      }
      return ExportFile('$base-csv.zip', Uint8List.fromList(ZipEncoder().encode(zip)), 'application/zip');
  }
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _slug(String title) => title.toLowerCase().replaceAll('&', 'and').replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

/// One table as CSV: a header row, then data. UTF-8 with a byte-order mark so
/// Excel shows ₹ and other symbols correctly. Numbers are plain (no grouping),
/// dates are YYYY-MM-DD.
Uint8List buildCsv(ExportTable table) {
  String cell(Object? v, CellKind kind) {
    if (v == null) return '';
    final text = switch (kind) {
      CellKind.money || CellKind.percent => v is num ? v.toStringAsFixed(2) : '$v',
      CellKind.number => v is double && v == v.roundToDouble() ? v.toInt().toString() : '$v',
      _ => '$v',
    };
    // Quote when needed; a leading = + - @ would make spreadsheets run it as a formula.
    final safe = kind == CellKind.text && RegExp(r'^[=+\-@\t\r]').hasMatch(text) ? "'$text" : text;
    return RegExp(r'[",\r\n]').hasMatch(safe) ? '"${safe.replaceAll('"', '""')}"' : safe;
  }

  final out = StringBuffer('﻿');
  out.write(table.columns.map((c) => cell(c.title, CellKind.text)).join(','));
  out.write('\r\n');
  for (final row in table.rows) {
    out.write([for (var i = 0; i < table.columns.length; i++) cell(row[i], table.columns[i].kind)].join(','));
    out.write('\r\n');
  }
  return Uint8List.fromList(utf8.encode(out.toString()));
}

// ---------------------------------------------------------------------------
// Excel (.xlsx)
// ---------------------------------------------------------------------------

/// A workbook with one sheet per table: bold frozen header row with filters,
/// real numbers and dates (so sums and sorting work), and totals underneath.
Uint8List buildXlsx(List<ExportTable> tables, {required String currency}) {
  final zip = Archive();
  void add(String path, String xml) {
    final bytes = utf8.encode(xml);
    zip.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  final names = _sheetNames(tables.map((t) => t.title).toList());
  add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${[for (var i = 1; i <= tables.length; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join('\n')}
</Types>''');
  add('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''');
  add('xl/workbook.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>${[for (var i = 0; i < tables.length; i++) '<sheet name="${_xml(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets>
<definedNames>${[for (var i = 0; i < tables.length; i++)
    if (tables[i].rows.isNotEmpty) '<definedName name="_xlnm._FilterDatabase" localSheetId="$i" hidden="1">\'${_xml(names[i].replaceAll("'", "''"))}\'!\$A\$1:\$${_col(tables[i].columns.length - 1)}\$${tables[i].rows.length + 1}</definedName>'].join()}</definedNames>
</workbook>''');
  add('xl/_rels/workbook.xml.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${[for (var i = 1; i <= tables.length; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join('\n')}
<Relationship Id="rId${tables.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''');
  add('xl/styles.xml', _styles(currency));
  for (var i = 0; i < tables.length; i++) {
    add('xl/worksheets/sheet${i + 1}.xml', _sheet(tables[i]));
  }
  return Uint8List.fromList(ZipEncoder().encode(zip));
}

// Cell style indexes in styles.xml (cellXfs).
const _sText = 0, _sHeader = 1, _sMoney = 2, _sDate = 3, _sPercent = 4, _sNumber = 5, _sBold = 6, _sBoldMoney = 7;

String _styles(String currency) {
  // Indian grouping (1,23,45,678.00) for rupees, 1,234,567.00 otherwise.
  final money = currency == 'INR' ? r'[&gt;=10000000]##\,##\,##\,##0.00;[&gt;=100000]##\,##\,##0.00;##,##0.00' : '#,##0.00';
  return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="4"><numFmt numFmtId="164" formatCode="$money"/><numFmt numFmtId="165" formatCode="dd\\-mmm\\-yyyy"/><numFmt numFmtId="166" formatCode="0.00&quot;%&quot;"/><numFmt numFmtId="167" formatCode="#,##0.####"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD1FAE5"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="8">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyNumberFormat="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>''';
}

String _sheet(ExportTable t) {
  final out = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
  );
  out.write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>');
  out.write('<cols>');
  for (var i = 0; i < t.columns.length; i++) {
    out.write('<col min="${i + 1}" max="${i + 1}" width="${t.columns[i].width}" customWidth="1"/>');
  }
  out.write('</cols><sheetData>');
  var r = 1;
  out.write('<row r="$r">');
  for (var i = 0; i < t.columns.length; i++) {
    out.write(_textCell('${_col(i)}$r', t.columns[i].title, _sHeader));
  }
  out.write('</row>');
  for (final row in t.rows) {
    r++;
    out.write('<row r="$r">');
    for (var i = 0; i < t.columns.length; i++) {
      out.write(_cell('${_col(i)}$r', row[i], t.columns[i].kind));
    }
    out.write('</row>');
  }
  if (t.totals.isNotEmpty) {
    r++; // blank line
    for (final (label, value, kind) in t.totals) {
      r++;
      out.write('<row r="$r">${_textCell('A$r', label, _sBold)}');
      out.write(kind == CellKind.money && value is num ? _numCell('B$r', value, _sBoldMoney) : _cell('B$r', value, kind));
      out.write('</row>');
    }
  }
  out.write('</sheetData>');
  if (t.rows.isNotEmpty) out.write('<autoFilter ref="A1:${_col(t.columns.length - 1)}${t.rows.length + 1}"/>');
  out.write('</worksheet>');
  return out.toString();
}

String _cell(String ref, Object? v, CellKind kind) {
  if (v == null || (v is String && v.isEmpty)) return '';
  switch (kind) {
    case CellKind.money:
      return v is num ? _numCell(ref, v, _sMoney) : _textCell(ref, '$v', _sText);
    case CellKind.percent:
      return v is num ? _numCell(ref, v, _sPercent) : _textCell(ref, '$v', _sText);
    case CellKind.number:
      return v is num ? _numCell(ref, v, _sNumber) : _textCell(ref, '$v', _sText);
    case CellKind.date:
      final d = DateTime.tryParse('$v');
      if (d == null) return _textCell(ref, '$v', _sText);
      final serial = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(1899, 12, 30)).inDays;
      return _numCell(ref, serial, _sDate);
    case CellKind.text:
      return _textCell(ref, '$v', _sText);
  }
}

String _numCell(String ref, num v, int style) => v.isFinite ? '<c r="$ref" s="$style"><v>$v</v></c>' : '';

String _textCell(String ref, String text, int style) =>
    '<c r="$ref" t="inlineStr"${style == 0 ? '' : ' s="$style"'}><is><t xml:space="preserve">${_xml(text)}</t></is></c>';

/// 0 -> A, 25 -> Z, 26 -> AA.
String _col(int index) {
  var n = index + 1;
  final out = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    out.write(String.fromCharCode(65 + rem));
    n = (n - 1) ~/ 26;
  }
  return out.toString().split('').reversed.join();
}

String _xml(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Excel sheet names: at most 31 characters, none of : \ / ? * [ ], unique.
List<String> _sheetNames(List<String> titles) {
  final used = <String>{};
  return [
    for (final t in titles)
      () {
        var name = t.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ');
        if (name.length > 31) name = name.substring(0, 31);
        var unique = name;
        for (var i = 2; used.contains(unique.toLowerCase()); i++) {
          unique = '${name.substring(0, name.length.clamp(0, 28))} $i';
        }
        used.add(unique.toLowerCase());
        return unique;
      }(),
  ];
}

// ---------------------------------------------------------------------------
// PDF
// ---------------------------------------------------------------------------

/// A printable report: a title, then each table with its totals. Wide tables
/// keep only their main columns ([ExportColumn.inPdf]).
Future<Uint8List> buildPdf(List<ExportTable> tables, {required String currency, required DateTime now, required ReportFonts fonts, String? ownerName}) {
  final money = Money(currency);
  final green = PdfColor.fromHex('#047857');
  final grey = PdfColor.fromHex('#6B7280');
  final doc = pw.Document(title: 'Finverse report', author: 'Finverse', creator: 'Finverse');
  final theme = pw.ThemeData.withFont(base: pw.Font.ttf(fonts.regular), bold: pw.Font.ttf(fonts.bold));

  String show(Object? v, CellKind kind) {
    if (v == null || (v is String && v.isEmpty)) return '';
    return switch (kind) {
      CellKind.money => v is num ? money.exact(v) : '$v',
      CellKind.percent => v is num ? '${v.toStringAsFixed(2)}%' : '$v',
      CellKind.number => v is double && v == v.roundToDouble() ? v.toInt().toString() : '$v',
      CellKind.date => DateTime.tryParse('$v') == null ? '$v' : displayDate(DateTime.parse('$v')),
      CellKind.text => '$v',
    };
  }

  bool rightAligned(CellKind k) => k == CellKind.money || k == CellKind.number || k == CellKind.percent;

  pw.Widget table(ExportTable t) {
    final cols = [
      for (var i = 0; i < t.columns.length; i++)
        if (t.columns[i].inPdf) i,
    ];
    if (t.rows.isEmpty) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 6),
        child: pw.Text('Nothing to show.', style: pw.TextStyle(color: grey)),
      );
    }
    return pw.TableHelper.fromTextArray(
      headers: [for (final i in cols) t.columns[i].title],
      data: [
        for (final row in t.rows) [for (final i in cols) show(row[i], t.columns[i].kind)],
      ],
      headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8, color: PdfColors.white),
      headerDecoration: pw.BoxDecoration(color: green),
      cellStyle: const pw.TextStyle(fontSize: 8),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColor(0.96, 0.97, 0.97)),
      border: null,
      columnWidths: {for (var j = 0; j < cols.length; j++) j: pw.FlexColumnWidth(t.columns[cols[j]].width)},
      headerAlignments: {for (var j = 0; j < cols.length; j++) j: rightAligned(t.columns[cols[j]].kind) ? pw.Alignment.centerRight : pw.Alignment.centerLeft},
      cellAlignments: {for (var j = 0; j < cols.length; j++) j: rightAligned(t.columns[cols[j]].kind) ? pw.Alignment.centerRight : pw.Alignment.centerLeft},
    );
  }

  pw.Widget totals(ExportTable t) => pw.Container(
    margin: const pw.EdgeInsets.only(top: 6),
    alignment: pw.Alignment.centerRight,
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        for (final (label, value, kind) in t.totals)
          pw.Row(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Text('$label   ', style: pw.TextStyle(fontSize: 9, color: grey)),
              pw.SizedBox(
                width: 110,
                child: pw.Text(
                  show(value, kind),
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
                ),
              ),
            ],
          ),
      ],
    ),
  );

  doc.addPage(
    pw.MultiPage(
      theme: theme,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 32),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Made with Finverse on ${displayDate(now)}', style: pw.TextStyle(fontSize: 7, color: grey)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: grey)),
        ],
      ),
      build: (ctx) => [
        pw.Text(
          'Finverse report',
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: green),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          [if (ownerName != null && ownerName.trim().isNotEmpty) ownerName.trim(), 'Prepared ${displayDate(now)}'].join(' · '),
          style: pw.TextStyle(fontSize: 10, color: grey),
        ),
        pw.SizedBox(height: 10),
        for (final t in tables) ...[
          pw.SizedBox(height: 10),
          pw.Text(t.title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          if (t.subtitle != null) pw.Text(t.subtitle!, style: pw.TextStyle(fontSize: 9, color: grey)),
          pw.SizedBox(height: 4),
          table(t),
          if (t.totals.isNotEmpty) totals(t),
        ],
      ],
    ),
  );
  return doc.save();
}
