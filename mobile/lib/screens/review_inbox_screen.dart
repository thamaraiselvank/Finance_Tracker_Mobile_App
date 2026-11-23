import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../capture/sms_sync.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';

/// Payments captured from bank SMS, waiting for a quick yes / no.
///
/// Swipe right = confirm (counts in Money from then on), swipe left = ignore,
/// tap = edit. Category and account chips can be changed before confirming;
/// the app remembers the choice for the next payment to the same merchant.
class ReviewInboxScreen extends StatefulWidget {
  const ReviewInboxScreen({super.key});

  @override
  State<ReviewInboxScreen> createState() => _ReviewInboxScreenState();
}

class _ReviewInboxScreenState extends State<ReviewInboxScreen> {
  List<Json>? _items;
  List<Json> _accounts = [];
  List<Json> _categories = [];
  String? _error;
  bool _confirmingAll = false;
  SmsSync? _sync;

  CaptureService get _capture => context.services.capture!;

  @override
  void initState() {
    super.initState();
    _sync = context.read<SmsSync?>();
    _sync?.addListener(_onSyncChanged);
    _load();
  }

  @override
  void dispose() {
    _sync?.removeListener(_onSyncChanged);
    super.dispose();
  }

  int _lastSeenCount = -1;
  void _onSyncChanged() {
    // A scan finished with new items: refresh the list.
    final count = _sync!.pendingCount;
    if (!_sync!.scanning && count != _lastSeenCount) {
      _lastSeenCount = count;
      _load();
    }
  }

