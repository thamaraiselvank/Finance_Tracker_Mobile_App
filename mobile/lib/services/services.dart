/// The app's data layer: every screen talks to these interfaces, never to
/// HTTP or the database directly.
///
/// Today each interface is implemented by a `Remote…` class that calls the
/// Finverse backend (see `remote/remote_services.dart`). In the local-first
/// version each one is replaced by a `Local…` class backed by SQLite on the
/// phone, one area at a time, without changing the screens.
///
/// Data is passed as JSON-shaped maps ([Json]) with exactly the same keys the
/// backend returns today, so local implementations must produce the same shape.
library;

import '../capture/sms_parser.dart';

export '../capture/sms_parser.dart' show ParsedSms;

typedef Json = Map<String, dynamic>;

/// Sign-in and the user's profile.
abstract class AuthService {
  /// True for the cloud version (sign-in, password). False on the phone-only
  /// version, which has a local profile and an optional app lock instead.
  bool get hasAccounts;

  /// Called when the session can no longer be renewed (user must sign in again).
  set onSessionExpired(void Function()? callback);

  /// Loads a saved session. Returns true if one exists.
  Future<bool> restoreSession();
  Future<Json> currentUser();

  /// Returns the signed-in user.
  Future<Json> login(String usernameOrEmail, String password);

  /// Returns the new, signed-in user.
  Future<Json> register(Json payload);

  /// Returns the updated user.
  Future<Json> updateProfile(Json changes);
  Future<void> changePassword(String oldPassword, String newPassword);
  Future<void> signOut();
}

abstract class AccountsService {
  Future<List<Json>> list();
  Future<void> create(Json account);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
}

abstract class CategoriesService {
  Future<List<Json>> list();
}

abstract class TransactionsService {
  Future<List<Json>> list({DateTime? start, DateTime? end, String? type, int? limit});

  /// Income, expense and per-category totals for the period.
  Future<Json> summary({DateTime? start, DateTime? end});
  Future<void> create(Json transaction);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
}

abstract class BudgetsService {
  Future<List<Json>> forMonth(int month, int year);

  /// Creates or replaces the limit for one category in one month.
  Future<void> setLimit({required String categoryId, required double monthlyLimit, required int month, required int year});
}

abstract class AssetsService {
  /// All assets plus totals by class.
  Future<Json> summary();
  Future<void> create(Json asset);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
  Future<void> deleteAll();

  /// Fetches the latest public market prices. Returns a result with a `message`.
  Future<Json> refreshPrices();
}

abstract class GoalsService {
  Future<List<Json>> list();
  Future<Json> progressSummary();
  Future<void> create(Json goal);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
  Future<void> addContribution(String goalId, double amount);
}

abstract class DebtsService {
  Future<List<Json>> list();
  Future<Json> summary();

  /// Payoff plan for `avalanche` or `snowball`.
  Future<Json> payoffPlan(String strategy);
  Future<void> create(Json debt);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
}

abstract class InsuranceService {
  Future<List<Json>> list();
  Future<Json> summary();
  Future<void> create(Json policy);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
}

/// Recurring income and payments (rent, EMIs, salary, SIPs…).
abstract class SchedulesService {
  Future<List<Json>> list();
  Future<List<Json>> occurrences({required DateTime start, required DateTime end});
  Future<void> completeOccurrence(String scheduleId, DateTime occurrenceDate, {required double actualAmount, required DateTime actualDate});
  Future<void> create(Json schedule);
  Future<void> update(String id, Json changes);
  Future<void> delete(String id);
}

abstract class TaxService {
  /// Rules for the current tax year plus `available_tax_years`.
  Future<Json> rules();

  /// Values suggested from the user's own data for [taxYear].
  Future<Json> profile(String taxYear);
  Future<Json> estimate(Json input);
}

/// Kinds of calculator supported by [CalculatorsService.calculate].
enum CalculatorKind { sip, lumpsum, emi, cagr, fire }

abstract class CalculatorsService {
  Future<Json> calculate(CalculatorKind kind, Json input);
}

abstract class EssentialsService {
  /// Financial health score and checks (emergency fund, insurance, debt…).
  Future<Json> healthCheck();
}

/// Bank statement and broker holdings import.
abstract class ImportService {
  /// Reads a file and returns a preview (`preview` rows) without saving anything.
  /// [accountId] (statements, phone version) marks rows already in that account.
  Future<Json> parseFile({
    required List<int> bytes,
    required String filename,
    required String importType,
    String? broker,
    String? password,
    String? accountId,
  });

  /// Saves reviewed statement rows. Returns a result with a `message`.
  Future<dynamic> commitTransactions(String accountId, List<Json> transactions);

  /// Saves reviewed holdings. Returns a result with a `message`.
  Future<dynamic> commitAssets(List<Json> assets);
}

abstract class AiService {
  Future<Json> currentConversation();
  Future<List<Json>> conversations();
  Future<Json> conversation(String id);
  Future<Json> newConversation();
  Future<Json> quota();
  Future<Json> chat(String question, {String? conversationId});
  Future<Json> financialAssessment(Json answers);
}

/// A message that may describe a payment: a bank SMS today, later also UPI
/// app notifications and text shared to Finverse.
class CapturedMessage {
  const CapturedMessage({required this.source, required this.sender, required this.body, required this.receivedAt, this.parsed});

