import 'dart:convert';
import 'dart:io';

import 'package:finance_tracker_mobile/local/local_db.dart';
import 'package:finance_tracker_mobile/local/local_money.dart';
import 'package:finance_tracker_mobile/local/local_planning.dart';
import 'package:finance_tracker_mobile/local/local_services.dart';
import 'package:finance_tracker_mobile/local/tax_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDb db;
  late LocalTaxService tax;
  final rules = TaxRules([jsonDecode(File('assets/tax/india_tax_rules.json').readAsStringSync()) as Map<String, dynamic>]);

  setUp(() {
    db = LocalDb.inMemory();
    tax = LocalTaxService(db, rules, today: () => DateTime(2026, 11, 23));
  });
  tearDown(() => db.close());

  test('tax pre-fill uses the profile income and this tax year\'s transactions', () async {
    await LocalProfileService(db).updateProfile({'monthly_income': 100000, 'is_onboarded': true});
    final accounts = LocalAccountsService(db);
    await accounts.create({'name': 'Bank', 'account_type': 'SAVINGS', 'balance': 0});
    final account = (await accounts.list()).single['id'];
    final tx = LocalTransactionsService(db, today: () => DateTime(2026, 11, 23));
    Future<void> add(String type, double amount, String date, String description, {String? category}) =>
        tx.create({'account_id': account, 'type': type, 'amount': amount, 'date': date, 'description': description, 'category_id': category});

    const investments = '00000000-0000-0000-0000-000000000002';
    await add('INCOME', 4200, '2026-06-30', 'FD interest credited', category: investments);
    await add('INCOME', 1500, '2026-08-10', 'Dividend ITC', category: investments);
    await add('EXPENSE', 50000, '2026-05-02', 'PPF deposit');
    await add('EXPENSE', 18000, '2026-07-15', 'Star Health insurance premium');
    await add('INCOME', 9999, '2026-03-31', 'Interest from last tax year', category: investments);

    final p = await tax.profile('2026-27');
    expect(p['period_start'], '2026-04-01');
    expect(p['as_of'], '2026-11-23');
    final s = p['suggestions'] as Map;
    expect(s['salary_income']['value'], 1200000.0);
    expect(s['salary_income']['period'], 'annualized-profile');
    expect(s['interest_income']['value'], 4200.0);
    expect(s['dividend_income']['value'], 1500.0);
    expect(s['section_80c']['value'], 50000.0);
    expect(s['section_80d']['value'], 18000.0);
    expect(p['currency_warning'], isNull);
  });

  test('non-INR profiles get no money suggestions', () async {
    await LocalProfileService(db).updateProfile({'currency': 'USD', 'monthly_income': 5000});
    final p = await tax.profile('2026-27');
    expect(p['currency_warning'], contains('USD'));
    expect((p['suggestions'] as Map)['salary_income']['value'], 0.0);
  });

  test('unknown tax year is explained', () async {
    expect(() => tax.profile('1999-00'), throwsA(predicate((e) => e.toString() == 'No India tax rules are available for Tax Year 1999-00.')));
  });
}
