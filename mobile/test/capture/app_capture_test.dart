import 'package:finance_tracker_mobile/capture/app_capture.dart';
import 'package:finance_tracker_mobile/capture/receipt_parser.dart';
import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/local/local_capture.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  late LocalDb db;
  late LocalCaptureService capture;
  final t0 = DateTime(2026, 11, 12, 10, 30);

  setUp(() {
    db = LocalDb.inMemory();
    capture = LocalCaptureService(db);
  });
  tearDown(() => db.close());

  group('UPI notification + bank SMS for one payment', () {
    test('are merged, and the SMS fills in account digits and UPI reference', () async {
      final accounts = LocalAccountsService(db);
      await accounts.create({'name': 'HDFC Savings', 'account_type': 'SAVINGS', 'balance': 5000});
      await accounts.create({'name': 'Cash', 'account_type': 'WALLET', 'balance': 500});
      final hdfc = (await accounts.list()).first['id'] as String;
      db.execute("UPDATE accounts SET last4 = '1234' WHERE id = ?", [hdfc]);

      final first = await capture.ingest([
        CapturedMessage(source: 'UPI_NOTIFICATION', sender: 'GPAY', body: 'You paid ₹250.00 to Swiggy', receivedAt: t0),
      ]);
      expect(first['added'], 1);
      var item = (await capture.pending()).single;
      expect(item['bank'], 'Google Pay');
      expect(item['account_id'], isNull); // two accounts, no digits yet

      final second = await capture.ingest([
        CapturedMessage(
          source: 'SMS',
          sender: 'AX-HDFCBK',
          body: 'Sent Rs.250.00 From HDFC Bank A/C *1234 To SWIGGY On 12/11/26 Ref 431234567890',
          receivedAt: t0.add(const Duration(minutes: 2)),
        ),
      ]);
      expect(second['added'], 0);
      expect(second['duplicates'], 1);

      item = (await capture.pending()).single;
      expect(item['description'], 'Swiggy');
      expect(item['account_last4'], '1234');
      expect(item['upi_ref'], '431234567890');
      expect(item['bank'], 'HDFC Bank');
      expect(item['account_id'], hdfc);
      // Now known by its UPI reference, so a screenshot of it is a duplicate too.
      final shot = await capture.ingest([
        CapturedMessage(
          source: 'SHARE',
          sender: 'SHARE',
          body: '…',
          receivedAt: DateTime(2026, 11, 20),
          parsed: const ParsedSms(type: 'EXPENSE', amount: 250, upiRef: '431234567890'),
        ),
      ]);
      expect(shot['duplicates'], 1);
    });
  });

  test('a shared screenshot keeps its own date and note', () async {
    final parsed = ReceiptParser.parse(const [
      OcrLine('Received from', 14),
      OcrLine('Rahul Sharma', 18),
      OcrLine('₹ 1,500', 56),
      OcrLine('01 Nov 2026, 08:15 PM', 12),
      OcrLine('UPI Ref No: 431234567892', 12),
      OcrLine('Note: Dinner split', 12),
    ])!;
    final result = await capture.ingest([
      CapturedMessage(source: 'SHARE', sender: 'SHARE', body: 'ocr text', receivedAt: DateTime(2026, 11, 23), parsed: parsed),
    ]);
    expect((result['ids'] as List).length, 1);
    final item = (await capture.pending()).single;
    expect(item['date'], '2026-11-01');
    expect(item['notes'], 'Dinner split');
    expect(item['type'], 'INCOME');
    expect(item['source'], 'SHARE');
    expect(item['description'], 'Rahul Sharma');
  });

  group('Share to Finverse screen', () {
    Widget app(Map<String, dynamic> item, {Future<List<OcrLine>> Function(String)? ocr}) => ChangeNotifierProvider(
          create: (_) => AppState(localServices(db).auth),
          child: MaterialApp(
            home: SharedPaymentScreen(item: item, capture: capture, ocr: ocr ?? (_) async => []),
          ),
        );

    final receipt = [
      const OcrLine('To SWIGGY', 22),
      const OcrLine('₹250', 64),
      const OcrLine('Completed', 16),
      const OcrLine('UPI transaction ID 431234567890', 12),
    ];

    testWidgets('a screenshot is read and added to the inbox; sharing it again is a duplicate', (tester) async {
      await tester.pumpWidget(app({'type': 'image', 'path': 'x.img'}, ocr: (_) async => receipt));
      await tester.pumpAndSettle();
      expect(find.text('Added to your review inbox'), findsOneWidget);
      expect(find.textContaining('Swiggy'), findsOneWidget);
      expect(await capture.pendingCount(), 1);

      await tester.pumpWidget(Container());
      await tester.pumpWidget(app({'type': 'image', 'path': 'x.img'}, ocr: (_) async => receipt));
      await tester.pumpAndSettle();
      expect(find.text('Already captured'), findsOneWidget);
      expect(await capture.pendingCount(), 1);
    });

    testWidgets('shared text (a forwarded bank SMS) works too', (tester) async {
      await tester.pumpWidget(app({'type': 'text', 'text': 'Rs.499.00 debited from A/c XX4321 at DECATHLON on 12-11-26.'}));
      await tester.pumpAndSettle();
      expect(find.text('Added to your review inbox'), findsOneWidget);
    });

    testWidgets('an image without a payment says so and shows what was read', (tester) async {
      await tester.pumpWidget(app({'type': 'image', 'path': 'x.img'}, ocr: (_) async => const [OcrLine('Holiday photo', 20)]));
      await tester.pumpAndSettle();
      expect(find.text('No payment found'), findsOneWidget);
      expect(find.text('Text that was read'), findsOneWidget);
      expect(await capture.pendingCount(), 0);
    });
  });
}