  /// 'SMS', 'UPI_NOTIFICATION' or 'SHARE' (same values as transactions.source).
  final String source;

  /// SMS sender ID ("AX-HDFCBK"), payment app code ("GPAY"), or "SHARE".
  final String sender;
  final String body;
  final DateTime receivedAt;

  /// Already read (screenshots, which need OCR line sizes). When null the
  /// body is parsed as message text.
  final ParsedSms? parsed;
}

/// Automatic capture and the review inbox (phone-only version).
///
/// Captured payments wait as *pending* until the user confirms (swipe right)
/// or ignores (swipe left) them. Only confirmed ones affect balances, totals
/// and budgets.
abstract class CaptureService {
  /// Parses the messages and adds new payments to the inbox. Returns counts:
  /// `read`, `added` (to the inbox), `auto_added` (straight to Money by a rule
  /// with "add automatically"), `auto_ignored` (rule says ignore),
  /// `duplicates`, `skipped` (not a payment), and `ids` (the new inbox items).
  Future<Json> ingest(List<CapturedMessage> messages);

  /// Pending transactions, newest first, in TransactionOut shape plus
  /// `merchant`, `bank`, `account_last4`, `upi_ref`, `raw_text`, `occurred_at`,
  /// `direction` (IN / OUT), `seen_via` (list of {source, label}),
  /// `suggest_source` (RULE / BUILTIN / GUESS / USER / null), `suggest_label`.
  Future<List<Json>> pending();

  /// What "payments like this one" means for a pending payment: `match_kind`
  /// (UPI / PARTY / TEMPLATE, or null when nothing can be recognised),
  /// `match_label`, `direction`, `other_pending` and `past` (confirmed) counts
  /// of matching payments, and the existing `rule` if any.
  Future<Json> similar(String id);

  /// Sets the type ('INCOME', 'EXPENSE', 'TRANSFER' or 'IGNORE') and category
  /// of a pending payment. With `remember`, saves a rule (optionally
  /// `auto_add`) and applies it to other waiting payments like it; with
  /// `apply_to_past`, also to confirmed ones (balances are corrected).
  /// Returns `pending_updated` and `past_updated` counts.
  Future<Json> classify(String id, Json choice);

  /// Learned rules, most recently used first, with category / account names.
  Future<List<Json>> rules();
  Future<void> updateRule(String id, Json changes);
  Future<void> deleteRule(String id);
  Future<int> pendingCount();

  /// Changes a pending transaction without confirming it (category, account,
  /// amount, type, description, date).
  Future<void> updatePending(String id, Json changes);

  /// Applies [changes] (optional) and confirms. Needs an account. Learns the
  /// type and category for payments with the same UPI ID / name, and the
  /// account's last digits, for next time.
  Future<void> confirm(String id, [Json changes = const {}]);

  /// Hides the payment. It is remembered, so the same SMS is never added again.
  Future<void> ignore(String id);

  /// Undo: puts a confirmed or ignored payment back in the inbox.
  Future<void> reopen(String id);

  /// Creates an account like "HDFC Bank ••1234" from a pending payment and
  /// assigns it to every pending payment with the same last digits.
  Future<String> createAccountFor(String id);

  /// When bank SMS were last read (null if never).
  Future<DateTime?> lastSmsScan();
  Future<void> setLastSmsScan(DateTime time);
}

/// Encrypted backup and restore of everything on the phone (phone-only
/// version). Backups are locked with the user's backup password, never with
/// the phone's own database key.
abstract class BackupService {
  /// Writes a backup of all data, locked with [password], to a new file in
  /// [directory]. Returns `path`, `file_name` and `summary` (`created_at`,
  /// `profile_name`, `counts`).
  Future<Json> create(String password, {required String directory});

  /// Opens the backup at [path] (a private copy: an older backup is upgraded
  /// in place) and returns its `summary`, without changing anything.
  /// Throws with a user-facing message for a wrong password or a bad file.
  Future<Json> inspect(String path, String password);

  /// Replaces everything on this phone with the backup at [path], in one
  /// step (on any error the phone keeps its data). Returns its `summary`.
  Future<Json> restore(String path, String password);
}

/// All services together, provided once at the top of the app.
class Services {
  const Services({
    required this.auth,
    required this.accounts,
    required this.categories,
    required this.transactions,
    required this.budgets,
    required this.assets,
    required this.goals,
    required this.debts,
    required this.insurance,
    required this.schedules,
    required this.tax,
    required this.calculators,
    required this.essentials,
    required this.imports,
    required this.ai,
    this.capture,
    this.backup,
  });

  final AuthService auth;
  final AccountsService accounts;
  final CategoriesService categories;
  final TransactionsService transactions;
  final BudgetsService budgets;
  final AssetsService assets;
  final GoalsService goals;
  final DebtsService debts;
  final InsuranceService insurance;
  final SchedulesService schedules;
  final TaxService tax;
  final CalculatorsService calculators;
  final EssentialsService essentials;
  final ImportService imports;
  final AiService ai;

  /// SMS capture and review inbox. Null in the cloud version.
  final CaptureService? capture;

  /// Encrypted backup and restore. Null in the cloud version (data is on the server).
  final BackupService? backup;
}
