/// Reads a payment out of the text of a payment-app screenshot
/// (Google Pay, PhonePe, Paytm, BHIM, bank apps).
///
/// The text comes from on-phone OCR (Google ML Kit), line by line, with each
/// line's height on screen. No AI is involved:
///   * the amount is the TALLEST money-looking line (payment screens always
///     show the amount in the biggest text), which also survives OCR misreading
///     the ₹ sign;
///   * the person / merchant is the line after "Paid to", "To", "Received from";
///   * UPI reference, bank, account digits and date/time come from their labels.
///
/// Pure Dart, unit-tested with text as OCR returns it.
library;

import 'sms_parser.dart';

/// One line of recognised text and its height in pixels.
class OcrLine {
  const OcrLine(this.text, this.height);
  final String text;
  final double height;
}

class ReceiptParser {
  const ReceiptParser._();

  static ParsedSms? parse(List<OcrLine> lines) {
    final clean = [
      for (final l in lines)
        if (l.text.trim().isNotEmpty) OcrLine(l.text.replaceAll(RegExp(r'\s+'), ' ').trim(), l.height),
    ];
    if (clean.isEmpty) return null;
    final text = clean.map((l) => l.text).join('\n');
    final lower = text.toLowerCase();

    if (RegExp(r'\bfailed\b|\bdeclined\b|\bpending\b|processing|unsuccessful|cancelled').hasMatch(lower)) return null;
    final looksLikePayment = RegExp(
      r'\bpaid\b|\bsent\b|\breceived\b|payment successful|transaction successful|\bcompleted\b|\bsuccessful\b|\bdebited\b|\bcredited\b|transfer(?:red)? to|upi (?:transaction|ref)|\butr\b|transaction id',
    ).hasMatch(lower);
    if (!looksLikePayment) return null;

    final amount = _amount(clean);
    if (amount == null || amount <= 0 || amount > 1e9) return null;

    final income = RegExp(r'received from|paid you|sent you|credited to your|money received|\breceived\b').hasMatch(lower) &&
        !RegExp(r'paid to|sent to|payment to|debited from').hasMatch(lower);
    final type = income ? 'INCOME' : 'EXPENSE';

    return ParsedSms(
      type: type,
      amount: amount,
      merchant: _counterparty(clean, income),
      upiRef: _upiRef(text),
      accountLast4: _last4(text),
      bank: _bank(lower),
      note: _note(clean),
      occurredAt: _dateTime(text),
    );
  }

  // -------------------------------------------------------------------------

  /// A line that is (almost) only an amount: "₹250", "₹ 1,25,000.00",
  /// "Rs. 99", or "250" / "%250" / "Z250" when OCR misreads the ₹ sign.
  static final _amountLine = RegExp(r'^(?:[₹%Z?]|rs\.?|inr)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*/?-?$', caseSensitive: false);
  static final _inlineMoney = RegExp(r'(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', caseSensitive: false);

  static double? _amount(List<OcrLine> lines) {
    OcrLine? best;
    double? bestValue;
    for (final l in lines) {
      final m = _amountLine.firstMatch(l.text);
      if (m == null) continue;
      final raw = m.group(1)!;
      // Skip bare numbers that look like ids, years or times.
      final hasSymbol = l.text.length > raw.length;
      if (!hasSymbol && (raw.length >= 9 || RegExp(r'^(?:19|20)\d\d$').hasMatch(raw))) continue;
      final value = double.tryParse(raw.replaceAll(',', ''));
      if (value == null) continue;
      if (best == null || l.height > best.height) {
        best = l;
        bestValue = value;
      }
    }
    if (bestValue != null) return bestValue;
    final inline = _inlineMoney.firstMatch(lines.map((l) => l.text).join(' '));
    return inline == null ? null : double.tryParse(inline.group(1)!.replaceAll(',', ''));
  }

  static final _toLabel = RegExp(r'^(?:paid (?:successfully )?to|sent to|payment to|transferred to|to|banking name|paying)\s*:?\s*(.*)$', caseSensitive: false);
  static final _fromLabel = RegExp(r'^(?:received from|from|paid by|sent by)\s*:?\s*(.*)$', caseSensitive: false);

  static String? _counterparty(List<OcrLine> lines, bool income) {
    final label = income ? _fromLabel : _toLabel;
    for (var i = 0; i < lines.length; i++) {
      final m = label.firstMatch(lines[i].text);
      if (m == null) continue;
      final sameLine = m.group(1)!.trim();
      final candidate = sameLine.isNotEmpty ? sameLine : (i + 1 < lines.length ? lines[i + 1].text : '');
      final name = _cleanName(candidate);
      if (name != null) return name;
    }
    // "Rahul Sharma paid you ₹500"
    final paidYou = RegExp(r"^([A-Za-z][A-Za-z .']{1,40}?)\s+(?:paid|sent) you", caseSensitive: false);
    for (final l in lines) {
      final m = paidYou.firstMatch(l.text);
      if (m != null) return _cleanName(m.group(1)!);
    }
    return null;
  }

