import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/core/pro.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/screens/transactions_tab.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:finance_tracker_mobile/widgets/transaction_tile.dart';
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

  testWidgets('tapping a category shows its subcategories; tapping one filters the list', (tester) async {
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 100000});
    final account = (await services.accounts.list()).single['id'];
    final food = (await services.categories.list()).firstWhere((c) => c['name'] == 'Food & Groceries');
    final subs = {for (final s in food['subcategories'] as List) s['name']: s['id']};
    final today = DateTime.now();
    final date = '${today.year}-${today.month.toString().padLeft(2, '0')}-01';
    for (final (desc, amount, sub) in [('Big Bazaar', 3000, 'Daily Groceries'), ('Pizza', 1000, 'Dining Out'), ('Cafe', 500, 'Dining Out')]) {
      await services.transactions.create({
        'account_id': account, 'category_id': food['id'], 'subcategory_id': subs[sub], 'type': 'EXPENSE',
        'amount': amount, 'date': date, 'description': desc,
      });
    }

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<Services>.value(value: services),
        ChangeNotifierProvider(create: (_) => AppState(services.auth)),
        ChangeNotifierProvider(create: (_) => ProStatus(forced: true)),
      ],
      child: const MaterialApp(home: Scaffold(body: TransactionsTab())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Daily Groceries  ·  1'), findsNothing);

    await tester.tap(find.text('Food & Groceries  ·  3'));
    await tester.pumpAndSettle();
    expect(find.text('Daily Groceries  ·  1'), findsOneWidget);
    expect(find.text('Dining Out  ·  2'), findsOneWidget);

    await tester.ensureVisible(find.text('Dining Out  ·  2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dining Out  ·  2'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Food & Groceries · Dining Out'), 200, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text('Cafe'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byType(TransactionTile), findsNWidgets(2));
  });
}
