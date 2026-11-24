/// What can be exported, as plain tables built from the [Services] (so the
/// numbers are the same ones the screens show, in either app version).
library;

import '../core/format.dart';
import '../services/services.dart';

/// How a column's values are shown (and typed in Excel).
enum CellKind { text, money, number, percent, date }

class ExportColumn {
  const ExportColumn(this.title, this.kind, {this.width = 14, this.inPdf = true});
  final String title;
  final CellKind kind;

  /// Excel column width in characters.
  final double width;

  /// Shown in the PDF report (which has less room than a spreadsheet).
  final bool inPdf;
}

/// One section of an export: a sheet in Excel, a file in CSV, a table in PDF.
class ExportTable {
  const ExportTable({required this.section, required this.columns, required this.rows, this.subtitle, this.totals = const []});
  final ExportSection section;
  final List<ExportColumn> columns;

  /// Cells: String, num (money / number / percent) or a 'YYYY-MM-DD' date string.
  final List<List<Object?>> rows;

  /// E.g. the period, "1 Apr 2026 – 31 Mar 2027".
  final String? subtitle;

  /// Summary lines under the table: label, value and how to show the value.
  final List<(String, Object?, CellKind)> totals;

  String get title => section.label;
}

enum ExportSection {
  transactions('Transactions'),
  accounts('Accounts'),
  budgets('Budgets'),
  holdings('Wealth holdings'),
  goals('Goals'),
  debts('Debts & loans'),
  insurance('Insurance'),
  recurring('Bills & recurring');

  const ExportSection(this.label);
  final String label;
}

/// Choices for an export.
class ExportOptions {
  ExportOptions({
    required this.sections,
    this.start,
    this.end,
    this.type = 'ALL',
    this.accountId,
    this.categoryId,
    int? budgetMonth,
    int? budgetYear,
    this.assetClass,
  }) : budgetMonth = budgetMonth ?? DateTime.now().month,
       budgetYear = budgetYear ?? DateTime.now().year;

  final Set<ExportSection> sections;

  /// Transactions: date range (inclusive; null = no limit), type
  /// (ALL / INCOME / EXPENSE / TRANSFER), account and category.
  final DateTime? start;
  final DateTime? end;
  final String type;
  final String? accountId;
  final String? categoryId;

  /// Budgets: which month.
  final int budgetMonth;
  final int budgetYear;

  /// Holdings: one asset class (e.g. MUTUAL_FUND), or null for all.
  final String? assetClass;
}

const _sourceLabels = {
  'MANUAL': 'Added by hand',
  'SMS': 'Bank SMS',
  'UPI_NOTIFICATION': 'UPI app',
  'SHARE': 'Screenshot',
  'IMPORT': 'Statement import',
  'SCHEDULE': 'Recurring',
};

const _typeLabels = {'INCOME': 'Income', 'EXPENSE': 'Expense', 'TRANSFER': 'Transfer'};

String _type(Object? t) => _typeLabels['$t'.toUpperCase()] ?? humanize('$t');

/// "1 Apr 2026 – 31 Mar 2027", "Since 1 Apr 2026", "All dates".
String periodLabel(DateTime? start, DateTime? end) {
  if (start == null && end == null) return 'All dates';
  if (start == null) return 'Up to ${displayDate(end)}';
  if (end == null) return 'Since ${displayDate(start)}';
  return '${displayDate(start)} – ${displayDate(end)}';
}

/// Builds the chosen tables, in [ExportSection] order.
Future<List<ExportTable>> buildExportTables(Services s, ExportOptions o, {DateTime? today}) async {
  final now = today ?? DateTime.now();
  final tables = <ExportTable>[];
  for (final section in ExportSection.values.where(o.sections.contains)) {
    tables.add(switch (section) {
      ExportSection.transactions => await _transactions(s, o),
      ExportSection.accounts => await _accounts(s),
      ExportSection.budgets => await _budgets(s, o),
      ExportSection.holdings => await _holdings(s, o),
      ExportSection.goals => await _goals(s),
      ExportSection.debts => await _debts(s),
      ExportSection.insurance => await _insurance(s),
      ExportSection.recurring => await _recurring(s, now),
    });
  }
  return tables;
}