  Future<void> _load() async {
    final s = context.services;
    try {
      final r = await Future.wait([_capture.pending(), s.accounts.list(), s.categories.list()]);
      if (!mounted) return;
      setState(() {
        _items = r[0];
        _accounts = r[1].where((a) => a['is_active'] != false).toList();
        _categories = r[2];
        _error = null;
      });
      _sync?.refreshCount();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done, String? undoId}) async {
    try {
      await action();
      await _load();
      if (!mounted || done == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(done),
          action: undoId == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: () => _run(() => _capture.reopen(undoId))),
        ));
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
      await _load();
    }
  }

  /// "Add" button: asks for the account first if the SMS didn't identify one.
  Future<void> _confirm(Json item) async {
    if (item['account_id'] == null && await _pickAccount(item) == null) return;
    await _run(() => _capture.confirm(item['id'] as String), done: 'Added to Money', undoId: item['id'] as String);
  }

  Future<void> _ignore(Json item) =>
      _run(() => _capture.ignore(item['id'] as String), done: 'Ignored', undoId: item['id'] as String);

  /// Swipe: only changes the database; the list reloads after the card has
  /// slid away (in onDismissed), so the animation is never interrupted.
  Future<bool> _swiped(Json item, DismissDirection direction) async {
    try {
      if (direction == DismissDirection.endToStart) {
        await _capture.ignore(item['id'] as String);
        return true;
      }
      if (item['account_id'] == null) {
        await _pickAccount(item); // card stays; swipe again or tap Add
        return false;
      }
      await _capture.confirm(item['id'] as String);
      return true;
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
      return false;
    }
  }

  void _afterSwipe(Json item, DismissDirection direction) {
    setState(() => _items?.removeWhere((i) => i['id'] == item['id']));
    _run(() async {}, done: direction == DismissDirection.startToEnd ? 'Added to Money' : 'Ignored', undoId: item['id'] as String);
  }

  Future<void> _confirmAllReady() async {
    final ready = (_items ?? []).where((i) => i['account_id'] != null).toList();
    if (ready.isEmpty) return;
    setState(() => _confirmingAll = true);
    var failed = 0;
    for (final item in ready) {
      try {
        await _capture.confirm(item['id'] as String);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _confirmingAll = false);
    await _load();
    if (mounted) context.showSnack(failed == 0 ? 'Added ${ready.length} to Money' : 'Added ${ready.length - failed}; $failed need attention');
  }

  /// Returns the chosen account id (also saved on the item), or null.
  Future<String?> _pickAccount(Json item) async {
    final last4 = item['account_last4'] as String?;
    final bank = item['bank'] as String?;
    const createKey = '__create__';
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              last4 == null ? 'Which account was this?' : 'Which account ends in $last4?',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          for (final a in _accounts)
            ListTile(
              leading: const Icon(Icons.account_balance_outlined),
              title: Text(a['name'].toString()),
              subtitle: a['last4'] != null ? Text('••${a['last4']}') : null,
              onTap: () => Navigator.pop(ctx, a['id'] as String),
            ),
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: Text('New account: ${[bank ?? 'Bank account', if (last4 != null) '••$last4'].join(' ')}'),
            subtitle: const Text('Starts at a zero balance. You can set the real balance in Money → Accounts.'),
            onTap: () => Navigator.pop(ctx, createKey),
          ),
        ]),
      ),
    );
    if (choice == null) return null;
    try {
      if (choice == createKey) {
        final id = await _capture.createAccountFor(item['id'] as String);
        await _load();
        return id;
      }
      await _capture.updatePending(item['id'] as String, {'account_id': choice});
      await _load();
      return choice;
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
      return null;
    }
  }

  Future<void> _pickCategory(Json item) async {
    final type = item['type'];
    final options = _categories.where((c) => c['type'] == type).toList();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => ListView(controller: controller, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              item['merchant'] != null ? 'Category for ${item['merchant']}' : 'Category',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          if (item['merchant'] != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Finverse will remember this for ${item['merchant']}.', style: Theme.of(ctx).textTheme.bodySmall),
            ),
          for (final c in options)
            ListTile(
              title: Text(c['name'].toString()),
              trailing: c['id'] == item['category_id'] ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, c['id'] as String),
            ),
        ]),
      ),
    );
    if (choice == null) return;
    await _run(() => _capture.updatePending(item['id'] as String, {'category_id': choice}));
  }

  Future<void> _edit(Json item) async {
    final changed = await showFormSheet<bool>(context, title: 'Edit payment', child: _PendingEditForm(item: item));
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SmsSync?>();
    final items = _items;
    final readyCount = (items ?? []).where((i) => i['account_id'] != null).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review inbox'),
        actions: [
          if (readyCount > 1)
            IconButton(
              tooltip: 'Add all with an account',
              onPressed: _confirmingAll ? null : _confirmAllReady,
              icon: _confirmingAll
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.done_all),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await sync?.scan(force: true);
          await _load();
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (sync != null) SmsStatusCard(sync: sync),
          if (_error != null)
            ErrorView(message: _error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'All caught up',
              message: 'New bank and UPI payments appear here automatically. Swipe right to add one to Money, left to ignore it.',
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                '${items.length} to review · swipe right to add, left to ignore',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            for (final item in items)
              Dismissible(
                key: ValueKey(item['id']),
                background: _swipeBackground(context, Icons.check, 'Add', AppColors.income, Alignment.centerLeft),
                secondaryBackground: _swipeBackground(context, Icons.close, 'Ignore', Theme.of(context).colorScheme.outline, Alignment.centerRight),
                confirmDismiss: (direction) => _swiped(item, direction),
                onDismissed: (direction) => _afterSwipe(item, direction),
                child: _PendingCard(
                  item: item,
                  categoryName: _categoryName(item),
                  accountName: _accountName(item),
                  onTap: () => _edit(item),
                  onCategory: () => _pickCategory(item),
                  onAccount: () => _pickAccount(item),
                  onConfirm: () => _confirm(item),
                  onIgnore: () => _ignore(item),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  String? _categoryName(Json item) {
    final name = item['category_name'] as String?;
    final sub = item['subcategory_name'] as String?;
    if (name == null) return null;
    return sub == null ? name : '$name · $sub';
  }

  String? _accountName(Json item) => item['account_name'] as String?;

  Widget _swipeBackground(BuildContext context, IconData icon, String label, Color color, Alignment alignment) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        alignment: alignment,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.item,
    required this.categoryName,
    required this.accountName,
    required this.onTap,
    required this.onCategory,
    required this.onAccount,
    required this.onConfirm,
    required this.onIgnore,
  });

  final Json item;
  final String? categoryName;
  final String? accountName;
  final VoidCallback onTap, onCategory, onAccount, onConfirm, onIgnore;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final income = item['type'] == 'INCOME';
    final at = DateTime.tryParse(item['occurred_at']?.toString() ?? '')?.toLocal();
    final where = [
      if (item['bank'] != null) item['bank'],
      if (item['account_last4'] != null) '••${item['account_last4']}',
      if (at != null) DateFormat('d MMM, h:mm a').format(at),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: (income ? AppColors.income : AppColors.expense).withValues(alpha: 0.12),
                child: Icon(income ? Icons.south_west : Icons.north_east, size: 18, color: income ? AppColors.income : AppColors.expense),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item['description'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (where.isNotEmpty)
                    Text(where, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                ]),
              ),
              Text(
                '${income ? '+' : '−'}${state.money.format(item['amount'], hidden: state.hideAmounts)}',
                style: TextStyle(fontWeight: FontWeight.w800, color: income ? AppColors.income : null),
              ),
              const SizedBox(width: 8),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ActionChip(
                avatar: Icon(categoryName == null ? Icons.label_outline : Icons.label, size: 16),
                label: Text(categoryName ?? 'Add category'),
                onPressed: onCategory,
              ),
              ActionChip(
                avatar: Icon(Icons.account_balance_outlined, size: 16, color: accountName == null ? AppColors.warning : null),
                label: Text(accountName ?? 'Choose account'),
                onPressed: onAccount,
              ),
            ]),
            Row(children: [
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Original message'),
                    content: SelectableText(item['raw_text']?.toString() ?? ''),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                  ),
                ),
                child: const Text('View SMS'),
              ),
              const Spacer(),
              TextButton(onPressed: onIgnore, child: const Text('Ignore')),
              FilledButton.tonal(onPressed: onConfirm, child: const Text('Add')),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Edit a captured payment before adding it (amount, type, description, date).
