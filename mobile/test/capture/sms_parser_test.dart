import 'package:finance_tracker_mobile/capture/categorizer.dart';
import 'package:finance_tracker_mobile/capture/sms_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Representative wordings of Indian bank / card / UPI SMS (written for these
/// tests in the common formats; not real messages). When a real SMS is not
/// recognised on a phone, add its (anonymised) text here and fix the parser.
class _Case {
  const _Case(this.name, this.sender, this.body, {required this.type, required this.amount, this.last4, this.merchant, this.upiRef, this.bank, this.balance});
  final String name, sender, body, type;
  final double amount;
  final String? last4, merchant, upiRef, bank;
  final double? balance;
}

const _transactions = [
  _Case('HDFC UPI sent (multi-line)', 'AX-HDFCBK-S',
      'Sent Rs.250.00\nFrom HDFC Bank A/C *1234\nTo SWIGGY\nOn 12/11/26\nRef 431234567890\nNot You?\nCall 18002586161/SMS BLOCK UPI to 7308080808',
      type: 'EXPENSE', amount: 250, last4: '1234', merchant: 'Swiggy', upiRef: '431234567890', bank: 'HDFC Bank'),
  _Case('HDFC UPI received from VPA', 'VM-HDFCBK',
      'Rs.5000.00 credited to HDFC Bank A/c XX1234 on 12-11-26 from VPA rahul.sharma@okicici (UPI 431298765432)',
      type: 'INCOME', amount: 5000, last4: '1234', merchant: 'rahul sharma', upiRef: '431298765432'),
  _Case('ICICI UPI debit, merchant credited', 'JD-ICICIT',
      'ICICI Bank Acct XX123 debited for Rs 1,499.00 on 12-Nov-26; AMAZON PAY credited. UPI:431234500001. Call 18002662 for dispute. SMS BLOCK 123 to 9215676766.',
      type: 'EXPENSE', amount: 1499, last4: '123', merchant: 'Amazon Pay', upiRef: '431234500001', bank: 'ICICI Bank'),
  _Case('ICICI credit card spend', 'AD-ICICIB',
      'INR 2,340.50 spent using ICICI Bank Card XX9012 on 12-Nov-26 on IND*Swiggy. Avl Limit: INR 1,23,456.00. If not you, call 1800 2662/SMS BLOCK 9012 to 9215676766',
      type: 'EXPENSE', amount: 2340.5, last4: '9012'),
  _Case('SBI UPI debit without currency sign', 'VM-SBIUPI',
      'Dear UPI user A/C X1234 debited by 250.0 on date 12Nov26 trf to SWIGGY Refno 431234567777. If not u? call 1800111109. -SBI',
      type: 'EXPENSE', amount: 250, last4: '1234', merchant: 'Swiggy', upiRef: '431234567777', bank: 'State Bank of India'),
  _Case('SBI UPI credit', 'BZ-SBIINB',
      'Dear SBI UPI User, ur A/cX1234 credited by Rs500 on 12Nov26 by (Ref no 431234560000)',
      type: 'INCOME', amount: 500, last4: '1234', upiRef: '431234560000'),
  _Case('Axis UPI P2M', 'AX-AXISBK',
      'INR 899.00 debited\nA/c no. XX5678\n12-11-26, 14:32:10\nUPI/P2M/431234511111/NETFLIX\nNot you? SMS BLOCKUPI Cust ID to 919951860002\nAxis Bank',
      type: 'EXPENSE', amount: 899, last4: '5678', merchant: 'Netflix', upiRef: '431234511111', bank: 'Axis Bank'),
  _Case('Kotak UPI to VPA', 'VK-KOTAKB',
      'Sent Rs.120.00 from Kotak Bank AC X4321 to zomato@hdfcbank on 12-11-26.UPI Ref 431234522222. Not you, https://kotak.com/KBANKT/Fraud',
      type: 'EXPENSE', amount: 120, last4: '4321', merchant: 'zomato', upiRef: '431234522222', bank: 'Kotak Bank'),
  _Case('PNB ATM withdrawal with balance', 'AD-PNBSMS',
      'Your A/c XXXXXXXX7788 has been debited with INR 2,000.00 on 12-11-2026 for ATM withdrawal. Avl Bal INR 15,230.40',
      type: 'EXPENSE', amount: 2000, last4: '7788', balance: 15230.40, bank: 'Punjab National Bank'),
  _Case('HDFC salary NEFT', 'VM-HDFCBK',
      'Update! INR 85,000.00 deposited in HDFC Bank A/c XX1234 on 01-NOV-26 for NEFT Cr-ACME TECHNOLOGIES PVT LTD-SALARY NOV.Avl bal INR 1,02,345.67. Cheque deposits in A/C are subject to clearing',
      type: 'INCOME', amount: 85000, last4: '1234', balance: 102345.67),
  _Case('SBI Card payment received', 'VM-SBICRD',
      'We have received payment of Rs.15,000.00 on your SBI Credit Card ending 4455 on 10-Nov-26. Your available limit is Rs.2,10,000.00',
      type: 'INCOME', amount: 15000, last4: '4455', bank: 'SBI Card'),
  _Case('Card refund', 'AX-HDFCBK',
      'Rs.499.00 refund from AMAZON credited to your HDFC Bank Credit Card XX9876 on 11-11-26',
      type: 'INCOME', amount: 499, last4: '9876'),
  _Case('Loan EMI debited, mentions next due date', 'VM-HDFCBK',
      'EMI of Rs 12,500.00 for Loan A/c XX3344 debited on 05-11-26. Next EMI is due on 05-12-26.',
      type: 'EXPENSE', amount: 12500, last4: '3344'),
  _Case('Reversal of a failed payment', 'VM-SBIUPI',
      'Rs 300.00 reversed to your A/c XX1234 for failed UPI txn Ref 431234599999',
      type: 'INCOME', amount: 300, last4: '1234', upiRef: '431234599999'),
  _Case('Card purchase at merchant', 'AD-AXISBK',
      'Spent INR 1,250.00 on Axis Bank Card no. XX8899 at DECATHLON SPORTS on 12-11-26 12:40:11. Avl Lmt INR 85,000.00. Not you? SMS BLOCK 8899 to 919951860002',
      type: 'EXPENSE', amount: 1250, last4: '8899', merchant: 'Decathlon Sports'),
  _Case('Lakh amount with ₹ sign', 'VM-IDFCFB',
      '₹1,25,000.00 debited from your IDFC FIRST Bank A/c XXXX6655 on 12-NOV-2026 via NEFT to SHARMA PROPERTIES. Ref 431234533333',
      type: 'EXPENSE', amount: 125000, last4: '6655', bank: 'IDFC First Bank'),
];

