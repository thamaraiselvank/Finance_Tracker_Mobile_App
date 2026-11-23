import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

const scheduleFrequencies = {'WEEKLY': 'Weekly', 'MONTHLY': 'Monthly', 'QUARTERLY': 'Quarterly', 'YEARLY': 'Yearly'};
const _incomeSources = {'SALARY': 'Salary', 'RENTAL_INCOME': 'Rent received', 'DIVIDEND': 'Dividend', 'INTEREST': 'Interest', 'OTHER': 'Other'};
const _expenseSources = {'BILL': 'Bill', 'SUBSCRIPTION': 'Subscription', 'EMI': 'Loan EMI', 'INSURANCE_PREMIUM': 'Insurance premium', 'OTHER': 'Other'};

/// Loads occurrences from the start of this month up to 60 days ahead,
/// so overdue items from this month are also visible.
Future<List<Map<String, dynamic>>> loadUpcomingOccurrences(BuildContext context, {int daysAhead = 60}) {
  final now = DateTime.now();
  return context.services.schedules.occurrences(
    start: DateTime(now.year, now.month, 1),
    end: now.add(Duration(days: daysAhead)),
  );
}

class SchedulesScreen extends StatelessWidget {
  const SchedulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: _Bar(),
        body: TabBarView(children: [_UpcomingTab(), _AllSchedulesTab()]),
      ),
    );
  }
}

class _Bar extends StatelessWidget implements PreferredSizeWidget {
  const _Bar();
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 48);
  @override
  Widget build(BuildContext context) =>
      AppBar(title: const Text('Bills & recurring'), bottom: const TabBar(tabs: [Tab(text: 'Upcoming'), Tab(text: 'All schedules')]));
}

// ---------------------------------------------------------------------------

class _UpcomingTab extends StatefulWidget {
  const _UpcomingTab();

  @override
  State<_UpcomingTab> createState() => _UpcomingTabState();
}

class _UpcomingTabState extends State<_UpcomingTab> with AutomaticKeepAliveClientMixin {
  final _viewKey = GlobalKey<AsyncViewState<List<Map<String, dynamic>>>>();

  @override
  bool get wantKeepAlive => true;

