import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/core/pro.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/screens/calculators_screen.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  late LocalDb db;
  late Services services;
  setUp(() {
    db = LocalDb.inMemory();
    services = localServices(db);
  });
  tearDown(() => db.close());

  Widget app() => MultiProvider(
        providers: [
          Provider<Services>.value(value: services),
          ChangeNotifierProvider(create: (_) => AppState(services.auth)),
          ChangeNotifierProvider(create: (_) => ProStatus(forced: true)),
        ],
        child: const MaterialApp(home: CalculatorsScreen()),
      );

  Future<void> open(WidgetTester tester, String name) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  testWidgets('SIP shows results and charts straight away, and updates while typing', (tester) async {
    await open(tester, 'SIP');
    expect(find.text('Total value'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Year by year'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Where the final amount comes from'), findsOneWidget);
    expect(find.text('Year by year'), findsOneWidget);

    final before = tester.widget<Text>(find.descendant(of: find.widgetWithText(ListTile, 'Total value'), matching: find.byType(Text)).last).data;
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Monthly investment'), -300, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Monthly investment'), '20000');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final after = tester.widget<Text>(find.descendant(of: find.widgetWithText(ListTile, 'Total value'), matching: find.byType(Text)).last).data;
    expect(after, isNot(before));
  });

  testWidgets('EMI shows how the payments split and the loan left', (tester) async {
    await open(tester, 'EMI');
    await tester.scrollUntilVisible(find.text('Loan left to pay'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('What you pay back'), findsOneWidget);
    expect(find.text("Each year's payments"), findsOneWidget);
  });

  testWidgets('FIRE and CAGR draw their charts', (tester) async {
    await open(tester, 'FIRE');
    await tester.scrollUntilVisible(find.text('Your savings vs what you need'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('CAGR'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('Growing at'), 300, scrollable: find.byType(Scrollable).first);
  });
}