Future<ExportTable> _transactions(Services s, ExportOptions o) async {
  var list = await s.transactions.list(start: o.start, end: o.end, type: o.type == 'ALL' ? null : o.type, limit: 1000000);
  if (o.accountId != null) list = list.where((t) => t['account_id'] == o.accountId).toList();
  if (o.categoryId != null) list = list.where((t) => t['category_id'] == o.categoryId).toList();
  // Oldest first, like a bank statement.
  list = list.reversed.toList();

  double sum(String type) => list.where((t) => '${t['type']}'.toUpperCase() == type).fold<double>(0.0, (a, t) => a + toDouble(t['amount']));
  final income = sum('INCOME');
  final expense = sum('EXPENSE');
  final transfers = list.where((t) => '${t['type']}'.toUpperCase() == 'TRANSFER').length;

  return ExportTable(
    section: ExportSection.transactions,
    subtitle: periodLabel(o.start, o.end),
    columns: const [
      ExportColumn('Date', CellKind.date, width: 12),
      ExportColumn('Description', CellKind.text, width: 36),
      ExportColumn('Type', CellKind.text, width: 10),
      ExportColumn('Category', CellKind.text, width: 20),
      ExportColumn('Subcategory', CellKind.text, width: 18, inPdf: false),
      ExportColumn('Account', CellKind.text, width: 20),
      ExportColumn('Amount', CellKind.money, width: 14),
      ExportColumn('Notes', CellKind.text, width: 24, inPdf: false),
      ExportColumn('Tags', CellKind.text, width: 14, inPdf: false),
      ExportColumn('Source', CellKind.text, width: 16, inPdf: false),
    ],
    rows: [
      for (final t in list)
        [
          t['date'],
          t['description'],
          _type(t['type']),
          t['category_name'] ?? 'Uncategorised',
          t['subcategory_name'],
          t['account_name'],
          toDouble(t['amount']),
          t['notes'],
          t['tags'],
          _sourceLabels['${t['source']}'] ?? t['source'],
        ],
    ],
    totals: [
      ('Transactions', list.length, CellKind.number),
      ('Total income', income, CellKind.money),
      ('Total expenses', expense, CellKind.money),
      ('Net (income − expenses)', income - expense, CellKind.money),
      if (transfers > 0) ('Transfers (not counted above)', transfers, CellKind.number),
    ],
  );
}

Future<ExportTable> _accounts(Services s) async {
  final list = await s.accounts.list();
  final total = list.where((a) => a['is_active'] != false).fold<double>(0.0, (sum, a) => sum + toDouble(a['balance']));
  return ExportTable(
    section: ExportSection.accounts,
    columns: const [
      ExportColumn('Account', CellKind.text, width: 28),
      ExportColumn('Type', CellKind.text, width: 16),
      ExportColumn('Bank / institution', CellKind.text, width: 22),
      ExportColumn('Balance', CellKind.money, width: 16),
      ExportColumn('Active', CellKind.text, width: 8),
    ],
    rows: [
      for (final a in list)
        [a['name'], humanize(a['account_type'] as String?), a['institution'], toDouble(a['balance']), a['is_active'] == false ? 'No' : 'Yes'],
    ],
    totals: [('Total balance (active accounts)', total, CellKind.money)],
  );
}

Future<ExportTable> _budgets(Services s, ExportOptions o) async {
  final list = (await s.budgets.forMonth(o.budgetMonth, o.budgetYear)).where((b) => b['monthly_limit'] != null || toDouble(b['spent']) > 0).toList();
  final limit = list.fold<double>(0.0, (sum, b) => sum + toDouble(b['monthly_limit']));
  final spent = list.fold<double>(0.0, (sum, b) => sum + toDouble(b['spent']));
  return ExportTable(
    section: ExportSection.budgets,
    subtitle: displayMonth(o.budgetMonth, o.budgetYear),
    columns: const [
      ExportColumn('Category', CellKind.text, width: 28),
      ExportColumn('Budget', CellKind.money, width: 14),
      ExportColumn('Spent', CellKind.money, width: 14),
      ExportColumn('Left', CellKind.money, width: 14),
      ExportColumn('Over budget', CellKind.text, width: 12),
    ],
    rows: [
      for (final b in list)
        [
          b['category_name'],
          b['monthly_limit'] == null ? null : toDouble(b['monthly_limit']),
          toDouble(b['spent']),
          b['remaining'] == null ? null : toDouble(b['remaining']),
          b['over_budget'] == true ? 'Yes' : '',
        ],
    ],
    totals: [('Total budget', limit, CellKind.money), ('Total spent', spent, CellKind.money)],
  );
}

String displayMonth(int month, int year) {
  const names = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return '${names[month - 1]} $year';
}