  Future<void> _markDone(Map<String, dynamic> o) async {
    final money = context.read<AppState>().money;
    final amount = TextEditingController(text: toDouble(o['amount']).toStringAsFixed(0));
    final formKey = GlobalKey<FormState>();
    var date = DateTime.now();
    final isIncome = o['flow_type'] == 'INCOME';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(isIncome ? 'Mark as received' : 'Mark as paid'),
          content: SingleChildScrollView(child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${o['description']} – due ${displayDate(toDate(o['occurrence_date']))}'),
              const SizedBox(height: 14),
              AmountField(controller: amount, label: 'Actual amount', prefix: money.symbol),
              DateInput(label: 'Date', value: date, lastDate: DateTime.now(), onChanged: (d) => setLocal(() => date = d ?? date)),
              Text('A matching ${isIncome ? 'income' : 'expense'} transaction will be added to ${o['account_name'] ?? 'the account'}.', style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.services.schedules.completeOccurrence(
        o['schedule_id'].toString(),
        toDate(o['occurrence_date'])!,
        actualAmount: double.parse(amount.text),
        actualDate: date,
      );
      if (!mounted) return;
      context.showSnack(isIncome ? 'Marked as received' : 'Marked as paid');
      _viewKey.currentState?.reload();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return AsyncView<List<Map<String, dynamic>>>(
      key: _viewKey,
      load: () => loadUpcomingOccurrences(context),
      builder: (context, items, reload) {
        final overdue = items.where((o) => o['status'] == 'overdue').toList();
        final upcoming = items.where((o) => o['status'] == 'upcoming').toList();
        final done = items.where((o) => o['status'] == 'paid' || o['status'] == 'received').toList();
        final dueOut = upcoming.where((o) => o['flow_type'] == 'EXPENSE').fold<double>(0, (s, o) => s + toDouble(o['amount']));
        final dueIn = upcoming.where((o) => o['flow_type'] == 'INCOME').fold<double>(0, (s, o) => s + toDouble(o['amount']));

        Widget tile(Map<String, dynamic> o) {
          final isIncome = o['flow_type'] == 'INCOME';
          final status = o['status'];
          final date = toDate(o['occurrence_date']);
          final color = status == 'overdue' ? AppColors.expense : (isIncome ? AppColors.income : theme.colorScheme.onSurface);
          final isDone = status == 'paid' || status == 'received';
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: (isDone ? AppColors.income : color).withValues(alpha: 0.12),
              child: Icon(isDone ? Icons.check : (isIncome ? Icons.south_west : Icons.receipt_outlined), color: isDone ? AppColors.income : color, size: 20),
            ),
            title: Text(o['description'].toString()),
            subtitle: Text([
              isDone ? '${status == 'paid' ? 'Paid' : 'Received'} ${displayDate(toDate(o['actual_date']))}' : '${status == 'overdue' ? 'Was due' : 'Due'} ${DateFormat('EEE, d MMM').format(date!)}',
              _expenseSources[o['source_type']] ?? _incomeSources[o['source_type']] ?? '',
            ].where((s) => s.isNotEmpty).join(' • ')),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${o['amount_is_estimate'] == true ? '~' : ''}${state.money.format(isDone ? o['actual_amount'] : o['amount'], hidden: state.hideAmounts)}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: isIncome ? AppColors.income : null)),
              if (!isDone) Text('Tap to mark ${isIncome ? 'received' : 'paid'}', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
            ]),
            onTap: isDone ? null : () => _markDone(o),
          );
        }

        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          StatGrid(children: [
            StatTile(label: 'Due to pay (60 days)', value: state.money.compact(dueOut, hidden: state.hideAmounts), color: AppColors.expense),
            StatTile(label: 'Expected in (60 days)', value: state.money.compact(dueIn, hidden: state.hideAmounts), color: AppColors.income),
          ]),
          if (items.isEmpty)
            const EmptyState(
              icon: Icons.event_repeat,
              title: 'Nothing scheduled',
              message: 'Add your salary, rent, EMIs, subscriptions and premiums under "All schedules" to see what\'s due.',
            ),
          if (overdue.isNotEmpty) ...[
            const SectionHeader('Overdue'),
            Card(child: Column(children: overdue.map(tile).toList())),
          ],
          if (upcoming.isNotEmpty) ...[
            const SectionHeader('Coming up'),
            Card(child: Column(children: upcoming.map(tile).toList())),
          ],
          if (done.isNotEmpty) ...[
            const SectionHeader('Done this month'),
            Card(child: Column(children: done.map(tile).toList())),
          ],
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _AllSchedulesTab extends StatefulWidget {
  const _AllSchedulesTab();

  @override
  State<_AllSchedulesTab> createState() => _AllSchedulesTabState();
}

class _AllSchedulesTabState extends State<_AllSchedulesTab> with AutomaticKeepAliveClientMixin {
  final _viewKey = GlobalKey<AsyncViewState<List<Map<String, dynamic>>>>();

  @override
  bool get wantKeepAlive => true;

