import 'package:sqlite3/sqlite3.dart';

import '../capture/rules.dart';

/// Database schema, as an ordered list of migrations.
///
/// The database stores how many have run in `PRAGMA user_version`; on open,
/// any newer ones run in order inside a transaction. Never edit a migration
/// that has shipped: add a new one at the end instead.
///
/// Conventions (differences from the PostgreSQL schema in backend/db):
///  * Money is stored as whole minor units (paise/cents) in `*_minor`
///    INTEGER columns, so balances never drift through float rounding.
///  * Dates are 'YYYY-MM-DD' TEXT; timestamps are ISO-8601 UTC TEXT.
///  * Booleans are INTEGER 0/1.
///  * There is no users table or user_id column: the phone has one owner.
///    The single `profile` row replaces `users`.
const List<String> migrations = [_v1, _v2, _v3, _v4, _v5, _v6];

void migrate(Database db) {
  final current = db.select('PRAGMA user_version').first.values.first as int;
  for (var version = current; version < migrations.length; version++) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(migrations[version]);
      if (version == 0) _seedCategories(db);
      if (version == 4) _backfillV5(db);
      db.execute('PRAGMA user_version = ${version + 1}');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

const _v1 = '''
CREATE TABLE profile (
  id TEXT PRIMARY KEY,
  full_name TEXT,
  currency TEXT NOT NULL DEFAULT 'INR',
  current_age INTEGER NOT NULL DEFAULT 28,
  target_retirement_age INTEGER NOT NULL DEFAULT 50,
  monthly_income_minor INTEGER NOT NULL DEFAULT 0,
  monthly_expense_minor INTEGER NOT NULL DEFAULT 0,
  target_savings_rate REAL NOT NULL DEFAULT 30,
  emergency_fund_minor INTEGER NOT NULL DEFAULT 0,
  dependents_count INTEGER NOT NULL DEFAULT 0,
  health_dependents TEXT NOT NULL DEFAULT '[]',
  is_onboarded INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Small key/value store for app settings (app lock, last SMS scan, ...).
CREATE TABLE app_settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('INCOME', 'EXPENSE', 'TRANSFER')),
  icon TEXT DEFAULT 'Tag',
  color TEXT DEFAULT '#10B981',
  is_system INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE subcategories (
  id TEXT PRIMARY KEY,
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_subcategories_category ON subcategories(category_id);

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  account_type TEXT NOT NULL CHECK (account_type IN ('SAVINGS', 'CURRENT', 'CREDIT_CARD', 'WALLET', 'FIXED_DEPOSIT', 'INVESTMENT', 'OTHER')),
  balance_minor INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'INR',
  institution TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE transactions (
  id TEXT PRIMARY KEY,
  account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
  subcategory_id TEXT REFERENCES subcategories(id) ON DELETE SET NULL,
  type TEXT NOT NULL CHECK (type IN ('INCOME', 'EXPENSE', 'TRANSFER')),
  amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
  date TEXT NOT NULL,
  description TEXT NOT NULL,
  notes TEXT,
  tags TEXT,
  scheduled_cashflow_id TEXT,
  scheduled_occurrence_date TEXT,
  -- Automatic capture (SMS, UPI notifications, Share to Finverse).
  -- Only CONFIRMED transactions count towards balances, totals and budgets;
  -- PENDING ones wait in the review inbox, IGNORED ones are kept so the same
  -- message is not captured twice.
  source TEXT NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL', 'SMS', 'UPI_NOTIFICATION', 'SHARE', 'IMPORT', 'SCHEDULE')),
  status TEXT NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN ('PENDING', 'CONFIRMED', 'IGNORED')),
  merchant TEXT,
  upi_ref TEXT,
  account_last4 TEXT,
  raw_text TEXT,
  dedup_key TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_transactions_date ON transactions(status, date DESC, created_at DESC);
CREATE INDEX idx_transactions_account ON transactions(account_id);
CREATE INDEX idx_transactions_category ON transactions(category_id);
CREATE UNIQUE INDEX idx_transactions_dedup ON transactions(dedup_key) WHERE dedup_key IS NOT NULL;
CREATE UNIQUE INDEX idx_transactions_scheduled_occurrence
  ON transactions(scheduled_cashflow_id, scheduled_occurrence_date)
  WHERE scheduled_cashflow_id IS NOT NULL AND scheduled_occurrence_date IS NOT NULL;

CREATE TABLE budgets (
  id TEXT PRIMARY KEY,
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  monthly_limit_minor INTEGER NOT NULL DEFAULT 0,
  month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
  year INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (category_id, month, year)
);
''';

/// v2: automatic capture from SMS (and later UPI notifications / Share).
const _v2 = '''
-- Exact time of a captured payment (for spotting the same payment twice),
-- the bank it came from, and a normalised merchant name for learned rules.
ALTER TABLE transactions ADD COLUMN occurred_at TEXT;
ALTER TABLE transactions ADD COLUMN bank TEXT;
ALTER TABLE transactions ADD COLUMN merchant_key TEXT;
CREATE INDEX idx_transactions_occurred ON transactions(amount_minor, occurred_at);

-- Last digits of the bank account / card, learned when the user confirms a
-- captured transaction, so later SMS go to the right account automatically.
ALTER TABLE accounts ADD COLUMN last4 TEXT;

-- "Swiggy is Food": remembered from the user's choices in the review inbox.
CREATE TABLE merchant_rules (
  merchant_key TEXT PRIMARY KEY,
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  subcategory_id TEXT REFERENCES subcategories(id) ON DELETE SET NULL,
  hits INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);
''';

/// v3: goals, debts and insurance policies (step 4b). The backend's older
/// duplicate tables (`liabilities`, `insurances`) are not carried over: on the
/// phone every loan is a debt and every policy an insurance policy.
const _v3 = '''
CREATE TABLE goals (
  id TEXT PRIMARY KEY,
  goal_name TEXT NOT NULL,
  goal_type TEXT NOT NULL CHECK (goal_type IN ('RETIREMENT', 'DOWN_PAYMENT', 'DEBT_PAYOFF', 'WEALTH_BUILD', 'EDUCATION', 'VACATION', 'BUSINESS', 'EMERGENCY_FUND', 'OTHER')),
  target_amount_minor INTEGER NOT NULL,
  current_amount_minor INTEGER NOT NULL DEFAULT 0,
  target_date TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 3,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PAUSED', 'COMPLETED', 'ABANDONED')),
  suggested_monthly_minor INTEGER NOT NULL DEFAULT 0,
  allocated_monthly_minor INTEGER NOT NULL DEFAULT 0,
  progress_percentage REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE goal_contributions (
  id TEXT PRIMARY KEY,
  goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
  amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
  contributed_at TEXT NOT NULL
);
CREATE INDEX idx_goal_contributions_goal ON goal_contributions(goal_id, contributed_at);

CREATE TABLE debts (
  id TEXT PRIMARY KEY,
  debt_name TEXT NOT NULL,
  debt_type TEXT NOT NULL CHECK (debt_type IN ('CREDIT_CARD', 'PERSONAL_LOAN', 'HOME_LOAN', 'CAR_LOAN', 'EDUCATION_LOAN', 'GOLD_LOAN', 'BUSINESS_LOAN', 'OTHER')),
  principal_minor INTEGER NOT NULL,
  current_outstanding_minor INTEGER NOT NULL,
  interest_rate_pct REAL NOT NULL,
  tenure_months INTEGER,
  monthly_emi_minor INTEGER,
  start_date TEXT,
  end_date TEXT,
  creditor_name TEXT,
  priority_payoff INTEGER NOT NULL DEFAULT 0,
  payoff_strategy TEXT NOT NULL DEFAULT 'STANDARD' CHECK (payoff_strategy IN ('SNOWBALL', 'AVALANCHE', 'STANDARD')),
  total_interest_paid_minor INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE insurance_policies (
  id TEXT PRIMARY KEY,
  policy_name TEXT NOT NULL,
  policy_type TEXT NOT NULL CHECK (policy_type IN ('HEALTH', 'TERM_LIFE', 'MOTOR', 'HOME', 'TRAVEL', 'CRITICAL_ILLNESS', 'OTHER')),
  sum_insured_minor INTEGER NOT NULL,
  annual_premium_minor INTEGER NOT NULL,
  policy_number TEXT,
  start_date TEXT,
  maturity_date TEXT,
  renewal_date TEXT,
  coverage_type TEXT,
  dependents_covered INTEGER NOT NULL DEFAULT 0,
  insurer_name TEXT,
  payment_frequency TEXT NOT NULL DEFAULT 'YEARLY',
  payment_status TEXT NOT NULL DEFAULT 'PENDING',
  next_payment_date TEXT,
  last_payment_date TEXT,
  agent_name TEXT,
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'EXPIRED', 'LAPSED', 'RENEWED')),
  document_url TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''';

/// v4: investment holdings and Bills & recurring (step 4c).
const _v4 = '''
CREATE TABLE assets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  asset_class TEXT NOT NULL CHECK (asset_class IN ('EQUITY', 'MUTUAL_FUND', 'COMMODITY_GOLD', 'REAL_ESTATE', 'CASH_EQUIVALENT', 'FIXED_INCOME', 'CRYPTO', 'OTHER')),
  sub_type TEXT,
  invested_minor INTEGER NOT NULL DEFAULT 0,
  current_value_minor INTEGER NOT NULL DEFAULT 0,
  quantity REAL DEFAULT 1,
  buy_price_minor INTEGER DEFAULT 0,
  current_price_minor INTEGER DEFAULT 0,
  purchase_date TEXT,
  notes TEXT,
  meta_data TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_assets_class ON assets(asset_class);

-- Planned income and payments; recording one creates a transaction that
-- points back here (transactions.scheduled_cashflow_id / _occurrence_date).
CREATE TABLE scheduled_cashflows (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
  category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
  asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  description TEXT NOT NULL,
  flow_type TEXT NOT NULL CHECK (flow_type IN ('INCOME', 'EXPENSE')),
  source_type TEXT NOT NULL DEFAULT 'OTHER' CHECK (source_type IN ('BILL', 'SUBSCRIPTION', 'EMI', 'INSURANCE_PREMIUM', 'SALARY', 'RENTAL_INCOME', 'DIVIDEND', 'INTEREST', 'OTHER')),
  amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
  amount_is_estimate INTEGER NOT NULL DEFAULT 0,
  frequency TEXT NOT NULL CHECK (frequency IN ('WEEKLY', 'MONTHLY', 'QUARTERLY', 'YEARLY')),
  interval_count INTEGER NOT NULL DEFAULT 1 CHECK (interval_count BETWEEN 1 AND 12),
  start_date TEXT NOT NULL,
  end_date TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  debt_id TEXT REFERENCES debts(id) ON DELETE CASCADE,
  insurance_policy_id TEXT REFERENCES insurance_policies(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (end_date IS NULL OR end_date >= start_date)
);
CREATE INDEX idx_scheduled_active ON scheduled_cashflows(is_active, start_date);
''';

/// v5: rules that learn more than a category (step 3.5), and transfers of
/// the user's own money that move a balance without being income/spending.
const _v5 = '''
-- Which way a transfer moved money for its account: IN (e.g. broker
-- settlement received) or OUT (e.g. adding funds to the broker). NULL for
-- transfers entered by hand, which (as on the web app) don't move a balance.
ALTER TABLE transactions ADD COLUMN direction TEXT CHECK (direction IN ('IN', 'OUT'));
-- How a captured payment can be recognised again (see capture/rules.dart).
ALTER TABLE transactions ADD COLUMN vpa TEXT;
ALTER TABLE transactions ADD COLUMN template_key TEXT;
-- Why the type / category were chosen: RULE (learned), BUILTIN, GUESS
-- (keyword), USER (changed in the inbox); with a short label to show.
ALTER TABLE transactions ADD COLUMN rule_id TEXT;
ALTER TABLE transactions ADD COLUMN suggest_source TEXT;
ALTER TABLE transactions ADD COLUMN suggest_label TEXT;
-- Where the payment was seen, e.g. "SMS:HDFC Bank|UPI_NOTIFICATION:Google Pay".
ALTER TABLE transactions ADD COLUMN seen_via TEXT;

UPDATE transactions SET direction = CASE type WHEN 'INCOME' THEN 'IN' WHEN 'EXPENSE' THEN 'OUT' END
WHERE source IN ('SMS', 'UPI_NOTIFICATION', 'SHARE');
UPDATE transactions SET seen_via = source || COALESCE(':' || bank, '') WHERE source IN ('SMS', 'UPI_NOTIFICATION', 'SHARE');
UPDATE transactions SET suggest_source = 'GUESS' WHERE status = 'PENDING' AND category_id IS NOT NULL;

-- "Payments like this are <type> · <category>, from <account>".
CREATE TABLE capture_rules (
  id TEXT PRIMARY KEY,
  match_kind TEXT NOT NULL CHECK (match_kind IN ('UPI', 'PARTY', 'TEMPLATE')),
  match_value TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('IN', 'OUT')),
  type TEXT NOT NULL CHECK (type IN ('INCOME', 'EXPENSE', 'TRANSFER', 'IGNORE')),
  category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
  subcategory_id TEXT REFERENCES subcategories(id) ON DELETE SET NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  auto_add INTEGER NOT NULL DEFAULT 0,
  label TEXT NOT NULL,
  hits INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (match_kind, match_value, direction)
);

-- Category-only rules from v2 become name rules.
INSERT INTO capture_rules (id, match_kind, match_value, direction, type, category_id, subcategory_id, label, hits, created_at, updated_at)
SELECT lower(hex(randomblob(16))), 'PARTY', r.merchant_key, CASE c.type WHEN 'INCOME' THEN 'IN' ELSE 'OUT' END, c.type,
       r.category_id, r.subcategory_id, r.merchant_key, r.hits, r.updated_at, r.updated_at
FROM merchant_rules r JOIN categories c ON c.id = r.category_id WHERE c.type IN ('INCOME', 'EXPENSE');
DROP TABLE merchant_rules;

INSERT OR IGNORE INTO categories (id, name, type, icon, color, is_system, created_at) VALUES
  ('00000000-0000-0000-0000-000000000030', 'Broker funds', 'TRANSFER', 'TrendingUp', '#0EA5E9', 1, '2026-11-23T00:00:00.000Z'),
  ('00000000-0000-0000-0000-000000000031', 'Own account transfer', 'TRANSFER', 'Repeat', '#0EA5E9', 1, '2026-11-23T00:00:00.000Z'),
  ('00000000-0000-0000-0000-000000000032', 'Credit card bill payment', 'TRANSFER', 'CreditCard', '#0EA5E9', 1, '2026-11-23T00:00:00.000Z'),
  ('00000000-0000-0000-0000-000000000033', 'Wallet top-up', 'TRANSFER', 'Wallet', '#0EA5E9', 1, '2026-11-23T00:00:00.000Z'),
  ('00000000-0000-0000-0000-000000000034', 'Cash withdrawal', 'TRANSFER', 'Banknote', '#0EA5E9', 1, '2026-11-23T00:00:00.000Z');
''';

/// v6: one net-worth reading per day (taken when the app is used), so the
/// app can show how wealth changed over time ("₹4.2L on 12 Oct → ₹4.6L").
const _v6 = '''
CREATE TABLE wealth_snapshots (
  date TEXT PRIMARY KEY,
  net_worth_minor INTEGER NOT NULL,
  assets_minor INTEGER NOT NULL,
  liabilities_minor INTEGER NOT NULL,
  invested_minor INTEGER NOT NULL,
  holdings_minor INTEGER NOT NULL
);
''';

/// Fills the v5 match columns for payments captured before v5.
void _backfillV5(Database db) {
  final rows = db.select("SELECT id, raw_text, merchant FROM transactions WHERE raw_text IS NOT NULL AND source IN ('SMS', 'UPI_NOTIFICATION', 'SHARE')");
  final update = db.prepare('UPDATE transactions SET vpa = ?, template_key = ? WHERE id = ?');
  for (final r in rows) {
    final keys = RuleKeys.of(text: r['raw_text'] as String, merchant: r['merchant'] as String?);
    update.execute([keys.vpa, keys.template, r['id']]);
  }
  update.close();
}

/// Default categories, identical to the backend seed (same ids), so data
/// moved between the web app and the phone keeps its categories.
const systemCategories = [
  ('00000000-0000-0000-0000-000000000001', 'Salary', 'INCOME', 'Briefcase', '#10B981'),
  ('00000000-0000-0000-0000-000000000002', 'Investments & Returns', 'INCOME', 'TrendingUp', '#059669'),
  ('00000000-0000-0000-0000-000000000003', 'Freelance / Business', 'INCOME', 'Laptop', '#34D399'),
  ('00000000-0000-0000-0000-000000000004', 'Rental Income', 'INCOME', 'Home', '#6EE7B7'),
  ('00000000-0000-0000-0000-000000000005', 'Other Income', 'INCOME', 'PlusCircle', '#A7F3D0'),
  ('00000000-0000-0000-0000-000000000010', 'Housing & Rent', 'EXPENSE', 'Home', '#EF4444'),
  ('00000000-0000-0000-0000-000000000011', 'Food & Groceries', 'EXPENSE', 'Utensils', '#F59E0B'),
  ('00000000-0000-0000-0000-000000000012', 'Utilities & Bills', 'EXPENSE', 'Zap', '#6366F1'),
  ('00000000-0000-0000-0000-000000000013', 'Transportation & Fuel', 'EXPENSE', 'Car', '#EC4899'),
  ('00000000-0000-0000-0000-000000000014', 'Healthcare & Medical', 'EXPENSE', 'Activity', '#14B8A6'),
  ('00000000-0000-0000-0000-000000000015', 'Shopping & Lifestyle', 'EXPENSE', 'ShoppingBag', '#8B5CF6'),
  ('00000000-0000-0000-0000-000000000016', 'Entertainment & Leisure', 'EXPENSE', 'Film', '#F97316'),
  ('00000000-0000-0000-0000-000000000017', 'Insurance Premiums', 'EXPENSE', 'ShieldCheck', '#3B82F6'),
  ('00000000-0000-0000-0000-000000000018', 'Loan EMI & Debt Payoff', 'EXPENSE', 'CreditCard', '#DC2626'),
  ('00000000-0000-0000-0000-000000000019', 'Education & Courses', 'EXPENSE', 'BookOpen', '#0284C7'),
  ('00000000-0000-0000-0000-000000000020', 'Other Expenses', 'EXPENSE', 'MinusCircle', '#64748B'),
  ('00000000-0000-0000-0000-000000000021', 'Social & Travel', 'EXPENSE', 'Plane', '#D946EF'),
];

/// Default subcategories, as in the backend seed.
const systemSubcategories = [
  ('00000000-0000-0000-0000-000000000001', 'Monthly Salary'),
  ('00000000-0000-0000-0000-000000000001', 'Bonus & Incentive'),
  ('00000000-0000-0000-0000-000000000002', 'Dividends'),
  ('00000000-0000-0000-0000-000000000002', 'Stock Capital Gains'),
  ('00000000-0000-0000-0000-000000000002', 'Mutual Fund Gains'),
  ('00000000-0000-0000-0000-000000000002', 'Interest (FD/Savings)'),
  ('00000000-0000-0000-0000-000000000010', 'Apartment Rent'),
  ('00000000-0000-0000-0000-000000000010', 'Maintenance & Repairs'),
  ('00000000-0000-0000-0000-000000000010', 'Property Tax'),
  ('00000000-0000-0000-0000-000000000011', 'Daily Groceries'),
  ('00000000-0000-0000-0000-000000000011', 'Dining Out'),
  ('00000000-0000-0000-0000-000000000011', 'Coffee & Snacks'),
  ('00000000-0000-0000-0000-000000000012', 'Electricity Bill'),
  ('00000000-0000-0000-0000-000000000012', 'Water & Gas'),
  ('00000000-0000-0000-0000-000000000012', 'Broadband & Mobile'),
  ('00000000-0000-0000-0000-000000000012', 'DTH & TV Bill'),
  ('00000000-0000-0000-0000-000000000013', 'Fuel & Petrol'),
  ('00000000-0000-0000-0000-000000000013', 'Cab / Taxi'),
  ('00000000-0000-0000-0000-000000000013', 'Auto / Rickshaw'),
  ('00000000-0000-0000-0000-000000000013', 'Bike / Scooter'),
  ('00000000-0000-0000-0000-000000000013', 'Vehicle Service'),
  ('00000000-0000-0000-0000-000000000014', 'Doctor Consultations'),
  ('00000000-0000-0000-0000-000000000014', 'Medicines & Pharmacy'),
  ('00000000-0000-0000-0000-000000000014', 'Lab Tests'),
  ('00000000-0000-0000-0000-000000000015', 'Clothing & Dresses'),
  ('00000000-0000-0000-0000-000000000015', 'Shoes & Slippers'),
  ('00000000-0000-0000-0000-000000000015', 'Eyewear & Glasses'),
  ('00000000-0000-0000-0000-000000000015', 'Accessories'),
  ('00000000-0000-0000-0000-000000000015', 'Personal Care'),
  ('00000000-0000-0000-0000-000000000017', 'Health Insurance Premium'),
  ('00000000-0000-0000-0000-000000000017', 'Term Life Insurance Premium'),
  ('00000000-0000-0000-0000-000000000017', 'Bike Insurance Premium'),
  ('00000000-0000-0000-0000-000000000017', 'Car Insurance Premium'),
  ('00000000-0000-0000-0000-000000000017', 'Travel Insurance Premium'),
  ('00000000-0000-0000-0000-000000000018', 'Home Loan EMI'),
  ('00000000-0000-0000-0000-000000000018', 'Car Loan EMI'),
  ('00000000-0000-0000-0000-000000000018', 'Personal Loan EMI'),
  ('00000000-0000-0000-0000-000000000016', 'Movies & Events'),
  ('00000000-0000-0000-0000-000000000016', 'Hobbies & Games'),
  ('00000000-0000-0000-0000-000000000019', 'Tuition & School Fees'),
  ('00000000-0000-0000-0000-000000000019', 'Books & Supplies'),
  ('00000000-0000-0000-0000-000000000019', 'Online Courses'),
  ('00000000-0000-0000-0000-000000000021', 'Friends Outing'),
  ('00000000-0000-0000-0000-000000000021', 'Trips & Vacations'),
  ('00000000-0000-0000-0000-000000000021', 'Events & Celebrations'),
];

void _seedCategories(Database db) {
  const seededAt = '2026-01-01T00:00:00.000Z';
  final insertCategory = db.prepare(
    'INSERT INTO categories (id, name, type, icon, color, is_system, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
  );
  for (final (id, name, type, icon, color) in systemCategories) {
    insertCategory.execute([id, name, type, icon, color, seededAt]);
  }
  insertCategory.close();

  // Fixed ids so every phone has the same default subcategories.
  final insertSub = db.prepare('INSERT INTO subcategories (id, category_id, name, created_at) VALUES (?, ?, ?, ?)');
  for (var i = 0; i < systemSubcategories.length; i++) {
    final (categoryId, name) = systemSubcategories[i];
    insertSub.execute(['00000000-0000-0000-0001-${(i + 1).toString().padLeft(12, '0')}', categoryId, name, seededAt]);
  }
  insertSub.close();
}
