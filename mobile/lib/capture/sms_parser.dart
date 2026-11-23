/// Turns a bank / UPI / card SMS into a transaction, or rejects it.
///
/// Indian banks word their messages differently, so instead of one template
/// per bank this looks for the parts every transaction SMS has:
///   * an amount ("Rs 250", "INR 1,234.50", "₹99", "debited by 250.0")
///   * a direction ("debited", "spent", "sent" vs "credited", "received")
///   * where it happened (account / card last digits, or a UPI reference)
/// and rejects everything that only looks similar: OTPs, offers, payment
/// requests, failed payments, bill / due-date reminders, balance alerts.
///
/// Pure Dart with no phone APIs, so it is fully unit-tested.
library;

class ParsedSms {
  const ParsedSms({
    required this.type,
    required this.amount,
    this.accountLast4,
    this.merchant,
    this.upiRef,
    this.bank,
    this.isCard = false,
    this.balance,
    this.note,
    this.occurredAt,
  });

  /// 'EXPENSE' (money out) or 'INCOME' (money in).
  final String type;
  final double amount;
  final String? accountLast4;
  final String? merchant;
  final String? upiRef;
  final String? bank;
  final bool isCard;

  /// Available balance after the transaction, when the SMS mentions it.
  final double? balance;

  /// The payer's note, when a receipt shows one ("Dinner split").
  final String? note;

  /// When the payment happened, if the text says so (receipt screenshots).
  /// Otherwise the message's arrival time is used.
  final DateTime? occurredAt;

  @override
  String toString() =>
      'ParsedSms($type $amount, last4=$accountLast4, merchant=$merchant, upi=$upiRef, bank=$bank, card=$isCard, bal=$balance)';
}

class SmsParser {
  const SmsParser._();

  /// [fromPaymentApp]: the text comes from a payment app notification or was
  /// shared by the user, so it doesn't need account digits or a UPI
  /// reference to be trusted ("You paid ₹250.00 to Swiggy").
  static ParsedSms? parse(String sender, String body, {bool fromPaymentApp = false}) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();

    if (_rejected(lower)) return null;

    final balanceSpans = _balanceMatches(text).toList();
    final amount = _amount(text, balanceSpans);
    if (amount == null || amount <= 0 || amount > 1e9) return null;

    final type = _direction(lower);
    if (type == null) return null;

    final last4 = _accountLast4(text);
    final upiRef = _upiRef(text, lower);
    final bank = bankForSender(sender);

    // Known bank senders need a direction word; unknown senders (shops,
    // apps) must also name an account / card or a UPI reference, to keep
    // order confirmations and adverts out.
    if (!fromPaymentApp) {
      if (bank == null && last4 == null && upiRef == null) return null;
      if (last4 == null && upiRef == null && !RegExp(r'a/c|acct|account|card|upi|wallet').hasMatch(lower)) return null;
    }

