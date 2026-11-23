/// Suggests a category for an automatically captured transaction.
///
/// Order: 1) what the user chose before for payments like this (learned
/// rules, see rules.dart), 2) built-in rules for own-money transfers and
/// salary (rules.dart), 3) the keyword list below ("Guess · please check"),
/// 4) nothing (the user picks in the review inbox, and that becomes a rule).
///
/// The keyword list starts from the backend importer's
/// `_suggest_statement_category` and adds common Indian merchants.
library;

/// Category ids (same as the backend seed).
class CategoryIds {
  static const salary = '00000000-0000-0000-0000-000000000001';
  static const investments = '00000000-0000-0000-0000-000000000002';
  static const rentalIncome = '00000000-0000-0000-0000-000000000004';
  static const otherIncome = '00000000-0000-0000-0000-000000000005';
  static const housing = '00000000-0000-0000-0000-000000000010';
  static const food = '00000000-0000-0000-0000-000000000011';
  static const utilities = '00000000-0000-0000-0000-000000000012';
  static const transport = '00000000-0000-0000-0000-000000000013';
  static const health = '00000000-0000-0000-0000-000000000014';
  static const shopping = '00000000-0000-0000-0000-000000000015';
  static const entertainment = '00000000-0000-0000-0000-000000000016';
  static const insurance = '00000000-0000-0000-0000-000000000017';
  static const loans = '00000000-0000-0000-0000-000000000018';
  static const education = '00000000-0000-0000-0000-000000000019';
  static const travel = '00000000-0000-0000-0000-000000000021';

  // "Own money moving" (type TRANSFER): changes an account balance but is
  // neither income nor spending. Phone-only (schema v5).
  static const brokerFunds = '00000000-0000-0000-0000-000000000030';
  static const ownTransfer = '00000000-0000-0000-0000-000000000031';
  static const cardBill = '00000000-0000-0000-0000-000000000032';
  static const walletTopUp = '00000000-0000-0000-0000-000000000033';
  static const cashWithdrawal = '00000000-0000-0000-0000-000000000034';
}

const _incomeKeywords = [
  (['salary', 'payroll', 'wages', 'sal credit', 'stipend'], CategoryIds.salary),
  (['interest', 'dividend', 'int.pd', 'int pd', 'mutual fund', 'redemption'], CategoryIds.investments),
  (['rent received', 'rental'], CategoryIds.rentalIncome),
  (['refund', 'cashback', 'reversal', 'reversed'], CategoryIds.otherIncome),
];

const _expenseKeywords = [
  (['swiggy', 'zomato', 'zepto', 'blinkit', 'bigbasket', 'big basket', 'instamart', 'dmart', 'grofers', 'dunzo', 'restaurant', 'cafe',
    'starbucks', 'dominos', "domino's", 'pizza', 'mcdonald', 'kfc', 'burger', 'grocery', 'groceries', 'supermarket', 'reliance fresh',
    'more retail', 'spencer', 'licious', 'freshtohome', 'eatsure', 'chaayos', 'haldiram', 'bakery'], CategoryIds.food),
  (['electricity', 'bescom', 'tneb', 'tangedco', 'msedcl', 'mahadiscom', 'bses', 'tata power', 'adani electricity', 'kseb', 'cesc',
    'water bill', 'gas bill', 'indane', 'bharat gas', 'hp gas', 'mahanagar gas', 'broadband', 'act fibernet', 'hathway', 'airtel', 'jio',
    'vodafone', 'vi recharge', 'bsnl', 'recharge', 'dth', 'tata play', 'tatasky', 'dish tv', 'sun direct', 'postpaid', 'prepaid'],
    CategoryIds.utilities),
  (['uber', 'ola', 'rapido', 'namma yatri', 'metro', 'petrol', 'diesel', 'fuel', 'hpcl', 'bpcl', 'iocl', 'indian oil', 'hindustan petroleum',
    'bharat petroleum', 'shell', 'fastag', 'parking', 'toll', 'blusmart'], CategoryIds.transport),
  (['pharmacy', 'medical', 'hospital', 'clinic', 'doctor', 'apollo', 'pharmeasy', '1mg', 'tata 1mg', 'netmeds', 'medplus', 'practo',
    'diagnostic', 'lab test', 'thyrocare', 'lal path', 'healthians', 'cult.fit', 'cultfit'], CategoryIds.health),
  (['amazon', 'flipkart', 'myntra', 'ajio', 'meesho', 'nykaa', 'tata cliq', 'croma', 'reliance digital', 'decathlon', 'lifestyle',
    'westside', 'pantaloons', 'shoppers stop', 'zara', 'h&m', 'ikea', 'pepperfry', 'urban company', 'lenskart', 'shopping'],
    CategoryIds.shopping),
  (['netflix', 'spotify', 'hotstar', 'jiocinema', 'jio cinema', 'prime video', 'amazon prime', 'sonyliv', 'zee5', 'youtube premium',
    'bookmyshow', 'pvr', 'inox', 'cinepolis', 'movie', 'cinema', 'gaming', 'steam', 'playstation'], CategoryIds.entertainment),
  (['insurance', 'premium', 'lic ', 'lic of india', 'policybazaar', 'star health', 'hdfc ergo', 'icici lombard', 'acko', 'digit insurance',
    'max life', 'bajaj allianz', 'care health', 'niva bupa'], CategoryIds.insurance),
  (['emi', 'loan repayment', 'loan payment', 'loan a/c', 'bajaj finance', 'bajaj finserv', 'home credit'],
    CategoryIds.loans),
  (['tuition', 'course fee', 'school', 'college', 'university', 'education', 'udemy', 'coursera', 'byju', 'unacademy', 'upgrad', 'vedantu'],
    CategoryIds.education),
  (['makemytrip', 'goibibo', 'cleartrip', 'irctc', 'indigo', 'air india', 'akasa', 'spicejet', 'vistara', 'oyo', 'redbus', 'airbnb',
    'booking.com', 'agoda', 'yatra', 'ixigo', 'abhibus', 'hotel', 'resort'], CategoryIds.travel),
  (['rent', 'nobroker', 'nestaway', 'housing', 'maintenance', 'society'], CategoryIds.housing),
];

/// Keyword suggestion for [text] (merchant name plus SMS text).
String? suggestCategory(String type, String text) {
  final lower = ' ${text.toLowerCase()} ';
  final table = type == 'INCOME' ? _incomeKeywords : _expenseKeywords;
  for (final (keywords, categoryId) in table) {
    if (keywords.any((k) => _containsWord(lower, k))) return categoryId;
  }
  return null;
}

/// Matches whole words / phrases, so "ola" doesn't match "cola" and "emi"
/// doesn't match "premium".
bool _containsWord(String haystack, String keyword) {
  final k = RegExp.escape(keyword.trim());
  return RegExp('(?<![a-z0-9])$k(?![a-z0-9])').hasMatch(haystack);
}

/// Stable key for remembering a merchant's category: "SWIGGY*Instamart" and
/// "swiggy instamart" share one rule.
String merchantKey(String merchant) =>
    merchant.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
