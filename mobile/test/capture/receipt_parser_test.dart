import 'package:finance_tracker_mobile/capture/receipt_parser.dart';
import 'package:finance_tracker_mobile/capture/sms_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screenshot text as ML Kit returns it: one entry per line, top to bottom,
/// with the line's height in pixels. Layouts follow the common payment-app
/// success screens (written for these tests, not real screenshots).
List<OcrLine> lines(List<(String, double)> rows) => [for (final (t, h) in rows) OcrLine(t, h)];

void main() {
  group('payment screenshots', () {
    test('Google Pay: paid to a merchant', () {
      final p = ReceiptParser.parse(lines([
        ('To SWIGGY', 22),
        ('₹250', 64),
        ('Completed', 16),
        ('12 Nov 2026, 10:42 am', 14),
        ('UPI transaction ID', 12),
        ('431234567890', 14),
        ('To: SWIGGY', 14),
        ('swiggy@icici', 12),
        ('From: RAHUL SHARMA (HDFC Bank)', 14),
        ('XXXXXXXX1234', 12),
        ('Google transaction ID', 12),
        ('CICAgMDA4c2xLQ', 12),
      ]))!;
      expect(p.type, 'EXPENSE');
      expect(p.amount, 250);
      expect(p.merchant, 'Swiggy');
      expect(p.upiRef, '431234567890');
      expect(p.accountLast4, '1234');
      expect(p.bank, 'HDFC Bank');
      expect(p.occurredAt, DateTime(2026, 11, 12, 10, 42));
    });

    test('PhonePe: OCR misreads ₹ as Z, amount found by size', () {
      final p = ReceiptParser.parse(lines([
        ('Transaction Successful', 20),
        ('10:42 am on 12 Nov 2026', 14),
        ('Paid to', 14),
        ('Swiggy', 18),
        ('Z250', 40),
        ('Transfer Details', 14),
        ('Transaction ID', 12),
        ('T2611121042123456789', 12),
        ('Debited from', 12),
        ('XXXXXX1234', 14),
        ('₹250', 14),
        ('UTR: 431234567891', 12),
      ]))!;
      expect(p.type, 'EXPENSE');
      expect(p.amount, 250);
      expect(p.merchant, 'Swiggy');
      expect(p.upiRef, '431234567891');
      expect(p.accountLast4, '1234');
      expect(p.occurredAt!.day, 12);
    });

    test('Paytm: money received, with a note', () {
      final p = ReceiptParser.parse(lines([
        ('Received from', 14),
        ('Rahul Sharma', 18),
        ('₹ 1,500', 56),
        ('Money received in', 12),
        ('Paytm Payments Bank - 5566', 14),
        ('12 Nov 2026, 08:15 PM', 12),
        ('UPI Ref No: 431234567892', 12),
        ('Note: Dinner split', 12),
      ]))!;
      expect(p.type, 'INCOME');
      expect(p.amount, 1500);
      expect(p.merchant, 'Rahul Sharma');
      expect(p.accountLast4, '5566');
      expect(p.bank, 'Paytm Payments Bank');
      expect(p.note, 'Dinner split');
      expect(p.occurredAt, DateTime(2026, 11, 12, 20, 15));
    });

    test('BHIM: shop payment', () {
      final p = ReceiptParser.parse(lines([
        ('₹ 99.00', 48),
        ('Paid to', 14),
        ('SHARMA GENERAL STORE', 18),
        ('sharmastore@ybl', 12),
        ('Payment Successful', 16),
        ('UPI Ref. No: 431234567893', 12),
      ]))!;
      expect(p.amount, 99);
      expect(p.merchant, 'Sharma General Store');
      expect(p.upiRef, '431234567893');
    });

    test('failed, pending and non-payment images are not added', () {
      expect(ReceiptParser.parse(lines([('Payment failed', 20), ('₹500', 50), ('To Swiggy', 14)])), isNull);
      expect(ReceiptParser.parse(lines([('Payment pending', 20), ('₹500', 50), ('To Swiggy', 14)])), isNull);
      expect(ReceiptParser.parse(lines([('Electricity Bill', 20), ('Amount due', 14), ('₹1,240', 40), ('Due date 05 Dec 2026', 12)])), isNull);
      expect(ReceiptParser.parse(lines([('Holiday photo', 20)])), isNull);
      expect(ReceiptParser.parse([]), isNull);
    });

    test('long ids and years are never taken as the amount', () {
      final p = ReceiptParser.parse(lines([
        ('Paid to', 14),
        ('Uber', 18),
        ('431234567890', 30),
        ('2026', 30),
        ('₹ 312', 28),
        ('Completed', 14),
      ]))!;
      expect(p.amount, 312);
    });
  });

  group('payment app notifications', () {
    ParsedSms? n(String sender, String text) => SmsParser.parse(sender, text, fromPaymentApp: true);

    test('money out and in', () {
      final paid = n('GPAY', 'You paid ₹250.00 to Swiggy')!;
      expect((paid.type, paid.amount, paid.merchant, paid.bank), ('EXPENSE', 250.0, 'Swiggy', 'Google Pay'));

      final got = n('GPAY', 'Rahul Sharma paid you ₹500.00')!;
      expect((got.type, got.amount, got.merchant), ('INCOME', 500.0, 'Rahul Sharma'));

      final phonepe = n('PHONEPE', 'Received ₹1,200 from Anita Desai. Paid to your account linked with PhonePe')!;
      expect((phonepe.type, phonepe.amount, phonepe.merchant), ('INCOME', 1200.0, 'Anita Desai'));

      final paytm = n('PAYTM', 'Paid Rs.180 to Uber India. Txn ID 2611121234')!;
      expect((paytm.type, paytm.amount, paytm.merchant), ('EXPENSE', 180.0, 'Uber India'));
    });

    test('rewards, pending payments and reminders are ignored', () {
      expect(n('GPAY', 'You won ₹10 cashback! Your scratch card is waiting'), isNull);
      expect(n('PHONEPE', 'Payment of ₹300 to Swiggy is pending'), isNull);
      expect(n('PAYTM', 'Pay your electricity bill of ₹1,240 now'), isNull);
    });

    test('the same wording from an unknown SMS sender is still rejected', () {
      expect(SmsParser.parse('VM-RANDOM', 'You paid ₹250.00 to Swiggy'), isNull);
    });
  });
}
