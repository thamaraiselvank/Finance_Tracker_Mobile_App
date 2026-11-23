import 'package:intl/intl.dart';

/// Safely converts JSON numbers (int, double, numeric strings, null) to double.
double toDouble(dynamic value, [double fallback = 0]) {
  if (value == null) return fallback;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? fallback;
}

int toInt(dynamic value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? toDouble(value, fallback.toDouble()).toInt();
}

String? toStr(dynamic value) => value?.toString();

DateTime? toDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

const _locales = {'INR': 'en_IN', 'USD': 'en_US', 'EUR': 'de_DE', 'GBP': 'en_GB'};
const _symbols = {'INR': '₹', 'USD': r'$', 'EUR': '€', 'GBP': '£'};

/// Currency formatting that mirrors the web app (no decimals, locale grouping).
class Money {
  Money(String? currency) : code = _locales.containsKey(currency) ? currency! : 'INR';

  final String code;

  String get symbol => _symbols[code]!;

  String format(dynamic value, {bool hidden = false}) {
    if (hidden) return '$symbol ••••';
    return NumberFormat.currency(locale: _locales[code], symbol: symbol, decimalDigits: 0)
        .format(toDouble(value));
  }

  /// Short form for tight spaces: ₹1.2L, ₹3.4Cr (INR) or $1.2K, $3.4M.
  String compact(dynamic value, {bool hidden = false}) {
    if (hidden) return '$symbol ••••';
    final v = toDouble(value);
    final abs = v.abs();
    final sign = v < 0 ? '-' : '';
    String fmt(double n) => n.toStringAsFixed(n >= 100 ? 0 : 1).replaceAll(RegExp(r'\.0$'), '');
    if (code == 'INR') {
      if (abs >= 1e7) return '$sign$symbol${fmt(abs / 1e7)}Cr';
      if (abs >= 1e5) return '$sign$symbol${fmt(abs / 1e5)}L';
    } else {
      if (abs >= 1e9) return '$sign$symbol${fmt(abs / 1e9)}B';
      if (abs >= 1e6) return '$sign$symbol${fmt(abs / 1e6)}M';
    }
    if (abs >= 1e3) return '$sign$symbol${fmt(abs / 1e3)}K';
    return format(v);
  }
}

final _apiDate = DateFormat('yyyy-MM-dd');
final _displayDate = DateFormat('d MMM yyyy');
final _shortDate = DateFormat('d MMM');

String apiDate(DateTime date) => _apiDate.format(date);
String displayDate(DateTime? date) => date == null ? '—' : _displayDate.format(date);
String shortDate(DateTime? date) => date == null ? '—' : _shortDate.format(date);

/// "SAVINGS_ACCOUNT" -> "Savings Account"
String humanize(String? value) {
  if (value == null || value.isEmpty) return '—';
  return value
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

String percent(dynamic value, {int digits = 1}) => '${toDouble(value).toStringAsFixed(digits)}%';

// ---------- Amount in words ----------

const _ones = ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const _tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
const _unitNames = {'INR': ('rupee', 'rupees', 'paisa', 'paise'), 'USD': ('dollar', 'dollars', 'cent', 'cents'), 'EUR': ('euro', 'euros', 'cent', 'cents'), 'GBP': ('pound', 'pounds', 'penny', 'pence')};

String _underThousand(int n) {
  if (n < 20) return _ones[n];
  if (n < 100) return '${_tens[n ~/ 10]}${n % 10 != 0 ? ' ${_ones[n % 10]}' : ''}';
  return '${_ones[n ~/ 100]} hundred${n % 100 != 0 ? ' ${_underThousand(n % 100)}' : ''}';
}

String _wholeInWords(int n, bool indian) {
  if (n == 0) return 'zero';
  final parts = <String>[];
  if (indian) {
    // Crores above 99 are themselves expressed in the Indian system (e.g. "one thousand crore").
    final crore = n ~/ 10000000;
    if (crore > 0) parts.add('${crore >= 1000 ? _wholeInWords(crore, true) : _underThousand(crore)} crore');
    final lakh = (n % 10000000) ~/ 100000;
    if (lakh > 0) parts.add('${_underThousand(lakh)} lakh');
    final thousand = (n % 100000) ~/ 1000;
    if (thousand > 0) parts.add('${_underThousand(thousand)} thousand');
  } else {
    const scales = [(1000000000000, 'trillion'), (1000000000, 'billion'), (1000000, 'million'), (1000, 'thousand')];
    var rest = n;
    for (final (size, name) in scales) {
      if (rest >= size) {
        parts.add('${_underThousand(rest ~/ size)} $name');
        rest %= size;
      }
    }
    n = rest;
  }
  final remainder = indian ? n % 1000 : n;
  if (remainder > 0) parts.add(_underThousand(remainder));
  return parts.join(' ');
}

/// "150000.5" (INR) -> "One lakh fifty thousand rupees and fifty paise".
/// Returns null for empty / invalid / negative input.
String? amountInWords(String text, String currency) {
  final value = double.tryParse(text.trim());
  if (value == null || value < 0 || value >= 1e15) return null;
  final code = _unitNames.containsKey(currency) ? currency : 'INR';
  final (one, many, subOne, subMany) = _unitNames[code]!;
  final cents = (value * 100).round();
  final whole = cents ~/ 100;
  final fraction = cents % 100;
  var words = '${_wholeInWords(whole, code == 'INR')} ${whole == 1 ? one : many}';
  if (fraction > 0) words += ' and ${_underThousand(fraction)} ${fraction == 1 ? subOne : subMany}';
  return words[0].toUpperCase() + words.substring(1);
}

/// Helper line for amount inputs: "₹1,50,000 · One lakh fifty thousand rupees".
String? amountHelperText(String text, String currency) {
  final words = amountInWords(text, currency);
  if (words == null) return null;
  final value = double.parse(text.trim());
  final money = Money(currency);
  final digits = value == value.roundToDouble()
      ? money.format(value)
      : NumberFormat.currency(locale: _locales[money.code], symbol: money.symbol, decimalDigits: 2).format(value);
  return '$digits · $words';
}

/// Currency code for a symbol shown as a field prefix (falls back to null).
String? currencyForSymbol(String? symbol) {
  for (final e in _symbols.entries) {
    if (e.value == symbol) return e.key;
  }
  return null;
}
