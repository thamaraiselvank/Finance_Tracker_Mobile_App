/// The other side's name in a bank statement narration, e.g.
/// "UPI/DR/412345678901/SWIGGY/YESB/swiggy@ybl/Payment" -> "SWIGGY",
/// "NEFT CR-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN1234" ->
/// "ZERODHA BROKING LTD", "POS 4321XXXX1234 AMAZON PAY IN" ->
/// "AMAZON PAY IN". Used so rules learned from SMS ("payments to Swiggy
/// are Food") also apply to imported statements.
library;

const _noise = {
  'upi', 'neft', 'imps', 'rtgs', 'dr', 'cr', 'pos', 'ach', 'ecs', 'nach', 'mb', 'ib', 'bil', 'onl', 'trf', 'transfer', 'to', 'from', 'by',
  'payment', 'paid', 'pay', 'p2a', 'p2m', 'upiintent', 'collect', 'mmt', 'inb', 'int', 'ref', 'txn', 'debit', 'credit', 'card', 'visa',
  'rupay', 'mastercard', 'atw', 'nwd', 'eaw', 'vps', 'vin', 'ipay', 'billpay', 'autopay', 'si', 'mandate', 'na', 'null', 'others', 'other',
  'sent', 'received', 'using', 'via', 'ltd', 'pvt', 'yesb', 'hdfc', 'icic', 'sbin', 'utib', 'kkbk', 'payu', 'razorpay', 'cashfree', 'bharatpe',
  'paytm', 'phonepe', 'gpay', 'ybl', 'okaxis', 'oksbi', 'okhdfcbank', 'okicici', 'axl', 'ibl', 'apl', 'upi intent', 'remarks',
};

String? narrationName(String narration) {
  final parts = narration.split(RegExp(r'[-/|:*]|\s{2,}'));
  for (var part in parts) {
    part = part.trim();
    if (part.isEmpty || part.contains('@')) continue;
    // Drop leading markers inside a part: "POS 4321XXXX1234 AMAZON PAY IN".
    final words = part.split(RegExp(r'\s+')).where((w) {
      final lower = w.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (lower.isEmpty) return false;
      if (RegExp(r'\d').hasMatch(lower)) return false; // references, IFSC, card digits
      if (RegExp(r'^x+$').hasMatch(lower)) return false;
      return true;
    }).toList();
    while (words.isNotEmpty && _noise.contains(words.first.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''))) {
      words.removeAt(0);
    }
    if (words.isEmpty) continue;
    final name = words.join(' ');
    final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.length < 3) continue;
    if (words.length == 1 && _noise.contains(letters.toLowerCase())) continue;
    return name.length > 60 ? name.substring(0, 60).trim() : name;
  }
  return null;
}