class _PendingEditForm extends StatefulWidget {
  const _PendingEditForm({required this.item});
  final Json item;

  @override
  State<_PendingEditForm> createState() => _PendingEditFormState();
}

class _PendingEditFormState extends State<_PendingEditForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _description, _amount;
  late String _type;
  late DateTime _date;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.item['description']?.toString() ?? '');
    _amount = TextEditingController(text: toDouble(widget.item['amount']).toStringAsFixed(2));
    _type = widget.item['type']?.toString() ?? 'EXPENSE';
    _date = toDate(widget.item['date']) ?? DateTime.now();
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() => runSave(
        context,
        formKey: _formKey,
        setBusy: (b) => setState(() => _busy = b),
        successMessage: 'Saved',
        action: () => context.services.capture!.updatePending(widget.item['id'] as String, {
          'type': _type,
          'amount': parseAmount(_amount),
          'description': _description.text.trim(),
          'date': apiDate(_date),
        }),
      );

  @override
  Widget build(BuildContext context) {
    final money = context.read<AppState>().money;
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'EXPENSE', label: Text('Money out')),
              ButtonSegment(value: 'INCOME', label: Text('Money in')),
            ],
            selected: {_type == 'TRANSFER' ? 'EXPENSE' : _type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
        ),
        AmountField(controller: _amount, label: 'Amount', prefix: money.symbol),
        TextInput(controller: _description, label: 'Description', required: true),
        DateInput(label: 'Date', value: _date, lastDate: DateTime.now(), onChanged: (d) => setState(() => _date = d ?? _date)),
        SaveButton(busy: _busy, onPressed: _save, label: 'Save'),
      ]),
    );
  }
}

/// SMS reading status: turn on, last read time, read now.
class SmsStatusCard extends StatelessWidget {
  const SmsStatusCard({super.key, required this.sync});
  final SmsSync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!sync.supported) return const SizedBox.shrink();
    if (!sync.granted) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.sms_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text('Record payments from bank SMS', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            const Text(
              'Finverse reads SMS from banks and payment apps (never personal messages) on this phone, '
              'and lists each payment here for you to confirm. Nothing is uploaded.',
            ),
            const SizedBox(height: 12),
            if (sync.permanentlyDenied)
              OutlinedButton.icon(onPressed: sync.openSettings, icon: const Icon(Icons.settings), label: const Text('Allow SMS in Settings'))
            else
              FilledButton.icon(onPressed: sync.enable, icon: const Icon(Icons.check), label: const Text('Allow SMS access')),
          ]),
        ),
      );
    }
    final last = sync.lastScan;
    final result = sync.lastResult;
    return Card(
      child: ListTile(
        leading: sync.scanning
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.sms_outlined, color: theme.colorScheme.primary),
        title: Text(sync.scanning ? 'Reading bank SMS…' : 'Bank SMS: on'),
        subtitle: Text(sync.error ??
            [
              if (last != null) 'Last read ${DateFormat('d MMM, h:mm a').format(last)}',
              if (result != null && (result['added'] as int) > 0) '${result['added']} new',
            ].join(' · ')),
        trailing: IconButton(
          tooltip: 'Read now',
          onPressed: sync.scanning ? null : () => sync.scan(force: true),
          icon: const Icon(Icons.refresh),
        ),
      ),
    );
  }
}