    return ParsedSms(
      type: type,
      amount: amount,
      accountLast4: last4,
      merchant: _merchant(text),
      upiRef: upiRef,
      bank: bank,
      isCard: RegExp(r'\bcard\b').hasMatch(lower),
      balance: balanceSpans.isEmpty ? null : _number(balanceSpans.first.group(1)!),
    );
  }

  // -------------------------------------------------------------------------

  /// Never a transaction: OTPs, payment requests, future debits, adverts.
  /// (Footers like "Never share your OTP" are fine; only real OTP texts match.)
  static final _alwaysReject = [
    RegExp(r'(?:is your|is the) (?:otp|one[- ]?time password)|\botp (?:is|for|to)\b|one[- ]?time password (?:is|for)|verification code'),
    RegExp(r'has requested|requested (?:money|rs|inr|₹)|collect request|is requesting|request(?:ed)? for (?:rs|inr|₹)|sent you a request'),
    RegExp(r'will be (?:auto[- ]?)?debited|to be debited|will be deducted'),
    RegExp(r'pre-?approved|apply now|click (?:here|on)|limited period|get up to|eligible for (?:a|an|instant)|loan of up to|t&c apply|t&cs apply|hurry'),
    // Payment-app extras: rewards, reminders and payments not finished yet.
    RegExp(r'scratch card|you(?:.ve| have)? won|rewards? (?:of|worth) (?:rs|inr|₹)|payment (?:is )?pending|is pending|under process|in progress|remind(?:er)? to pay|pay (?:your|now)'),
  ];

  /// Failed payments, unless the SMS is the refund of one.
  static final _failed = RegExp(r'\bfailed\b|\bdeclined\b|unsuccessful|could not be (?:processed|completed)|was not (?:processed|successful)');
  static final _refund = RegExp(r'\breversed\b|\breversal\b|\brefund(?:ed)?\b');

  /// Reminders and statements, unless money actually moved ("EMI debited …
  /// next EMI is due on …" is still a debit).
  static final _reminder = RegExp(
    r'is due|due on|due by|due date|payment due|minimum (?:amount )?due|min\.? amt due|total (?:amount )?due|amt due|statement (?:for|of|is)|is generated|e-?mandate|standing instruction|si (?:has been )?registered|autopay (?:set|scheduled)',
  );
  static final _moved = RegExp(r'\b(?:debited|credited|spent|withdrawn|received|deducted|paid|sent)\b');

  static bool _rejected(String lower) {
    if (_alwaysReject.any((p) => p.hasMatch(lower))) return true;
    if (_failed.hasMatch(lower) && !_refund.hasMatch(lower)) return true;
    if (_reminder.hasMatch(lower) && !_moved.hasMatch(lower)) return true;
    return false;
  }

  static final _money = RegExp(r'(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', caseSensitive: false);
  static final _bareMoney =
      RegExp(r'\b(?:debited|credited|deducted)\s+(?:by|with|for)\s+([0-9][0-9,]*(?:\.[0-9]{1,2})?)\b', caseSensitive: false);
  static final _balance = RegExp(
    r'(?:avl\.?\s*bal(?:ance)?|avbl\.?\s*bal(?:ance)?|available\s+bal(?:ance)?|a/c\s+bal(?:ance)?|clear\s+bal(?:ance)?|\bbal(?:ance)?)\s*(?:is|:|-|of)?\s*(?:rs\.?|inr|₹)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
    caseSensitive: false,
  );

  static Iterable<RegExpMatch> _balanceMatches(String text) => _balance.allMatches(text);

  static double? _amount(String text, List<RegExpMatch> balanceSpans) {
    bool inBalance(int index) => balanceSpans.any((b) => index >= b.start && index < b.end);
    for (final m in _money.allMatches(text)) {
      if (!inBalance(m.start)) return _number(m.group(1)!);
    }
    final bare = _bareMoney.firstMatch(text);
    return bare == null ? null : _number(bare.group(1)!);
  }

  static double? _number(String raw) => double.tryParse(raw.replaceAll(',', ''));

  static final _debitWords = RegExp(
    r'\bdebited\b|\bdebit of\b|\bspent\b|\bwithdrawn\b|\bwithdrawal\b|\bpaid\b|\bsent\b|\bpurchase\b|\bdeducted\b|\btransferred to\b|\btxn of\b|\bused (?:at|for|on)\b|\bdr\b',
  );
  static final _creditWords =
      RegExp(r'\bcredited\b|\bcredit of\b|\breceived\b|\bdeposited\b|\badded to\b|\brefund(?:ed)?\b|\breversed\b|\breversal\b|\bcashback\b|\bcr\b');

  /// Whichever kind of word comes first decides: "Rs 50 debited from A/c 12
  /// and credited to VPA x" is money out for the reader.
  static String? _direction(String lower) {
    // "Rahul Sharma paid you ₹500" / "sent you" is money in.
    if (RegExp(r'\b(?:paid|sent|transferred) you\b').hasMatch(lower)) return 'INCOME';
    final debit = _debitWords.firstMatch(lower)?.start;
    final credit = _creditWords.firstMatch(lower)?.start;
    if (debit == null && credit == null) return null;
    if (credit == null) return 'EXPENSE';
    if (debit == null) return 'INCOME';
    return debit < credit ? 'EXPENSE' : 'INCOME';
  }

  static final _accountPatterns = [
    RegExp(
      r'\b(?:a/c|a/c\.|acct|account|ac|card)(?:\s*(?:no\.?|number|num))?\s*(?:ending\s*(?:with|in)?)?\s*[:\-]?\s*[x\*\.#]*\s*(\d{3,6})\b',
      caseSensitive: false,
    ),
    RegExp(r'\b[x\*]{2,}(\d{3,4})\b', caseSensitive: false),
  ];

  static String? _accountLast4(String text) {
    for (final p in _accountPatterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final digits = m.group(1)!;
        return digits.length > 4 ? digits.substring(digits.length - 4) : digits;
      }
    }
    return null;
  }

  static final _refPattern = RegExp(
    r'(?:upi\s*(?:ref(?:erence)?|txn|transaction)?\s*(?:no\.?|id|#|number)?|ref(?:erence)?\s*(?:no\.?|number|#|id)?|rrn|utr(?:\s*no\.?)?)\s*[:\.\-]?\s*(\d{12})\b',
    caseSensitive: false,
  );

  /// UPI transaction references (RRN) are 12 digits.
  static String? _upiRef(String text, String lower) {
    final m = _refPattern.firstMatch(text);
    if (m != null) return m.group(1);
    if (lower.contains('upi')) return RegExp(r'\b(\d{12})\b').firstMatch(text)?.group(1);
    return null;
  }

  static const _name = r"[A-Za-z0-9&@.'*/_\- ]";
  static final _merchantPatterns = [
    RegExp(r'\b(?:to|from)\s+vpa\s+([\w.\-]+@[\w.\-]+)(?:\s*\(([^)]{2,40})\))?', caseSensitive: false),
    RegExp(r'\b(?:to|from)\s+([\w.\-]+@[a-z]{2,})\b', caseSensitive: false),
    RegExp(';\\s*($_name{2,40}?)\\s+credited\\b', caseSensitive: false),
    RegExp('\\btrf to\\s+($_name{2,40}?)\\s+(?:ref|on\\b|upi|\\.)', caseSensitive: false),
    // "UPI/P2M/431234511111/NETFLIX" and "Info: UPI/P2A/…/NAME": one word.
    RegExp(r'\bupi/p2[ma]/\d+/([A-Za-z][A-Za-z0-9&.\-_]{1,40})', caseSensitive: false),
    RegExp(r'\binfo[:\s]+(?:upi/)?(?:p2[ma]/)?(?:\d+/)?([A-Za-z][A-Za-z0-9&.\-_]{1,40})', caseSensitive: false),
    RegExp('\\b(?:at|@)\\s+($_name{2,40}?)\\s+(?:on\\b|via\\b|using\\b|ref|txn|avl|\\.\\s|\\.\$)', caseSensitive: false),
    // Payment apps: "Rahul Sharma paid you ₹500".
    RegExp(r"^([A-Za-z][A-Za-z .']{1,40}?)\s+(?:paid|sent|transferred) you\b", caseSensitive: false),
    RegExp('\\bto\\s+($_name{2,40}?)\\s*(?:\\son\\b|\\sref|\\supi|\\svia\\b|\\.\\s|\\.?\$)', caseSensitive: false),
    RegExp('\\bfrom\\s+($_name{2,40}?)\\s*(?:\\son\\b|\\sref|\\supi|\\svia\\b|\\.\\s|\\.?\$|\\()', caseSensitive: false),
    RegExp('\\bby\\s+($_name{2,40}?)\\s*(?:\\(|ref|upi|on\\b|\\.\\s|\\.\$)', caseSensitive: false),
  ];

  static final _notAMerchant = RegExp(
    r'^(?:your|you|ur|the|a/?c|ac|acct|account|card|bank|self|vpa|upi|net ?banking|imps|neft|rtgs|atm|mobile banking|beneficiary|customer)\b|a/c|account|\bbank\b|\bcard\b|^\d+$|^x+\d*$|^(?:rs|inr|₹)\.?\s*\d',
    caseSensitive: false,
  );

  static String? _merchant(String text) {
    for (final p in _merchantPatterns) {
      final m = p.firstMatch(text);
      if (m == null) continue;
      // Prefer a name in brackets after a UPI id: "to VPA swiggy@icici (SWIGGY)".
      // If the brackets hold something else (e.g. "(UPI 4312…)"), use the id.
      final named = m.groupCount >= 2 && m.group(2) != null ? _clean(m.group(2)!) : null;
      final candidate = named ?? _clean(m.group(1)!);
      if (candidate != null) return candidate;
    }
    return null;
  }

  static String? _clean(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'[\s.,;:\-*/]+$'), '').replaceAll(RegExp(r'^[\s.,;:\-*/]+'), '');
    if (s.contains('@')) s = _fromVpa(s);
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length < 2 || _notAMerchant.hasMatch(s)) return null;
    if (s.length > 40) s = s.substring(0, 40).trim();
    return s == s.toUpperCase() ? titleCase(s) : s;
  }

  /// "swiggy.food@icici" -> "swiggy food"; digits (phone numbers, ids) dropped.
  static String _fromVpa(String vpa) {
    final handle = vpa.split('@').first.replaceAll(RegExp(r'\d'), ' ').replaceAll(RegExp(r'[._\-]+'), ' ').trim();
    return handle.isEmpty ? vpa : handle;
  }
}

