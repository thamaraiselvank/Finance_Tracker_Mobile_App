import 'package:finance_tracker_mobile/capture/categorizer.dart';
import 'package:finance_tracker_mobile/capture/rules.dart';
import 'package:finance_tracker_mobile/capture/sms_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UPI IDs', () {
    test('found in bank and app text, lower case; e-mail addresses skipped', () {
      expect(vpaOf('Rs 250 debited from A/c XX1234 to VPA Swiggy@ICICI on 16-11-26'), 'swiggy@icici');
      expect(vpaOf('Received Rs.500.00 from rahul.k@okaxis on 16-11-26.UPI Ref:431255556666.'), 'rahul.k@okaxis');
      expect(vpaOf('Write to care@hdfcbank.com for help'), isNull);
      expect(vpaOf('Mail me at someone@gmail'), isNull);
      expect(vpaOf('No id here'), isNull);
    });
  });

  group('message wording', () {
    test('amounts, dates, digits and references do not matter', () {
      final a = templateKeyOf('Rs.199.00 debited from A/c XX1234 for Netflix subscription mandate on 16-11-26');
      final b = templateKeyOf('Rs.649.00 debited from A/c XX1234 for Netflix subscription mandate on 16-12-26');
      final c = templateKeyOf('INR 1,299 debited from A/c XX1234 for Netflix subscription mandate on 03-Jan-27');
      expect(a, isNotNull);
      expect(a, b);
      expect(a, c);
      expect(a, '# debited from a/c # for netflix subscription mandate on #');
    });

    test('wording made only of generic bank words is not used', () {
      expect(templateKeyOf('Rs 250.00 debited from A/c XX1234 on 16-11-26. UPI Ref 431234567000.'), isNull);
      expect(templateKeyOf('INR 500 credited to your account XX12 on 01 Nov. Avl bal INR 9,000'), isNull);
    });
  });

  group('rule keys', () {
    test('UPI ID first, then name, then wording', () {
      final keys = RuleKeys.of(text: 'Sent Rs.250 to VPA swiggy@icici (Swiggy) Ref 431234567890', merchant: 'Swiggy');
      expect(keys.best, (MatchKind.upi, 'swiggy@icici'));
      expect(keys.party, 'swiggy');
      final named = RuleKeys.of(text: 'Sent Rs.250.00 From HDFC Bank A/C *1234 To SWIGGY On 16/11/26 Ref 431234567890', merchant: 'Swiggy');
      expect(named.best, (MatchKind.party, 'swiggy'));
    });
  });

  group('built-in rules', () {
    BuiltinMatch? rule(String direction, String text, [String? merchant]) => builtinRule(direction: direction, text: text, merchant: merchant);

    test('brokers are own money, both ways', () {
      expect(rule('IN', 'NEFT Cr-YESB0000001-ZERODHA BROKING LTD')?.categoryId, CategoryIds.brokerFunds);
      expect(rule('OUT', 'Sent Rs 5000 to zerodhabroking.rzp@axisbank')?.type, 'TRANSFER');
      expect(rule('OUT', 'Paid to Groww')?.categoryId, CategoryIds.brokerFunds);
      expect(rule('IN', 'Funds from Upstox (RKSV Securities)')?.categoryId, CategoryIds.brokerFunds);
    });

    test('card bills, ATM, wallet, self transfer, salary', () {
      expect(rule('OUT', 'debited towards your ICICI Credit Card XX9876 bill')?.categoryId, CategoryIds.cardBill);
      expect(rule('IN', 'Payment of Rs 15,000 received on your HDFC Bank Credit Card XX1234')?.categoryId, CategoryIds.cardBill);
      expect(rule('OUT', 'Rs.2000 withdrawn at ATM S1AW0012')?.categoryId, CategoryIds.cashWithdrawal);
      expect(rule('OUT', 'Added money to your Paytm wallet')?.categoryId, CategoryIds.walletTopUp);
      expect(rule('OUT', 'IMPS self transfer to A/c XX5678')?.categoryId, CategoryIds.ownTransfer);
      expect(rule('IN', 'credited by NEFT from ACME TECH SALARY NOV')?.categoryId, CategoryIds.salary);
      expect(rule('OUT', 'Paid to Swiggy'), isNull);
      // "ATM" only matters for money going out.
      expect(rule('IN', 'Cash deposited at ATM'), isNull);
    });
  });

  group('names from bank transfer formats', () {
    String? merchant(String body, [String sender = 'AX-HDFCBK']) => SmsParser.parse(sender, body)?.merchant;

    test('NEFT / IMPS / Info- styles', () {
      expect(
        merchant('Update! INR 12,345.00 deposited in HDFC Bank A/c XX1234 on 15-NOV-26 for NEFT Cr-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN1234. Avl bal INR 50,000.00'),
        'Zerodha Broking Ltd',
      );
      expect(
        merchant('INR 5000.00 credited to A/c no. XX1234 on 15-11-26 at 10:30:00 IST. Info- NEFT/ZERODHA BROKING/AXISN1234. Avl Bal INR 9000', 'AX-AXISBK'),
        'Zerodha Broking',
      );
      expect(merchant('Rs 2,000.00 credited to a/c XX1234 on 16-11-26 by IMPS/P2A/631234567890/RAHUL KUMAR/SBIN. Bal Rs 5,000', 'AD-SBIINB'),
          'Rahul Kumar');
    });
  });
}