  static String? _cleanName(String raw) {
    var s = raw.trim();
    // "SWIGGY swiggy@icici" -> "SWIGGY"; "swiggy@icici" -> "swiggy"
    final vpa = RegExp(r'[\w.\-]+@[\w.\-]+').firstMatch(s);
    if (vpa != null) {
      final rest = s.replaceFirst(vpa.group(0)!, '').trim();
      s = rest.isNotEmpty ? rest : vpa.group(0)!.split('@').first.replaceAll(RegExp(r'\d'), ' ').replaceAll(RegExp(r'[._\-]+'), ' ').trim();
    }
    s = s.replaceAll(RegExp(r'[\s.,:;\-]+$'), '').trim();
    if (s.length < 2 || s.length > 40) return null;
    if (RegExp(r'^[\d\s₹,.]+$').hasMatch(s)) return null;
    if (RegExp(r'^(?:your|you|me|self|bank|upi|account)\b', caseSensitive: false).hasMatch(s)) return null;
    return s == s.toUpperCase() ? titleCase(s) : s;
  }

  static String? _upiRef(String text) {
    final labelled = RegExp(
      r'(?:upi (?:transaction|txn|ref(?:erence)?)\s*(?:id|no\.?|number)?|utr(?:\s*no\.?)?|rrn|upi ref no\.?)\s*[:\-]?\s*(\d{12})\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (labelled != null) return labelled.group(1);
    return RegExp(r'(?<!\d)(\d{12})(?!\d)').firstMatch(text)?.group(1);
  }

  static String? _last4(String text) =>
      RegExp(r'(?:•+|·{2,}|\*{2,}|[xX]{2,}|\b(?:a/?c|account|card)\s*(?:no\.?)?\s*[-:]?)\s*(\d{4})\b', caseSensitive: false)
          .firstMatch(text)
          ?.group(1) ??
      RegExp(r'\bbank\s*-\s*(\d{4})\b', caseSensitive: false).firstMatch(text)?.group(1);

  static const _banks = [
    ('hdfc', 'HDFC Bank'),
    ('icici', 'ICICI Bank'),
    ('state bank', 'State Bank of India'),
    ('sbi', 'State Bank of India'),
    ('axis', 'Axis Bank'),
    ('kotak', 'Kotak Bank'),
    ('punjab national', 'Punjab National Bank'),
    ('bank of baroda', 'Bank of Baroda'),
    ('canara', 'Canara Bank'),
    ('idfc', 'IDFC First Bank'),
    ('yes bank', 'Yes Bank'),
    ('indusind', 'IndusInd Bank'),
    ('federal', 'Federal Bank'),
    ('union bank', 'Union Bank'),
    ('bank of india', 'Bank of India'),
    ('indian bank', 'Indian Bank'),
    ('paytm payments bank', 'Paytm Payments Bank'),
    ('airtel payments bank', 'Airtel Payments Bank'),
  ];

  static String? _bank(String lower) {
    for (final (key, name) in _banks) {
      if (RegExp('\\b${RegExp.escape(key)}\\b').hasMatch(lower)) return name;
    }
    return null;
  }

  static String? _note(List<OcrLine> lines) {
    final label = RegExp(r'^(?:note|message|remarks?|purpose|description)\s*:?\s*(.*)$', caseSensitive: false);
    for (var i = 0; i < lines.length; i++) {
      final m = label.firstMatch(lines[i].text);
      if (m == null) continue;
      final value = m.group(1)!.trim().isNotEmpty ? m.group(1)!.trim() : (i + 1 < lines.length ? lines[i + 1].text : '');
      if (value.isNotEmpty && value.length <= 80) return value;
    }
    return null;
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// "12 Nov 2026, 10:42 am", "12 November 2026 at 10:42 PM", "Nov 12, 2026 10:42".
  static DateTime? _dateTime(String text) {
    final dmy = RegExp(r'\b(\d{1,2})\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})(?:\D{1,6}(\d{1,2}):(\d{2})\s*([ap]\.?m\.?)?)?', caseSensitive: false).firstMatch(text);
    final mdy = RegExp(r'\b([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})(?:\D{1,6}(\d{1,2}):(\d{2})\s*([ap]\.?m\.?)?)?', caseSensitive: false).firstMatch(text);
    int? day, month, year, hour, minute;
    String? ampm;
    if (dmy != null && _months.containsKey(dmy.group(2)!.toLowerCase().substring(0, 3))) {
      day = int.parse(dmy.group(1)!);
      month = _months[dmy.group(2)!.toLowerCase().substring(0, 3)];
      year = int.parse(dmy.group(3)!);
      hour = int.tryParse(dmy.group(4) ?? '');
      minute = int.tryParse(dmy.group(5) ?? '');
      ampm = dmy.group(6);
    } else if (mdy != null && _months.containsKey(mdy.group(1)!.toLowerCase().substring(0, 3))) {
      month = _months[mdy.group(1)!.toLowerCase().substring(0, 3)];
      day = int.parse(mdy.group(2)!);
      year = int.parse(mdy.group(3)!);
      hour = int.tryParse(mdy.group(4) ?? '');
      minute = int.tryParse(mdy.group(5) ?? '');
      ampm = mdy.group(6);
    }
    if (day == null || month == null || year == null || day > 31) return null;
    var h = hour ?? 12;
    if (ampm != null) {
      final pm = ampm.toLowerCase().startsWith('p');
      if (pm && h < 12) h += 12;
      if (!pm && h == 12) h = 0;
    }
    final result = DateTime(year, month, day, h, minute ?? 0);
    // Ignore impossible dates (OCR noise) and the future.
    if (result.month != month || result.isAfter(DateTime.now().add(const Duration(days: 1)))) return null;
    return result;
  }
}