const _notTransactions = [
  ('OTP for a card payment', 'AD-HDFCBK',
      '123456 is your OTP for txn of Rs 2,500.00 at AMAZON on HDFC Bank card ending 9012. OTP valid for 10 mins. Do not share OTP with anyone.'),
  ('UPI collect request', 'VM-PAYTMB', 'Rahul has requested Rs 500 from you on Paytm. Pay now: paytm.me/x'),
  ('Pre-approved loan advert', 'VK-HDFCBK',
      'Get a Pre-approved Personal Loan of up to Rs 5,00,000 instantly credited to your A/c XX1234. Apply now: hdfc.bank.in/pl T&C apply'),
  ('Credit card statement', 'VM-ICICIB',
      'Your ICICI Bank Credit Card XX9012 statement is generated. Total amt due Rs 12,345.00, Min amt due Rs 620.00, due by 05-Dec-26.'),
  ('Future auto-debit', 'AX-AXISBK', 'Rs 5,999.00 will be debited from your A/c XX5678 on 15-11-26 towards e-mandate for NETFLIX'),
  ('Failed UPI payment', 'VM-SBIUPI', 'Your UPI transaction of Rs 300.00 to SWIGGY has failed. Ref No 431234599999'),
  ('Balance alert only', 'AD-KOTAKB', 'Avl bal in A/c XX4321 is Rs 25,000.00 as on 12-11-26'),
  ('Shop order confirmation', 'VM-ZOMATO', 'Your order of Rs 349 has been placed! Track: zoma.to/t'),
  ('Empty', 'AD-HDFCBK', '   '),
];

void main() {
  group('recognises transaction SMS', () {
    for (final c in _transactions) {
      test(c.name, () {
        final p = SmsParser.parse(c.sender, c.body);
        expect(p, isNotNull, reason: 'not recognised: ${c.body}');
        expect(p!.type, c.type);
        expect(p.amount, c.amount);
        if (c.last4 != null) expect(p.accountLast4, c.last4);
        if (c.merchant != null) expect(p.merchant, c.merchant);
        if (c.upiRef != null) expect(p.upiRef, c.upiRef);
        if (c.bank != null) expect(p.bank, c.bank);
        if (c.balance != null) expect(p.balance, c.balance);
      });
    }
  });

  group('rejects messages that are not payments', () {
    for (final (name, sender, body) in _notTransactions) {
      test(name, () => expect(SmsParser.parse(sender, body), isNull, reason: body));
    }
  });

  test('sender IDs map to banks, with or without prefix / suffix', () {
    expect(bankForSender('AX-HDFCBK-S'), 'HDFC Bank');
    expect(bankForSender('HDFCBK'), 'HDFC Bank');
    expect(bankForSender('VM-SBICRD'), 'SBI Card');
    expect(bankForSender('JD-ICICIT'), 'ICICI Bank');
    expect(bankForSender('VM-ZOMATO'), isNull);
  });

  group('category suggestions', () {
    test('known merchants and words', () {
      expect(suggestCategory('EXPENSE', 'Swiggy'), CategoryIds.food);
      expect(suggestCategory('EXPENSE', 'UBER INDIA'), CategoryIds.transport);
      expect(suggestCategory('EXPENSE', 'Netflix'), CategoryIds.entertainment);
      expect(suggestCategory('EXPENSE', 'BESCOM electricity bill'), CategoryIds.utilities);
      expect(suggestCategory('INCOME', 'NEFT Cr-ACME TECHNOLOGIES PVT LTD-SALARY NOV'), CategoryIds.salary);
      expect(suggestCategory('INCOME', 'refund from AMAZON'), CategoryIds.otherIncome);
    });

    test('whole words only', () {
      expect(suggestCategory('EXPENSE', 'Coca Cola store'), isNot(CategoryIds.transport)); // "ola" inside "cola"
      expect(suggestCategory('EXPENSE', 'health premium'), CategoryIds.insurance); // not "emi" inside "premium"
      expect(suggestCategory('EXPENSE', 'Ramesh Kumar'), isNull);
    });

    test('merchant keys ignore case, digits and symbols', () {
      expect(merchantKey('SWIGGY*Instamart'), merchantKey('swiggy instamart'));
      expect(merchantKey('Amazon Pay 123'), 'amazon pay');
    });
  });
}
