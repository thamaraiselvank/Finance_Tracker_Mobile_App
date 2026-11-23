/// How Finverse recognises "a message like this one" so that a choice made
/// once (type, category, account) is applied automatically next time.
///
/// A captured payment is matched to a remembered rule by, in order of
/// reliability:
///   1. the other side's UPI ID   ("zerodha@hdfcbank")
///   2. the other side's name     ("zerodha broking ltd"), also read from
///      bank formats such as "NEFT Cr-YESB0000001-ZERODHA BROKING LTD-…"
///   3. the message's wording with amounts, dates, digits and references
///      removed ("credited to a/c # by neft from zerodha broking ltd"), for
///      messages that carry no name at all.
/// Rules also remember the direction (money in or out), so "Zerodha sent
/// me money" and "I added money to Zerodha" are separate choices.
///
/// When nothing was learned yet, [builtinRule] knows common "own money
/// moving" payments (broker funds, credit card bills, ATM cash, wallet
/// top-ups, self transfers) and salary.
///
/// Pure Dart, unit-tested.
library;

import 'categorizer.dart';

/// Kinds of match, most reliable first.
enum MatchKind {
  upi('UPI'),
  party('PARTY'),
  template('TEMPLATE');

  const MatchKind(this.code);
  final String code;

  static MatchKind fromCode(String code) => values.firstWhere((k) => k.code == code);
}

/// The ways one captured payment can be recognised again.
class RuleKeys {
  const RuleKeys({this.vpa, this.party, this.template});

  final String? vpa;
  final String? party;

  /// Null when the wording has nothing distinctive (only amounts, account
  /// digits and generic bank words): such a rule would match every payment.
  final String? template;

  /// Most reliable first.
  List<(MatchKind, String)> get all => [
        if (vpa != null) (MatchKind.upi, vpa!),
        if (party != null) (MatchKind.party, party!),
        if (template != null) (MatchKind.template, template!),
      ];

  (MatchKind, String)? get best => all.isEmpty ? null : all.first;

  static RuleKeys of({required String text, String? merchant}) {
    final party = merchant == null ? null : merchantKey(merchant);
    return RuleKeys(
      vpa: vpaOf(text),
      party: party == null || party.length < 2 ? null : party,
      template: templateKeyOf(text),
    );
  }
}

final _vpa = RegExp(r'\b([a-z0-9][a-z0-9.\-_]{1,63}@[a-z][a-z0-9]{1,31})\b(?!\.[a-z])', caseSensitive: false);

/// The first UPI ID in the text, lower case (e-mail addresses are skipped).
String? vpaOf(String text) {
  for (final m in _vpa.allMatches(text)) {
    final v = m.group(1)!.toLowerCase();
    if (v.endsWith('@gmail') || v.endsWith('@yahoo') || v.endsWith('@outlook')) continue;
    return v;
  }
  return null;
}

const _months = r'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';

/// Words every bank message has; a template made only of these (plus
/// numbers) says nothing about who the payment was with.
const _genericWords = {
  'rs', 'inr', 'debited', 'credited', 'debit', 'credit', 'from', 'to', 'your', 'you', 'a/c', 'ac', 'acct', 'account', 'bank', 'on', 'at',
  'by', 'for', 'of', 'the', 'is', 'has', 'been', 'was', 'with', 'in', 'and', 'avl', 'avbl', 'bal', 'balance', 'available', 'upi', 'ref',
  'refno', 'no', 'txn', 'transaction', 'not', 'call', 'sms', 'block', 'if', 'this', 'info', 'imps', 'neft', 'rtgs', 'vpa', 'sent', 'paid',
  'received', 'card', 'ending', 'via', 'xx', 'clear', 'total', 'limit', 'dear', 'customer', 'transfer', 'trf', 'cr', 'dr', 'ist', 'it', 'us',
  'please', 'pls', 'report', 'immediately', 'fraud', 'helpline', 'team', 'thank', 'thanks', 'regards', 'mobile', 'banking', 'net', 'app',
  'update', 'alert', 'amount', 'amt', 'date', 'time', 'reference', 'number', 'id', 'mob', 'ltd', 'limited', 'pvt', 'private',
};