String titleCase(String s) => s
    .toLowerCase()
    .split(' ')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

/// The bank or payment app behind an SMS sender ID such as "AX-HDFCBK-S".
/// Returns null for senders that are not known financial senders.
String? bankForSender(String sender) {
  final header = sender.toUpperCase().replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '').replaceFirst(RegExp(r'-[A-Z]$'), '');
  for (final (code, name) in _senders) {
    if (header.contains(code)) return name;
  }
  return null;
}

/// Order matters: more specific codes first (SBI Card before SBI).
const _senders = [
  ('SBICRD', 'SBI Card'),
  ('SBMSMS', 'SBM Bank'),
  ('HDFC', 'HDFC Bank'),
  ('ICICI', 'ICICI Bank'),
  ('SBI', 'State Bank of India'),
  ('AXIS', 'Axis Bank'),
  ('KOTAK', 'Kotak Bank'),
  ('KMBL', 'Kotak Bank'),
  ('PNB', 'Punjab National Bank'),
  ('BOBTXN', 'Bank of Baroda'),
  ('BOBSMS', 'Bank of Baroda'),
  ('BARODA', 'Bank of Baroda'),
  ('CANBNK', 'Canara Bank'),
  ('CANARA', 'Canara Bank'),
  ('IDFC', 'IDFC First Bank'),
  ('YESBNK', 'Yes Bank'),
  ('YESBANK', 'Yes Bank'),
  ('INDUS', 'IndusInd Bank'),
  ('FEDBNK', 'Federal Bank'),
  ('FEDERAL', 'Federal Bank'),
  ('AUBANK', 'AU Small Finance Bank'),
  ('IDBI', 'IDBI Bank'),
  ('UNIONB', 'Union Bank'),
  ('UBOI', 'Union Bank'),
  ('BOIIND', 'Bank of India'),
  ('CENTBK', 'Central Bank of India'),
  ('INDBNK', 'Indian Bank'),
  ('IOBCHN', 'Indian Overseas Bank'),
  ('IOBANK', 'Indian Overseas Bank'),
  ('UCOBNK', 'UCO Bank'),
  ('RBLBNK', 'RBL Bank'),
  ('SCBANK', 'Standard Chartered'),
  ('STANCB', 'Standard Chartered'),
  ('HSBC', 'HSBC'),
  ('CITI', 'Citibank'),
  ('AMEX', 'American Express'),
  ('KVBANK', 'Karur Vysya Bank'),
  ('KARBNK', 'Karnataka Bank'),
  ('SIBSMS', 'South Indian Bank'),
  ('DBSBNK', 'DBS Bank'),
  ('BANDHN', 'Bandhan Bank'),
  ('EQUTAS', 'Equitas Bank'),
  ('UJJIVN', 'Ujjivan Bank'),
  ('AIRBNK', 'Airtel Payments Bank'),
  ('PAYTM', 'Paytm'),
  ('PHONPE', 'PhonePe'),
  ('PHONEPE', 'PhonePe'),
  ('GPAY', 'Google Pay'),
  ('BHIM', 'BHIM'),
  ('CRED', 'CRED'),
  ('ONECRD', 'OneCard'),
  ('SLCEIT', 'Slice'),
  ('JUPITR', 'Jupiter'),
  ('FIMONY', 'Fi'),
  ('MOBKWK', 'MobiKwik'),
  ('AMAZON', 'Amazon Pay'),
];
