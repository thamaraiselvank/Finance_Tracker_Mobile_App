/// Implementations of the service interfaces that call the Finverse backend.
///
/// These are temporary: each one is replaced by a local (SQLite) version as
/// the app moves to local-first. They send exactly the same requests the
/// screens used to send themselves.
library;

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../services.dart';

Json _map(dynamic data) => data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

List<Json> _list(dynamic data) =>
    data is List ? data.map((e) => Map<String, dynamic>.from(e as Map)).toList() : <Json>[];

/// Builds the full set of services backed by the given [ApiClient].
Services remoteServices(ApiClient api) => Services(
      auth: RemoteAuthService(api),
      accounts: RemoteAccountsService(api),
      categories: RemoteCategoriesService(api),
      transactions: RemoteTransactionsService(api),
      budgets: RemoteBudgetsService(api),
      assets: RemoteAssetsService(api),
      goals: RemoteGoalsService(api),
      debts: RemoteDebtsService(api),
      insurance: RemoteInsuranceService(api),
      schedules: RemoteSchedulesService(api),
      tax: RemoteTaxService(api),
      calculators: RemoteCalculatorsService(api),
      essentials: RemoteEssentialsService(api),
      imports: RemoteImportService(api),
      ai: RemoteAiService(api),
    );

class RemoteAuthService implements AuthService {
  RemoteAuthService(this._api);
  final ApiClient _api;

  @override
  bool get hasAccounts => true;

  @override
  set onSessionExpired(void Function()? callback) => _api.onSessionExpired = callback;

  @override
  Future<bool> restoreSession() async {
    await _api.loadTokens();
    return _api.hasSession;
  }

  @override
  Future<Json> currentUser() async => _map(await _api.get('/auth/me'));

  @override
  Future<Json> login(String usernameOrEmail, String password) async => _completeSignIn(
        await _api.post('/auth/login', body: {'username_or_email': usernameOrEmail.trim(), 'password': password}),
      );

  @override
  Future<Json> register(Json payload) async => _completeSignIn(await _api.post('/auth/register', body: payload));

  Future<Json> _completeSignIn(dynamic data) async {
    await _api.saveTokens(access: data['access_token'], refresh: data['refresh_token']);
    return _map(data['user']);
  }

  @override
  Future<Json> updateProfile(Json changes) async => _map(await _api.put('/auth/me', body: changes));

  @override
  Future<void> changePassword(String oldPassword, String newPassword) =>
      _api.post('/auth/change-password', body: {'old_password': oldPassword, 'new_password': newPassword});

  @override
  Future<void> signOut() => _api.clearTokens();
}

class RemoteAccountsService implements AccountsService {
  RemoteAccountsService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list() async => _list(await _api.get('/accounts'));
  @override
  Future<void> create(Json account) => _api.post('/accounts', body: account);
  @override
  Future<void> update(String id, Json changes) => _api.put('/accounts/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/accounts/$id');
}

class RemoteCategoriesService implements CategoriesService {
  RemoteCategoriesService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list() async => _list(await _api.get('/categories'));
}

class RemoteTransactionsService implements TransactionsService {
  RemoteTransactionsService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list({DateTime? start, DateTime? end, String? type, int? limit}) async => _list(await _api.get('/transactions', query: {
        if (start != null) 'start_date': apiDate(start),
        if (end != null) 'end_date': apiDate(end),
        'type': ?type,
        'limit': ?limit,
      }));

  @override
  Future<Json> summary({DateTime? start, DateTime? end}) async => _map(await _api.get('/transactions/summary', query: {
        if (start != null) 'start_date': apiDate(start),
        if (end != null) 'end_date': apiDate(end),
      }));

  @override
  Future<void> create(Json transaction) => _api.post('/transactions', body: transaction);
  @override
  Future<void> update(String id, Json changes) => _api.put('/transactions/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/transactions/$id');
}

class RemoteBudgetsService implements BudgetsService {
  RemoteBudgetsService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> forMonth(int month, int year) async => _list(await _api.get('/budgets', query: {'month': month, 'year': year}));

  @override
  Future<void> setLimit({required String categoryId, required double monthlyLimit, required int month, required int year}) =>
      _api.put('/budgets', body: {'category_id': categoryId, 'monthly_limit': monthlyLimit, 'month': month, 'year': year});
}

class RemoteAssetsService implements AssetsService {
  RemoteAssetsService(this._api);
  final ApiClient _api;

  @override
  Future<Json> summary() async => _map(await _api.get('/assets/summary'));
  @override
  Future<void> create(Json asset) => _api.post('/assets', body: asset);
  @override
  Future<void> update(String id, Json changes) => _api.put('/assets/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/assets/$id');
  @override
  Future<void> deleteAll() => _api.delete('/assets/all');
  @override
  Future<Json> refreshPrices() async => _map(await _api.post('/assets/refresh-prices'));
}

