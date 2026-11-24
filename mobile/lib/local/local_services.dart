/// The local-mode (on-phone) service set.
///
/// Areas already moved to the phone use real SQLite implementations. The rest
/// throw [NotAvailableYetException] so the local build never mixes phone data
/// with server data. Each later step replaces one of the placeholders below.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import '../import/pdf_reader.dart';
import '../services/errors.dart';
import '../services/services.dart';
import 'assessment.dart';
import 'health_engine.dart';
import 'local_backup.dart';
import 'local_capture.dart';
import 'local_db.dart';
import 'local_import.dart';
import 'local_insights.dart';
import 'local_money.dart';
import 'local_planning.dart';
import 'local_plans.dart';
import 'local_wealth.dart';

export 'local_wealth.dart' show LocalAssetsService;
import 'py_round.dart';
import 'tax_estimator.dart';
import 'validate.dart';

/// Loads the bundled income-tax rules (assets/tax/*.json).
Future<TaxRules> loadTaxRules() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final files = manifest.listAssets().where((p) => p.startsWith('assets/tax/') && p.endsWith('.json'));
  return TaxRules([for (final f in files) jsonDecode(await rootBundle.loadString(f)) as Map<String, dynamic>]);
}

Services localServices(LocalDb db, {TaxRules? taxRules, StatementPdfReader pdfReader = const PdfiumStatementReader()}) => Services(
      auth: LocalProfileService(db),
      accounts: LocalAccountsService(db),
      categories: LocalCategoriesService(db),
      transactions: LocalTransactionsService(db),
      budgets: LocalBudgetsService(db),
      assets: LocalAssetsService(db),
      goals: LocalGoalsService(db),
      debts: LocalDebtsService(db),
      insurance: LocalInsuranceService(db),
      schedules: LocalSchedulesService(db),
      tax: taxRules == null ? const _PendingTax() : LocalTaxService(db, taxRules),
      calculators: const LocalCalculatorsService(),
      essentials: LocalEssentialsService(db),
      imports: LocalImportService(db, pdfReader: pdfReader),
      ai: const _PendingAi(),
      capture: LocalCaptureService(db),
      backup: LocalBackupService(db),
      insights: LocalInsightsService(db),
    );

// ---------------------------------------------------------------------------
// Profile  (replaces sign-in; routers/auth.py /me)
// ---------------------------------------------------------------------------

/// The phone has a single owner, so there is no account or password: just a
/// profile row (currency, income, age...) used by onboarding and planning.
class LocalProfileService implements AuthService {
  LocalProfileService(this._db);
  final LocalDb _db;

  static const _id = localUserId;

  @override
  bool get hasAccounts => false;

  @override
  set onSessionExpired(void Function()? callback) {}

  /// Creates the profile on first launch. There is always a "session".
  @override
  Future<bool> restoreSession() async {
    final now = nowTimestamp();
    _db.execute('INSERT OR IGNORE INTO profile (id, created_at, updated_at) VALUES (?, ?, ?)', [_id, now, now]);
    return true;
  }

  @override
  Future<Json> currentUser() async {
    await restoreSession();
    return _userOut(_db.queryOne('SELECT * FROM profile WHERE id = ?', [_id])!);
  }

  @override
  Future<Json> updateProfile(Json changes) async {
    await restoreSession();
    final columns = <String, Object?>{};
    if (changes.containsKey('full_name')) columns['full_name'] = readString(changes, 'full_name');
    if (changes.containsKey('currency')) columns['currency'] = readString(changes, 'currency') ?? 'INR';
    if (changes.containsKey('current_age')) columns['current_age'] = readInt(changes, 'current_age', required: true, ge: 0);
    if (changes.containsKey('target_retirement_age')) {
      columns['target_retirement_age'] = readInt(changes, 'target_retirement_age', required: true, ge: 0);
    }
    for (final (field, column) in const [
      ('monthly_income', 'monthly_income_minor'),
      ('monthly_expense', 'monthly_expense_minor'),
      ('emergency_fund_amount', 'emergency_fund_minor'),
    ]) {
      if (changes.containsKey(field)) columns[column] = toMinor(readNumber(changes, field, required: true, ge: 0)!);
    }
    if (changes.containsKey('target_savings_rate')) {
      columns['target_savings_rate'] = readNumber(changes, 'target_savings_rate', required: true, ge: 0);
    }
    if (changes.containsKey('dependents_count')) columns['dependents_count'] = readInt(changes, 'dependents_count', required: true, ge: 0);
    if (changes.containsKey('health_dependents')) {
      final value = changes['health_dependents'];
      if (value is! List) throw ValidationException('health_dependents', 'Input should be a valid list');
      columns['health_dependents'] = jsonEncode(value);
    }
    if (changes.containsKey('is_onboarded')) columns['is_onboarded'] = (readBool(changes, 'is_onboarded') ?? false) ? 1 : 0;

    if (columns.isNotEmpty) {
      columns['updated_at'] = nowTimestamp();
      _db.execute('UPDATE profile SET ${columns.keys.map((c) => '$c = ?').join(', ')} WHERE id = ?', [...columns.values, _id]);
    }
    return currentUser();
  }

  @override
  Future<Json> login(String usernameOrEmail, String password) => throw const ServiceException('Sign-in is not used in the offline version.');
  @override
  Future<Json> register(Json payload) => throw const ServiceException('Sign-in is not used in the offline version.');
  @override
  Future<void> changePassword(String oldPassword, String newPassword) =>
      throw const ServiceException('The offline version has no password. Use App lock instead.');
  @override
  Future<void> signOut() async {}

  /// Profile row -> the backend's UserOut shape.
  Json _userOut(Row r) => {
        'id': r['id'],
        'email': null,
        'username': null,
        'full_name': r['full_name'],
        'currency': r['currency'],
        'current_age': r['current_age'],
        'target_retirement_age': r['target_retirement_age'],
        'monthly_income': fromMinor(r['monthly_income_minor'] as int),
        'monthly_expense': fromMinor(r['monthly_expense_minor'] as int),
        'target_savings_rate': (r['target_savings_rate'] as num).toDouble(),
        'emergency_fund_amount': fromMinor(r['emergency_fund_minor'] as int),
        'dependents_count': r['dependents_count'],
        'health_dependents': jsonDecode(r['health_dependents'] as String),
        'is_onboarded': r['is_onboarded'] == 1,
        'created_at': r['created_at'],
      };
}

// ---------------------------------------------------------------------------
// Not moved to the phone yet. Each throws a clear "coming soon" message.
// ---------------------------------------------------------------------------

class _PendingTax implements TaxService {
  const _PendingTax();
  static const _na = NotAvailableYetException('Income tax estimate');
  @override
  Future<Json> rules() => throw _na;
  @override
  Future<Json> profile(String taxYear) => throw _na;
  @override
  Future<Json> estimate(Json input) => throw _na;
}

class _PendingAi implements AiService {
  const _PendingAi();
  static const _na = NotAvailableYetException('The AI advisor');
  @override
  Future<Json> currentConversation() => throw _na;
  @override
  Future<List<Json>> conversations() => throw _na;
  @override
  Future<Json> conversation(String id) => throw _na;
  @override
  Future<Json> newConversation() => throw _na;
  @override
  Future<Json> quota() => throw _na;
  @override
  Future<Json> chat(String question, {String? conversationId}) => throw _na;

  /// The check-up's score and next steps are rule-based, so they work fully
  /// on the phone (AI-written wording can be added with the AI step).
  @override
  Future<Json> financialAssessment(Json answers) async => offlineAssessment(answers);
}