  Future<void> _openForm([Map<String, dynamic>? s]) async {
    final saved = await showFormSheet<bool>(context, title: s == null ? 'New recurring item' : 'Edit recurring item', child: ScheduleForm(existing: s));
    if (saved == true) _viewKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Recurring')),
      body: AsyncView<List<Map<String, dynamic>>>(
        key: _viewKey,
        load: () => context.services.schedules.list(),
        builder: (context, items, reload) {
          if (items.isEmpty) {
            return ListView(children: [
              EmptyState(
                icon: Icons.event_repeat,
                title: 'No recurring items',
                message: 'Track salary, rent, EMIs, SIPs, subscriptions and insurance premiums.',
                action: FilledButton.tonal(onPressed: () => _openForm(), child: const Text('Add recurring item')),
              ),
            ]);
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
            Card(
              child: Column(children: [
                for (final s in items)
                  ListTile(
                    onTap: () => _openForm(s),
                    leading: Icon(s['flow_type'] == 'INCOME' ? Icons.south_west : Icons.north_east, color: s['flow_type'] == 'INCOME' ? AppColors.income : AppColors.expense),
                    title: Text(s['description'].toString()),
                    subtitle: Text([
                      _every(s),
                      if (s['account_name'] != null) s['account_name'],
                      if (s['is_active'] == false) 'Paused',
                    ].join(' • ')),
                    trailing: Text(state.money.format(s['amount'], hidden: state.hideAmounts), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ]),
            ),
            DeleteAllButton(
              label: 'Delete all recurring items (${items.length})',
              onPressed: () => deleteAllFlow<Map<String, dynamic>>(
                context,
                items: items,
                what: 'recurring items',
                deleteItem: (s) => context.services.schedules.delete(s['id'].toString()),
                extraWarning: 'Transactions already recorded from them are kept.',
                onDone: () => _viewKey.currentState?.reload(),
              ),
            ),
          ]);
        },
      ),
    );
  }

  String _every(Map<String, dynamic> s) {
    final n = toInt(s['interval_count'], 1);
    final f = s['frequency']?.toString() ?? 'MONTHLY';
    if (n == 1) return scheduleFrequencies[f] ?? humanize(f);
    final unit = {'WEEKLY': 'weeks', 'MONTHLY': 'months', 'QUARTERLY': 'quarters', 'YEARLY': 'years'}[f] ?? '';
    return 'Every $n $unit';
  }
}

class ScheduleForm extends StatefulWidget {
  const ScheduleForm({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<ScheduleForm> createState() => _ScheduleFormState();
}

class _ScheduleFormState extends State<ScheduleForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _description, _amount, _interval;
  late String _flow, _source, _frequency;
  String? _accountId, _categoryId;
  late DateTime _start;
  DateTime? _end;
  bool _estimate = false;
  bool _active = true;
  bool _busy = false;
  bool _loadingOptions = true;
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _categories = [];

  bool get _isEdit => widget.existing != null;
  bool get _linked => widget.existing != null && (widget.existing!['debt_id'] != null || widget.existing!['liability_id'] != null || widget.existing!['insurance_policy_id'] != null);

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _description = TextEditingController(text: e['description']?.toString() ?? '');
    _amount = TextEditingController(text: e['amount'] == null ? '' : toDouble(e['amount']).toStringAsFixed(0));
    _interval = TextEditingController(text: '${toInt(e['interval_count'], 1)}');
    _flow = e['flow_type']?.toString() ?? 'EXPENSE';
    _source = e['source_type']?.toString() ?? (_flow == 'INCOME' ? 'SALARY' : 'BILL');
    _frequency = e['frequency']?.toString() ?? 'MONTHLY';
    _accountId = e['account_id']?.toString();
    _categoryId = e['category_id']?.toString();
    _start = toDate(e['start_date']) ?? DateTime.now();
    _end = toDate(e['end_date']);
    _estimate = e['amount_is_estimate'] == true;
    _active = e['is_active'] != false;
    _loadOptions();
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final s = context.services;
      final r = await Future.wait([s.accounts.list(), s.categories.list()]);
      _accounts = r[0];
      _categories = r[1];
      if (_accountId == null && _accounts.length == 1) _accountId = _accounts.first['id'].toString();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
    if (mounted) setState(() => _loadingOptions = false);
  }