/// The message's fixed wording: lower case, with anything containing a
/// digit, month names and currency marks replaced by "#". Null if no word
/// is left that could tell this sender / payee apart from others.
String? templateKeyOf(String text) {
  var s = ' ${text.toLowerCase()} ';
  s = s.replaceAll(RegExp(r'(?:rs\.?|inr|₹)(?=\s*\d)'), ' ');
  s = s.replaceAll(RegExp(r'\S*\d\S*'), ' # ');
  s = s.replaceAll(RegExp('(?<![a-z])(?:$_months)(?![a-z])'), ' # ');
  s = s.replaceAll(RegExp(r'[^a-z#/@&.\- ]'), ' ');
  s = s.replaceAll(RegExp(r'(?<=\s)[.\-/]+(?=\s)'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  s = s.replaceAll(RegExp(r'#(?:[\s#.\-/]*#)+'), '#').trim();
  if (s.length > 160) s = s.substring(0, 160).trim();
  final words = RegExp(r'[a-z][a-z@&.\-]*[a-z]').allMatches(s).map((m) => m.group(0)!);
  final distinctive = words.any((w) => w.length >= 3 && !_genericWords.contains(w.replaceAll('.', '')));
  return distinctive ? s : null;
}

/// A built-in rule's verdict.
class BuiltinMatch {
  const BuiltinMatch(this.type, this.categoryId, this.label);

  /// 'TRANSFER' or 'INCOME'.
  final String type;
  final String categoryId;

  /// Shown on the inbox card ("Built-in: broker funds").
  final String label;
}

final _brokers = RegExp(
  r'zerodha|\bkite\b|groww|upstox|rksv|angel ?one|angel ?broking|icici ?securities|icicidirect|hdfc ?securities|hdfcsec|kotak ?securities|'
  r'motilal|5 ?paisa|\bdhan\b|raise securities|paytm ?money|sharekhan|edelweiss broking|nuvama|fyers|alice ?blue|indmoney|smallcase|'
  r'clearing corp|nse clearing|indian clearing|\biccl\b|bse ltd',
);
final _creditCardBill = RegExp(
  r'credit ?card (?:bill|payment|dues?)|towards (?:your )?(?:\w+ ){0,3}?credit ?card|payment (?:of .{1,25})?received (?:on|towards|for|in) (?:your )?(?:\w+ ){0,3}?(?:credit )?card|'
  r'cc ?bill|\bcred\b.{0,30}\bbill|bill ?desk.{0,20}card|card ?bill paid|payment .{0,25}credited to (?:your )?(?:\w+ ){0,3}?card',
);
final _atm = RegExp(r'\batm\b|cash withdrawal|cash wdl|withdrawn at|\bnfs\b|cash w/d');
final _wallet = RegExp(r'(?:add(?:ed)? money|top[- ]?up|loaded|recharged?) (?:to|in|into) (?:your )?(?:\w+ )?wallet|wallet (?:top[- ]?up|load)|amazon pay balance|paytm wallet');
final _self = RegExp(r'\bself[- ]?transfer|\bto self\b|own account|\bown a/?c\b|between your accounts');
final _salary = RegExp(r'\bsalary\b|\bsal(?:ary)? cr|payroll|\bsal for\b');

/// Common payments that are not spending or earning, or obvious salary.
/// [text] is the message, [merchant] the payee / payer name if found.
BuiltinMatch? builtinRule({required String direction, required String text, String? merchant}) {
  final lower = '${merchant ?? ''} ${text.toLowerCase()}'.toLowerCase();
  if (_brokers.hasMatch(lower)) return const BuiltinMatch('TRANSFER', CategoryIds.brokerFunds, 'Built-in: broker funds');
  if (_creditCardBill.hasMatch(lower)) return const BuiltinMatch('TRANSFER', CategoryIds.cardBill, 'Built-in: credit card bill');
  if (direction == 'OUT' && _atm.hasMatch(lower)) return const BuiltinMatch('TRANSFER', CategoryIds.cashWithdrawal, 'Built-in: cash withdrawal');
  if (_wallet.hasMatch(lower)) return const BuiltinMatch('TRANSFER', CategoryIds.walletTopUp, 'Built-in: wallet top-up');
  if (_self.hasMatch(lower)) return const BuiltinMatch('TRANSFER', CategoryIds.ownTransfer, 'Built-in: own account transfer');
  if (direction == 'IN' && _salary.hasMatch(lower)) return const BuiltinMatch('INCOME', CategoryIds.salary, 'Built-in: salary');
  return null;
}

/// 'IN' for money received, 'OUT' for money paid.
String directionOf(String parsedType) => parsedType == 'INCOME' ? 'IN' : 'OUT';
