import 'package:finance_tracker_mobile/core/app_state.dart';
import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/screens/dashboard_screen.dart';
import 'package:finance_tracker_mobile/services/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

/// The Home screen with comparisons, at a real phone's width.
void main() {
  testWidgets('Home shows comparisons with last month without overflowing', (tester) async {
    final db = LocalDb.inMemory();
    addTearDown(db.close);
    final services = localServices(db);
    await services.accounts.create({'name': 'HDFC', 'account_type': 'SAVINGS', 'balance': 250000});
    final account = (await services.accounts.list()).single['id'];
    final now = DateTime.now();
    String day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    for (var back = 3; back >= 0; back--) {
      final m = DateTime(now.year, now.month - back, 1);
      await services.transactions.create({'account_id': account, 'type': 'INCOME', 'amount': 95000.0 + back * 1000, 'date': day(m), 'description': 'Salary', 'category_id': '00000000-0000-0000-0000-000000000001'});
      await services.transactions.create({'account_id': account, 'type': 'EXPENSE', 'amount': 41234.0 + back * 3000, 'date': day(m), 'description': 'Rent', 'category_id': '00000000-0000-0000-0000-000000000010'});
    }
    db.execute("INSERT INTO wealth_snapshots VALUES ('2026-01-01', 10000000, 10000000, 0, 0, 0)");

    tester.view.physicalSize = const Size(1080, 2400); // Redmi Note 11 Pro class
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<Services>.value(value: services),
        ChangeNotifierProvider(create: (_) => AppState(services.auth)),
      ],
      child: MaterialApp(home: DashboardScreen(onNavigate: (_) {})),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('since 1 Jan'), findsOneWidget);
    expect(find.text('Compare'), findsOneWidget);
    expect(find.textContaining(RegExp(r'[▲▼] .*% vs \w{3}')), findsWidgets);
    await tester.scrollUntilVisible(find.text('Previous months'), 300, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
}
