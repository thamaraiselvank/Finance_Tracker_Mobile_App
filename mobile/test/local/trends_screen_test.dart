import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/screens/compare_screen.dart';
import 'package:finance_tracker_mobile/screens/trends_screen.dart';
import 'package:finance_tracker_mobile/screens/wealth_screen.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  late LocalDb db;
  late Services services;

  setUp(() async {
    db = LocalDb.inMemory();
    services = localServices(db);
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 1000});
    final account = (await services.accounts.list()).single['id'];
    final now = DateTime.now();
    String day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    for (final (date, type, amount, category) in [
      (lastMonth, 'INCOME', 50000.0, '00000000-0000-0000-0000-000000000001'),
      (lastMonth, 'EXPENSE', 12000.0, '00000000-0000-0000-0000-000000000011'),
      (DateTime(now.year, now.month, 1), 'EXPENSE', 3000.0, '00000000-0000-0000-0000-000000000011'),
    ]) {
      await services.transactions.create({'account_id': account, 'type': type, 'amount': amount, 'date': day(date), 'description': 'x', 'category_id': category});
    }
  });
  tearDown(() => db.close());

  testWidgets('trends page shows the comparison, months, categories and totals', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<Services>.value(value: services),
        ChangeNotifierProvider(create: (_) => AppState(services.auth)),
      ],
      child: const MaterialApp(home: TrendsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Earned'), findsWidgets);
    expect(find.text('Month by month'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Food & Groceries'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.textContaining(RegExp(r'^All of \w{3}$')));
    await tester.pumpAndSettle();
    expect(find.textContaining('₹12,000 · 100%'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Since you started'), 300, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text('Average spent a month'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('₹50,000'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  Widget app(Widget home) => MultiProvider(
        providers: [
          Provider<Services>.value(value: services),
          ChangeNotifierProvider(create: (_) => AppState(services.auth)),
        ],
        child: MaterialApp(home: home),
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets('compare months: totals, categories open to subcategories and payees, income', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const CompareMonthsScreen()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Totals'), findsOneWidget);
    expect(find.text('Same days only'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Food & Groceries'), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food & Groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Paid to'), findsOneWidget);
    await tester.tap(find.byTooltip('Swap'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    expect(find.text('Income by category'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wealth screen shows net worth over time, health, holdings and accounts', (tester) async {
    phone(tester);
    await services.assets.create({'name': 'Nifty fund', 'asset_class': 'MUTUAL_FUND', 'invested_amount': 100000, 'current_value': 130000});
    await services.assets.create({'name': 'XYZ Ltd', 'asset_class': 'EQUITY', 'invested_amount': 50000, 'current_value': 40000});
    db.execute("INSERT INTO wealth_snapshots (date, net_worth_minor, assets_minor, liabilities_minor, invested_minor, holdings_minor) VALUES ('2026-01-01', 10000000, 10000000, 0, 0, 0)");
    await tester.pumpWidget(app(const WealthScreen()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Net worth over time'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Where your money sits'), 300, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text('Doing best'), 300, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text('Down so far'), 300, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text('Accounts'), 300, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
}