class RemoteGoalsService implements GoalsService {
  RemoteGoalsService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list() async => _list(await _api.get('/goals/'));
  @override
  Future<Json> progressSummary() async => _map(await _api.get('/goals/summary/progress'));
  @override
  Future<void> create(Json goal) => _api.post('/goals/', body: goal);
  @override
  Future<void> update(String id, Json changes) => _api.put('/goals/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/goals/$id');
  @override
  Future<void> addContribution(String goalId, double amount) => _api.post('/goals/$goalId/contributions', body: {'amount': amount});
}

class RemoteDebtsService implements DebtsService {
  RemoteDebtsService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list() async => _list(await _api.get('/debts/'));
  @override
  Future<Json> summary() async => _map(await _api.get('/debts/summary/overview'));
  @override
  Future<Json> payoffPlan(String strategy) async => _map(await _api.get('/debts/strategy/$strategy'));
  @override
  Future<void> create(Json debt) => _api.post('/debts/', body: debt);
  @override
  Future<void> update(String id, Json changes) => _api.put('/debts/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/debts/$id');
}

class RemoteInsuranceService implements InsuranceService {
  RemoteInsuranceService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list() async => _list(await _api.get('/insurance/'));
  @override
  Future<Json> summary() async => _map(await _api.get('/insurance/summary/overview'));
  @override
  Future<void> create(Json policy) => _api.post('/insurance/', body: policy);
  @override
  Future<void> update(String id, Json changes) => _api.put('/insurance/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/insurance/$id');
}

class RemoteSchedulesService implements SchedulesService {
  RemoteSchedulesService(this._api);
  final ApiClient _api;

  @override
  Future<List<Json>> list() async => _list(await _api.get('/schedules'));

  @override
  Future<List<Json>> occurrences({required DateTime start, required DateTime end}) async =>
      _list(await _api.get('/schedules/occurrences', query: {'start_date': apiDate(start), 'end_date': apiDate(end)}));

  @override
  Future<void> completeOccurrence(String scheduleId, DateTime occurrenceDate, {required double actualAmount, required DateTime actualDate}) =>
      _api.post('/schedules/$scheduleId/occurrences/${apiDate(occurrenceDate)}/complete', body: {
        'actual_amount': actualAmount,
        'actual_date': apiDate(actualDate),
      });

  @override
  Future<void> create(Json schedule) => _api.post('/schedules', body: schedule);
  @override
  Future<void> update(String id, Json changes) => _api.put('/schedules/$id', body: changes);
  @override
  Future<void> delete(String id) => _api.delete('/schedules/$id');
}

class RemoteTaxService implements TaxService {
  RemoteTaxService(this._api);
  final ApiClient _api;

  @override
  Future<Json> rules() async => _map(await _api.get('/tax/rules'));
  @override
  Future<Json> profile(String taxYear) async => _map(await _api.get('/tax/profile', query: {'tax_year': taxYear}));
  @override
  Future<Json> estimate(Json input) async => _map(await _api.post('/tax/estimate', body: input));
}

class RemoteCalculatorsService implements CalculatorsService {
  RemoteCalculatorsService(this._api);
  final ApiClient _api;

  @override
  Future<Json> calculate(CalculatorKind kind, Json input) async => _map(await _api.post('/calculators/${kind.name}', body: input));
}

class RemoteEssentialsService implements EssentialsService {
  RemoteEssentialsService(this._api);
  final ApiClient _api;

  @override
  Future<Json> healthCheck() async => _map(await _api.get('/essentials/health-check'));
}

class RemoteImportService implements ImportService {
  RemoteImportService(this._api);
  final ApiClient _api;

  @override
  Future<Json> parseFile({required List<int> bytes, required String filename, required String importType, String? broker, String? password}) async =>
      _map(await _api.postFile('/import/parse-file', bytes: bytes, filename: filename, fields: {
        'import_type': importType,
        'broker': ?broker,
        'password': ?password,
      }));

  @override
  Future<dynamic> commitTransactions(String accountId, List<Json> transactions) =>
      _api.post('/import/commit', body: {'account_id': accountId, 'transactions': transactions});

  @override
  Future<dynamic> commitAssets(List<Json> assets) => _api.post('/import/commit-assets', body: {'assets': assets});
}

class RemoteAiService implements AiService {
  RemoteAiService(this._api);
  final ApiClient _api;

  @override
  Future<Json> currentConversation() async => _map(await _api.get('/ai/conversations/current'));
  @override
  Future<List<Json>> conversations() async => _list(await _api.get('/ai/conversations'));
  @override
  Future<Json> conversation(String id) async => _map(await _api.get('/ai/conversations/$id'));
  @override
  Future<Json> newConversation() async => _map(await _api.post('/ai/conversations'));
  @override
  Future<Json> quota() async => _map(await _api.get('/ai/quota'));

  @override
  Future<Json> chat(String question, {String? conversationId}) async => _map(await _api.post('/ai/chat', body: {
        'question': question,
        'conversation_id': ?conversationId,
      }));

  @override
  Future<Json> financialAssessment(Json answers) async => _map(await _api.post('/ai/financial-assessment', body: {'answers': answers}));
}