  Map<String, String> get _sources => _flow == 'INCOME' ? _incomeSources : _expenseSources;

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: _isEdit ? 'Saved' : 'Recurring item added',
        action: () async {
          final payload = <String, dynamic>{
            'description': _description.text.trim(),
            'account_id': _accountId,
            'category_id': _categoryId,
            'amount': parseAmount(_amount),
            'amount_is_estimate': _estimate,
            'frequency': _frequency,
            'interval_count': int.parse(_interval.text.trim()),
            'start_date': apiDate(_start),
            'end_date': _end == null ? null : apiDate(_end!),
          };
          if (!_linked) {
            payload['flow_type'] = _flow;
            payload['source_type'] = _source;
          }
          if (_isEdit) {
            payload['is_active'] = _active;
            await context.services.schedules.update(widget.existing!['id'].toString(), payload);
          } else {
            await context.services.schedules.create(payload);
          }
        },
      );

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete recurring item?', message: 'Past transactions stay; future reminders for "${widget.existing!['description']}" stop.');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.services.schedules.delete(widget.existing!['id'].toString());
      if (!mounted) return;
      Navigator.pop(context, true);
      context.showSnack('Deleted');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        context.showSnack(e.toString(), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingOptions) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
    if (_accounts.isEmpty) {
      return const EmptyState(icon: Icons.account_balance_outlined, title: 'Add an account first', message: 'Recurring items are paid from, or received into, an account.');
    }
    final money = context.read<AppState>().money;
    final cats = _categories.where((c) => c['type'] == _flow).toList();
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!_linked)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'EXPENSE', label: Text('Money out')), ButtonSegment(value: 'INCOME', label: Text('Money in'))],
              selected: {_flow},
              onSelectionChanged: (s) => setState(() {
                _flow = s.first;
                _source = _flow == 'INCOME' ? 'SALARY' : 'BILL';
                _categoryId = null;
              }),
            ),
          )
        else
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('Linked to ${widget.existing!['linked_record_name'] ?? 'a debt or policy'}.')),
        TextInput(controller: _description, label: 'Description (e.g. Rent, Netflix, Salary)', required: true),
        if (!_linked) DropdownInput<String>(key: ValueKey('src-$_flow'), label: 'Type', value: _source, items: _sources, onChanged: (v) => setState(() => _source = v ?? 'OTHER')),
        AmountField(controller: _amount, label: 'Amount', prefix: money.symbol),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Amount varies (estimate)'), value: _estimate, onChanged: (v) => setState(() => _estimate = v)),
        Row(children: [
          SizedBox(
            width: 90,
            child: TextInput(controller: _interval, label: 'Every', keyboardType: TextInputType.number, validator: (v) {
              final n = int.tryParse(v?.trim() ?? '');
              return n == null || n < 1 || n > 12 ? '1–12' : null;
            }),
          ),
          const SizedBox(width: 12),
          Expanded(child: DropdownInput<String>(label: 'Frequency', value: _frequency, items: scheduleFrequencies, onChanged: (v) => setState(() => _frequency = v ?? 'MONTHLY'))),
        ]),
        DropdownInput<String>(label: 'Account', value: _accountId, items: {for (final a in _accounts) a['id'].toString(): a['name'].toString()}, onChanged: (v) => setState(() => _accountId = v)),
        DropdownInput<String>(key: ValueKey('cat-$_flow'), label: 'Category (optional)', value: _categoryId, required: false, items: {for (final c in cats) c['id'].toString(): c['name'].toString()}, onChanged: (v) => setState(() => _categoryId = v)),
        DateInput(label: 'First date', value: _start, onChanged: (d) => setState(() => _start = d ?? _start)),
        DateInput(label: 'End date (optional)', value: _end, required: false, onChanged: (d) => setState(() => _end = d)),
        if (_isEdit) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: _active, onChanged: (v) => setState(() => _active = v)),
        SaveButton(busy: _busy, onPressed: _save, label: _isEdit ? 'Save changes' : 'Add'),
        if (_isEdit) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          ),
        ],
      ]),
    );
  }
}