Future<ExportTable> _holdings(Services s, ExportOptions o) async {
  final summary = await s.assets.summary();
  final items = <Json>[
    for (final c in (summary['asset_classes'] as List? ?? const []))
      if (o.assetClass == null || (c as Map)['asset_class'] == o.assetClass)
        for (final i in ((c as Map)['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map),
  ];
  final invested = items.fold<double>(0.0, (sum, a) => sum + toDouble(a['invested_amount']));
  final current = items.fold<double>(0.0, (sum, a) => sum + toDouble(a['current_value']));
  return ExportTable(
    section: ExportSection.holdings,
    subtitle: o.assetClass == null ? null : humanize(o.assetClass),
    columns: const [
      ExportColumn('Name', CellKind.text, width: 32),
      ExportColumn('Type', CellKind.text, width: 16),
      ExportColumn('Sub-type', CellKind.text, width: 14, inPdf: false),
      ExportColumn('Quantity', CellKind.number, width: 10),
      ExportColumn('Buy price', CellKind.money, width: 12, inPdf: false),
      ExportColumn('Current price', CellKind.money, width: 13, inPdf: false),
      ExportColumn('Invested', CellKind.money, width: 14),
      ExportColumn('Current value', CellKind.money, width: 14),
      ExportColumn('Gain / loss', CellKind.money, width: 14),
      ExportColumn('Gain / loss %', CellKind.percent, width: 12),
      ExportColumn('Bought on', CellKind.date, width: 12, inPdf: false),
      ExportColumn('Notes', CellKind.text, width: 24, inPdf: false),
    ],
    rows: [
      for (final a in items)
        [
          a['name'],
          humanize(a['asset_class'] as String?),
          a['sub_type'],
          toDouble(a['quantity']),
          toDouble(a['buy_price']),
          toDouble(a['current_price']),
          toDouble(a['invested_amount']),
          toDouble(a['current_value']),
          toDouble(a['pnl']),
          toDouble(a['pnl_percentage']),
          a['purchase_date'],
          a['notes'],
        ],
    ],
    totals: [
      ('Total invested', invested, CellKind.money),
      ('Current value', current, CellKind.money),
      ('Gain / loss', current - invested, CellKind.money),
      if (o.assetClass == null) ...[
        ('Loans & debts outstanding', toDouble(summary['total_liabilities_outstanding']), CellKind.money),
        ('Net worth (holdings − debts)', toDouble(summary['net_worth']), CellKind.money),
      ],
    ],
  );
}

Future<ExportTable> _goals(Services s) async {
  final list = await s.goals.list();
  return ExportTable(
    section: ExportSection.goals,
    columns: const [
      ExportColumn('Goal', CellKind.text, width: 28),
      ExportColumn('Type', CellKind.text, width: 16),
      ExportColumn('Target', CellKind.money, width: 14),
      ExportColumn('Saved so far', CellKind.money, width: 14),
      ExportColumn('Progress', CellKind.percent, width: 10),
      ExportColumn('Target date', CellKind.date, width: 12),
      ExportColumn('Needed / month', CellKind.money, width: 14),
      ExportColumn('Status', CellKind.text, width: 10),
      ExportColumn('Priority', CellKind.number, width: 8, inPdf: false),
      ExportColumn('Notes', CellKind.text, width: 24, inPdf: false),
    ],
    rows: [
      for (final g in list)
        [
          g['goal_name'],
          humanize(g['goal_type'] as String?),
          toDouble(g['target_amount']),
          toDouble(g['current_amount']),
          toDouble(g['progress_percentage']),
          g['target_date'],
          toDouble(g['suggested_monthly_savings']),
          humanize(g['status'] as String?),
          g['priority'],
          g['description'],
        ],
    ],
    totals: [
      ('Total target', list.fold<double>(0.0, (sum, g) => sum + toDouble(g['target_amount'])), CellKind.money),
      ('Total saved', list.fold<double>(0.0, (sum, g) => sum + toDouble(g['current_amount'])), CellKind.money),
    ],
  );
}

Future<ExportTable> _debts(Services s) async {
  final list = await s.debts.list();
  return ExportTable(
    section: ExportSection.debts,
    columns: const [
      ExportColumn('Debt', CellKind.text, width: 26),
      ExportColumn('Type', CellKind.text, width: 16),
      ExportColumn('Lender', CellKind.text, width: 18),
      ExportColumn('Borrowed', CellKind.money, width: 14, inPdf: false),
      ExportColumn('Still owed', CellKind.money, width: 14),
      ExportColumn('Interest %', CellKind.percent, width: 10),
      ExportColumn('EMI', CellKind.money, width: 12),
      ExportColumn('Tenure (months)', CellKind.number, width: 10, inPdf: false),
      ExportColumn('Start date', CellKind.date, width: 12, inPdf: false),
      ExportColumn('End date', CellKind.date, width: 12),
    ],
    rows: [
      for (final d in list)
        [
          d['debt_name'],
          humanize(d['debt_type'] as String?),
          d['creditor_name'],
          toDouble(d['principal_amount']),
          toDouble(d['current_outstanding']),
          toDouble(d['interest_rate_pct']),
          d['monthly_emi'] == null ? null : toDouble(d['monthly_emi']),
          d['tenure_months'],
          d['start_date'],
          d['end_date'],
        ],
    ],
    totals: [
      ('Total still owed', list.fold<double>(0.0, (sum, d) => sum + toDouble(d['current_outstanding'])), CellKind.money),
      ('Total EMI per month', list.fold<double>(0.0, (sum, d) => sum + toDouble(d['monthly_emi'])), CellKind.money),
    ],
  );
}

Future<ExportTable> _insurance(Services s) async {
  final list = await s.insurance.list();
  return ExportTable(
    section: ExportSection.insurance,
    columns: const [
      ExportColumn('Policy', CellKind.text, width: 26),
      ExportColumn('Type', CellKind.text, width: 16),
      ExportColumn('Insurer', CellKind.text, width: 18),
      ExportColumn('Policy number', CellKind.text, width: 18, inPdf: false),
      ExportColumn('Cover', CellKind.money, width: 14),
      ExportColumn('Annual premium', CellKind.money, width: 14),
      ExportColumn('Paid', CellKind.text, width: 10, inPdf: false),
      ExportColumn('Renewal date', CellKind.date, width: 12),
      ExportColumn('Next payment', CellKind.date, width: 12, inPdf: false),
      ExportColumn('Status', CellKind.text, width: 10),
    ],
    rows: [
      for (final p in list)
        [
          p['policy_name'],
          humanize(p['policy_type'] as String?),
          p['insurer_name'],
          p['policy_number'],
          toDouble(p['sum_insured']),
          toDouble(p['annual_premium']),
          humanize(p['payment_frequency'] as String?),
          p['renewal_date'],
          p['next_payment_date'],
          humanize(p['status'] as String?),
        ],
    ],
    totals: [('Total annual premium', list.fold<double>(0.0, (sum, p) => sum + toDouble(p['annual_premium'])), CellKind.money)],
  );
}

Future<ExportTable> _recurring(Services s, DateTime today) async {
  final list = await s.schedules.list();
  // The next date each one is due (paid / received ones are skipped).
  final next = <String, String>{};
  try {
    final day = DateTime(today.year, today.month, today.day);
    final occurrences = await s.schedules.occurrences(start: day.subtract(const Duration(days: 31)), end: day.add(const Duration(days: 330)));
    for (final o in occurrences) {
      if (o['status'] == 'upcoming' || o['status'] == 'overdue') next.putIfAbsent('${o['schedule_id']}', () => '${o['occurrence_date']}');
    }
  } catch (_) {
    // The calendar is optional here.
  }
  String every(Json r) {
    final n = toInt(r['interval_count'], 1);
    final f = humanize(r['frequency'] as String?);
    return n <= 1 ? f : 'Every $n ${f.toLowerCase()}';
  }

  return ExportTable(
    section: ExportSection.recurring,
    columns: const [
      ExportColumn('Name', CellKind.text, width: 28),
      ExportColumn('Income / expense', CellKind.text, width: 12),
      ExportColumn('Kind', CellKind.text, width: 16, inPdf: false),
      ExportColumn('Amount', CellKind.money, width: 14),
      ExportColumn('How often', CellKind.text, width: 14),
      ExportColumn('Next date', CellKind.date, width: 12),
      ExportColumn('Account', CellKind.text, width: 18, inPdf: false),
      ExportColumn('Category', CellKind.text, width: 18, inPdf: false),
      ExportColumn('Active', CellKind.text, width: 8),
    ],
    rows: [
      for (final r in list)
        [
          r['description'],
          _type(r['flow_type']),
          humanize(r['source_type'] as String?),
          toDouble(r['amount']),
          every(r),
          r['is_active'] == false ? null : next['${r['id']}'],
          r['account_name'],
          r['category_name'],
          r['is_active'] == false ? 'No' : 'Yes',
        ],
    ],
  );
}
