import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/screens/insights_screen.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  late LocalDb db;
  late Services services;
  late AppState state;
  const food = '00000000-0000-0000-0000-000000000011';

  setUp(() async {
    db = LocalDb.inMemory();
    services = localServices(db);
    state = AppState(services.auth);
    final now = DateTime.now();
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 1000});
    final account = (await services.accounts.list()).single['id'];
    await services.budgets.setLimit(categoryId: food, monthlyLimit: 2000, month: now.month, year: now.year);
    await services.transactions.create({
      'account_id': account,
      'type': 'EXPENSE',
      'amount': 2500,
      'date': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'description': 'Big shop',
      'category_id': food,
    });
  });
  tearDown(() => db.close());

  Widget app() => MultiProvider(
        providers: [
          Provider<Services>.value(value: services),
          ChangeNotifierProvider<AppState>.value(value: state),
        ],
        child: const MaterialApp(home: InsightsScreen()),
      );

  testWidgets('shows insights, hides amounts on request, and swipes one away', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Food & Groceries is over budget'), findsOneWidget);
    expect(find.textContaining('₹2,500 of your ₹2,000 budget'), findsOneWidget);

    state.toggleHideAmounts();
    await tester.pumpAndSettle();
    expect(find.textContaining('₹2,500'), findsNothing);
    expect(find.textContaining('₹ •••• of your ₹ •••• budget'), findsOneWidget);

    await tester.drag(find.text('Food & Groceries is over budget'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Food & Groceries is over budget'), findsNothing);
    expect(find.text('All clear'), findsOneWidget);
    expect(await services.insights!.list(), isEmpty);
  });
}
