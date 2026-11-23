/// Reads the words of a PDF statement on the phone.
///
/// Typed PDFs (almost all bank e-statements): text and positions come from
/// PDFium (pdfrx). Scanned pages with no text are drawn at 200 dpi and read
/// with Google ML Kit's offline text recognition. Nothing leaves the phone;
/// the password is used only to open the file and is not stored.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'layout_parser.dart';
import 'table_reader.dart';

typedef PdfPageWords = ({List<PageWord> words, bool ocr});

/// The words of each page, plus the text of the first pages (to tell which
/// bank the statement is from).
class PdfWords {
  const PdfWords(this.pages, this.firstPagesText);
  final List<PdfPageWords> pages;
  final String firstPagesText;
}

/// Turns PDF bytes into positioned words. A fake is used in tests.
abstract class StatementPdfReader {
  Future<PdfWords> read(Uint8List bytes, {String? password});
}

const maxPdfPages = 200;
const maxOcrPages = 20;

/// Positions are converted from PDF points (1/72 inch) to pixels at 200 dpi.
const _scale = 200 / 72;

class PdfiumStatementReader implements StatementPdfReader {
  const PdfiumStatementReader();

  @override
  Future<PdfWords> read(Uint8List bytes, {String? password}) async {
    await pdfrxFlutterInitialize();
    final PdfDocument doc;
    try {
      doc = await PdfDocument.openData(bytes, passwordProvider: createSimplePasswordProvider(password));
    } on PdfPasswordException {
      throw UnreadableFileException(password == null || password.isEmpty
          ? 'This PDF is locked. Enter its password and try again (banks often use part of your name, date of birth or customer ID).'
          : 'That password did not open the PDF. Check it and try again.');
    } catch (_) {
      throw const UnreadableFileException('Could not read this PDF. It may be damaged; try downloading the statement again.');
    }
    try {
      if (doc.pages.length > maxPdfPages) {
        throw const UnreadableFileException('This PDF has more than $maxPdfPages pages. Please split it into smaller statements.');
      }
      final pages = <PdfPageWords>[];
      final firstText = StringBuffer();
      var ocrPages = 0;
      TextRecognizer? recognizer;
      try {
        for (final (i, page) in doc.pages.indexed) {
          final raw = await page.loadText();
          final words = raw == null ? <PageWord>[] : wordsFromChars(raw.fullText, raw.charRects, page.height);
          final textChars = words.fold<int>(0, (n, w) => n + w.text.length);
          if (textChars >= 40) {
            pages.add((words: words, ocr: false));
            if (i < 2) firstText.writeln(raw!.fullText);
            continue;
          }
          if (ocrPages >= maxOcrPages) {
            throw const UnreadableFileException(
                'This statement needs text recognition on more than $maxOcrPages scanned pages. Please split it into smaller files.');
          }
          ocrPages++;
          recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
          final ocrWords = await _ocrPage(page, recognizer);
          pages.add((words: ocrWords, ocr: true));
          if (i < 2) firstText.writeln(ocrWords.map((w) => w.text).join(' '));
        }
      } finally {
        await recognizer?.close();
      }
      return PdfWords(pages, firstText.toString());
    } finally {
      await doc.dispose();
    }
  }

  Future<List<PageWord>> _ocrPage(PdfPage page, TextRecognizer recognizer) async {
    final width = (page.width * _scale).round(), height = (page.height * _scale).round();
    final image = await page.render(fullWidth: width.toDouble(), fullHeight: height.toDouble(), width: width, height: height, backgroundColor: 0xFFFFFFFF);
    if (image == null) return [];
    final Uint8List png;
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(image.pixels, image.width, image.height, ui.PixelFormat.bgra8888, completer.complete);
      final decoded = await completer.future;
      png = (await decoded.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      decoded.dispose();
    } finally {
      image.dispose();
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/finverse_statement_page_${DateTime.now().microsecondsSinceEpoch}.png');
    await file.writeAsBytes(png, flush: true);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
      return [
        for (final block in result.blocks)
          for (final line in block.lines)
            for (final e in line.elements)
              PageWord(
                e.text,
                left: e.boundingBox.left,
                top: e.boundingBox.top,
                width: e.boundingBox.width,
                height: e.boundingBox.height,
                confidence: e.confidence == null ? -1 : e.confidence! * 100,
              ),
      ];
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}

/// Splits a page's characters into words: at spaces and line breaks, and
/// where two characters are visibly apart (table cells often have no space
/// character between them). [rects] are in PDF points, origin bottom-left.
List<PageWord> wordsFromChars(String text, List<PdfRect> rects, double pageHeight) {
  final words = <PageWord>[];
  final buffer = StringBuffer();
  double left = 0, top = 0, right = 0, bottom = 0;

  void flush() {
    if (buffer.isEmpty) return;
    words.add(PageWord(buffer.toString(),
        left: left * _scale, top: (pageHeight - top) * _scale, width: (right - left) * _scale, height: (top - bottom) * _scale));
    buffer.clear();
  }

  final n = text.length < rects.length ? text.length : rects.length;
  for (var i = 0; i < n; i++) {
    final ch = text[i];
    if (ch.trim().isEmpty) {
      flush();
      continue;
    }
    final r = rects[i];
    if (r.isEmpty) {
      if (buffer.isNotEmpty) buffer.write(ch);
      continue;
    }
    if (buffer.isNotEmpty) {
      final h = (top - bottom) > (r.top - r.bottom) ? (top - bottom) : (r.top - r.bottom);
      final apart = r.left - right > h * 0.3 || (r.top - top).abs() > h * 0.6 || r.right < left;
      if (apart) flush();
    }
    if (buffer.isEmpty) {
      (left, top, right, bottom) = (r.left, r.top, r.right, r.bottom);
    } else {
      if (r.left < left) left = r.left;
      if (r.right > right) right = r.right;
      if (r.top > top) top = r.top;
      if (r.bottom < bottom) bottom = r.bottom;
    }
    buffer.write(ch);
  }
  flush();
  return words;
}
