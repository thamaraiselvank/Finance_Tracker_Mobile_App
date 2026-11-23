import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/screens/review_inbox_screen.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  late LocalDb db;
  late Services services;
  final t0 = DateTime(2026, 11, 16, 10, 30);

  setUp(() {
    db = LocalDb.inMemory();
    services = localServices(db);
  });
  tearDown(() => db.close());

  Widget app() => MultiProvider(
        providers: [
          Provider<Services>.value(value: services),
          ChangeNotifierProvider(create: (_) => AppState(services.auth)),
        ],
        child: const MaterialApp(home: ReviewInboxScreen()),
      );

  testWidgets('cards show where a payment was seen and why it got its category', (tester) async {
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 1000});
    await services.capture!.ingest([
      CapturedMessage(
        source: 'SMS',
        sender: 'AX-HDFCBK',
        body: 'Update! INR 12,345.00 deposited in HDFC Bank A/c XX1234 on 15-NOV-26 for NEFT Cr-YESB0000001-ZERODHA BROKING LTD-ZERODHA-YESBN1234.',
        receivedAt: t0,
      ),
      CapturedMessage(source: 'UPI_NOTIFICATION', sender: 'GPAY', body: 'You paid ₹250.00 to Swiggy', receivedAt: t0.add(const Duration(hours: 1))),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('2 to review'), findsOneWidget);
    expect(find.text('SMS · HDFC Bank'), findsOneWidget);
    expect(find.text('Google Pay notification'), findsOneWidget);
    expect(find.text('Built-in: broker funds'), findsOneWidget);
    expect(find.text('own money'), findsOneWidget);
    expect(find.text('Guess · please check'), findsOneWidget); // Swiggy → Food, by keyword

    // Tapping the category opens "What is this payment?".
    await tester.tap(find.text('Food & Groceries'));
    await tester.pumpAndSettle();
    expect(find.text('What is this payment?'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Do the same for payments like this'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('Do the same for payments like this'), findsOneWidget);
    expect(find.textContaining('Recognised by name “Swiggy”'), findsOneWidget);
  });

  testWidgets('swiping right adds to Money and counts progress', (tester) async {
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 1000});
    await services.capture!.ingest([
      CapturedMessage(source: 'UPI_NOTIFICATION', sender: 'GPAY', body: 'You paid ₹250.00 to Swiggy', receivedAt: t0),
      CapturedMessage(source: 'UPI_NOTIFICATION', sender: 'GPAY', body: 'You paid ₹90.00 to Zomato', receivedAt: t0.add(const Duration(hours: 1))),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.drag(find.text('Zomato'), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Added to Money'), findsOneWidget);
    expect(find.text('1 done · 1 left'), findsOneWidget);
    expect((await services.accounts.list()).single['balance'], 910.0);

    await tester.drag(find.text('Swiggy'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('All caught up'), findsOneWidget);
    expect(find.textContaining('You reviewed 2 payments'), findsOneWidget);
  });
}
