import 'package:flutter/services.dart' show HapticFeedback;
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../capture/app_capture.dart';
import '../capture/sms_sync.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../core/pro.dart';
import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';
import 'capture_rules_screen.dart';

/// Payments captured from bank SMS, payment-app notifications and shared
/// screenshots, waiting for a quick yes / no.
///
/// Swipe right = add to Money, swipe left = ignore, tap = edit. Tapping the
/// category opens "What is this payment?", which can also teach Finverse to
/// treat every payment like it the same way. Long-press (or "Select") picks
/// several payments to add or ignore together; "Ignore all" clears the inbox.
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

  /// Choosing several payments at once (tick boxes on the cards).
  bool _selecting = false;
  final _selected = <String>{};

  /// Reviewed since the screen opened, for the progress bar.
  int _reviewed = 0;

  /// Cards dragged past the point where letting go adds / ignores them.
  final _armed = <String>{};

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
        _selected.retainAll(r[0].map((i) => i['id'] as String));
        _accounts = r[1].where((a) => a['is_active'] != false).toList();
        _categories = r[2];
        _error = null;
      });
      _sync?.refreshCount();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// A short message that goes away by itself after two seconds, even when
  /// it has an Undo button (Flutter keeps those on screen unless told not to).
  void _snack(String message, {String? undoId, List<String>? undoIds}) {
    if (!mounted) return;
    final ids = undoIds ?? [?undoId];
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        persist: false,
        action: ids.isEmpty ? null : SnackBarAction(label: 'Undo', onPressed: () => _undo(ids)),
      ));
  }

  Future<void> _undo(List<String> ids) async {
    for (final id in ids) {
      try {
        await _capture.reopen(id);
        if (_reviewed > 0) _reviewed--;
      } catch (e) {
        if (mounted) context.showSnack(e.toString(), error: true);
      }
    }
    await _load();
  }

  Future<void> _run(Future<void> Function() action, {String? done, String? undoId}) async {
    try {
      await action();
      await _load();
      if (done != null) _snack(done, undoId: undoId);
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
      await _load();
    }
  }

  /// Free version: [FreeLimits.capturedPerMonth] automatic payments a month.
  Future<bool> _mayAdd([int adding = 1]) async {
    if (context.isProNow) return true;
    final used = await _capture.addedThisMonth();
    if (!mounted) return false;
    return checkFreeLimit(context, current: used, adding: adding, limit: FreeLimits.capturedPerMonth, what: 'automatic payments this month');
  }

  /// "Add" button: asks for the account first if the message didn't identify one.
  Future<void> _confirm(Json item) async {
    if (!await _mayAdd()) return;
    if (item['account_id'] == null && await _pickAccount(item) == null) return;
    HapticFeedback.lightImpact();
    _reviewed++;
    await _run(() => _capture.confirm(item['id'] as String), done: 'Added to Money', undoId: item['id'] as String);
  }

  Future<void> _ignore(Json item) {
    _reviewed++;
    return _run(() => _capture.ignore(item['id'] as String), done: 'Ignored · not counted', undoId: item['id'] as String);
  }

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
      if (!await _mayAdd()) return false;
      await _capture.confirm(item['id'] as String);
      HapticFeedback.lightImpact();
      return true;
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
      return false;
    } finally {
      _armed.remove(item['id']);
    }
  }

  void _afterSwipe(Json item, DismissDirection direction) {
    setState(() {
      _items?.removeWhere((i) => i['id'] == item['id']);
      _reviewed++;
    });
    _snack(direction == DismissDirection.startToEnd ? 'Added to Money' : 'Ignored · not counted', undoId: item['id'] as String);
    _load();
  }

  void _onSwipeUpdate(Json item, DismissUpdateDetails d) {
    if (d.reached == d.previousReached) return;
    if (d.reached) HapticFeedback.selectionClick();
    setState(() => d.reached ? _armed.add(item['id'] as String) : _armed.remove(item['id']));
  }

  /// "Add all": every payment that already has an account.
  Future<void> _confirmAllReady() => _addMany(List<Json>.from(_items ?? const []));

  // ---- choosing several ---------------------------------------------------

  void _startSelecting([String? id]) {
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      _selected.clear();
      if (id != null) _selected.add(id);
    });
  }

  void _stopSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  void _toggleAll() {
    final all = (_items ?? []).map((i) => i['id'] as String).toSet();
    setState(() {
      if (_selected.length == all.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(all);
      }
    });
  }

  List<Json> get _chosen => (_items ?? []).where((i) => _selected.contains(i['id'])).toList();

  /// Ignores [items] together, with one Undo for all of them.
  Future<void> _ignoreMany(List<Json> items) async {
    if (items.isEmpty) return;
    setState(() => _confirmingAll = true);
    final done = <String>[];
    for (final item in items) {
      try {
        await _capture.ignore(item['id'] as String);
        done.add(item['id'] as String);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _confirmingAll = false;
      _reviewed += done.length;
      _selecting = false;
      _selected.clear();
    });
    await _load();
    _snack('Ignored ${done.length} · not counted', undoIds: done);
  }

  /// "Ignore all": asks first, since it clears the whole inbox.
  Future<void> _ignoreAll() async {
    final items = List<Json>.from(_items ?? const []);
    if (items.isEmpty) return;
    final ok = await confirmDialog(
      context,
      title: 'Ignore all ${items.length}?',
      message: 'They will not be counted in Money. You can tap Undo right after, '
          'and "Read older SMS" can bring them back later.',
      confirmLabel: 'Ignore all',
    );
    if (ok && mounted) await _ignoreMany(items);
  }

  /// Adds the chosen payments. Ones with no account stay, to choose one.
  Future<void> _addMany(List<Json> items) async {
    final ready = items.where((i) => i['account_id'] != null).toList();
    final waiting = items.length - ready.length;
    if (ready.isEmpty) {
      context.showSnack('Choose an account for ${waiting == 1 ? 'this payment' : 'these payments'} first (tap "Choose account").');
      return;
    }
    if (!await _mayAdd(ready.length) || !mounted) return;
    setState(() => _confirmingAll = true);
    final done = <String>[];
    for (final item in ready) {
      try {
        await _capture.confirm(item['id'] as String);
        done.add(item['id'] as String);
      } catch (_) {}
    }
    if (!mounted) return;
    HapticFeedback.lightImpact();
    setState(() {
      _confirmingAll = false;
      _reviewed += done.length;
      _selecting = false;
      _selected.clear();
    });
    await _load();
    final failed = ready.length - done.length;
    _snack(
      [
        'Added ${done.length} to Money',
        if (waiting > 0) '$waiting need an account',
        if (failed > 0) '$failed could not be added',
      ].join(' · '),
      undoIds: done,
    );
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

  /// "What is this payment?" (kind, category, and payments like it).
  Future<void> _teach(Json item) async {
    final result = await showTeachSheet(context, item: item, categories: _categories);
    if (result == null || !mounted) return;
    await _load();
    final stillPending = _items?.any((i) => i['id'] == item['id']) ?? false;
    final updated = (result['pending_updated'] as int) + (result['past_updated'] as int);
    if (!stillPending) {
      _reviewed++;
      _snack(updated > 0 ? 'Ignored, with $updated like it' : 'Ignored · not counted', undoId: item['id'] as String);
    } else {
      _snack(updated > 0 ? 'Saved · $updated more payment${updated == 1 ? '' : 's'} like it updated' : 'Saved');
    }
  }

  Future<void> _edit(Json item) async {
    final changed = await showFormSheet<bool>(context, title: 'Edit payment', child: _PendingEditForm(item: item));
    if (changed == true) await _load();
  }

  void _openRules() => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProGate(feature: ProFeature.rules, child: CaptureRulesScreen()))).then((_) => _load());

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SmsSync?>();
    final notifications = context.watch<NotificationSync?>();
    final items = _items;
    final readyCount = (items ?? []).where((i) => i['account_id'] != null).length;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(tooltip: 'Stop choosing', onPressed: _stopSelecting, icon: const Icon(Icons.close)),
              title: Text(_selected.isEmpty ? 'Choose payments' : '${_selected.length} chosen'),
              actions: [
                TextButton(
                  onPressed: (items ?? []).isEmpty ? null : _toggleAll,
                  child: Text(_selected.length == (items ?? []).length && _selected.isNotEmpty ? 'Clear' : 'All'),
                ),
              ],
            )
          : AppBar(
              title: const Text('Review inbox'),
              actions: [
                if (_confirmingAll)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                if ((items ?? []).length > 1)
                  IconButton(tooltip: 'Choose several', onPressed: _confirmingAll ? null : _startSelecting, icon: const Icon(Icons.checklist)),
                IconButton(tooltip: 'Auto-categorise rules', onPressed: _openRules, icon: const Icon(Icons.auto_awesome_outlined)),
                if ((items ?? []).isNotEmpty)
                  PopupMenuButton<String>(
                    enabled: !_confirmingAll,
                    onSelected: (v) => switch (v) {
                      'add' => _confirmAllReady(),
                      'ignore' => _ignoreAll(),
                      _ => _startSelecting(),
                    },
                    itemBuilder: (_) => [
                      if (readyCount > 0)
                        PopupMenuItem(
                          value: 'add',
                          child: ListTile(leading: const Icon(Icons.done_all), title: Text('Add all ($readyCount)'), contentPadding: EdgeInsets.zero),
                        ),
                      PopupMenuItem(
                        value: 'ignore',
                        child: ListTile(leading: const Icon(Icons.do_not_disturb_on_outlined), title: Text('Ignore all (${items!.length})'), contentPadding: EdgeInsets.zero),
                      ),
                      const PopupMenuItem(
                        value: 'select',
                        child: ListTile(leading: Icon(Icons.checklist), title: Text('Choose several…'), contentPadding: EdgeInsets.zero),
                      ),
                    ],
                  ),
              ],
            ),
      bottomNavigationBar: _selecting ? _SelectionBar(
        count: _selected.length,
        busy: _confirmingAll,
        onIgnore: () => _ignoreMany(_chosen),
        onAdd: () => _addMany(_chosen),
      ) : null,
      body: RefreshIndicator(
        onRefresh: () async {
          await sync?.scan(force: true);
          await notifications?.refresh();
          await _load();
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (sync != null) SmsStatusCard(sync: sync),
          if (notifications != null) NotificationStatusCard(sync: notifications),
          if (_error != null)
            ErrorView(message: _error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            _CaughtUp(celebrate: _reviewed > 0, reviewed: _reviewed)
          else ...[
            const SizedBox(height: 8),
            if (_reviewed > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: _reviewed / (_reviewed + items.length)),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOut,
                  builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6, color: AppColors.income),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(children: [
              Expanded(
                child: Text(
                  _reviewed > 0 ? '$_reviewed done · ${items.length} left' : '${items.length} to review',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (!_selecting) ...[
                const Icon(Icons.swipe_right_alt, size: 18, color: AppColors.income),
                Text(' add  ', style: theme.textTheme.bodySmall),
                Icon(Icons.swipe_left_alt, size: 18, color: theme.colorScheme.outline),
                Text(' ignore', style: theme.textTheme.bodySmall),
              ] else
                Text('Tap cards to choose', style: theme.textTheme.bodySmall),
            ]),
            if (!_selecting && items.length > 1) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _confirmingAll ? null : _ignoreAll,
                    icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
                    label: const Text('Ignore all'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _confirmingAll ? null : () => _startSelecting(),
                    icon: const Icon(Icons.checklist, size: 18),
                    label: const Text('Choose'),
                  ),
                ),
                if (readyCount > 0) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _confirmingAll ? null : _confirmAllReady,
                      icon: const Icon(Icons.done_all, size: 18),
                      label: Text('Add $readyCount'),
                    ),
                  ),
                ],
              ]),
            ],
            const SizedBox(height: 8),
            for (final item in items)
              Dismissible(
                key: ValueKey(item['id']),
                direction: _selecting ? DismissDirection.none : DismissDirection.horizontal,
                background: _SwipeBackground(
                  icon: Icons.check_circle,
                  label: item['account_id'] == null ? 'Choose account' : 'Add to Money',
                  color: AppColors.income,
                  alignment: Alignment.centerLeft,
                  armed: _armed.contains(item['id']),
                ),
                secondaryBackground: _SwipeBackground(
                  icon: Icons.do_not_disturb_on,
                  label: 'Ignore',
                  color: AppColors.expense,
                  alignment: Alignment.centerRight,
                  armed: _armed.contains(item['id']),
                ),
                dismissThresholds: const {DismissDirection.startToEnd: 0.35, DismissDirection.endToStart: 0.35},
                onUpdate: (d) => _onSwipeUpdate(item, d),
                confirmDismiss: (direction) => _swiped(item, direction),
                onDismissed: (direction) => _afterSwipe(item, direction),
                child: _PendingCard(
                  item: item,
                  selecting: _selecting,
                  selected: _selected.contains(item['id']),
                  onLongPress: () => _selecting ? _toggle(item['id'] as String) : _startSelecting(item['id'] as String),
                  onTap: () => _selecting ? _toggle(item['id'] as String) : _edit(item),
                  onCategory: () => _teach(item),
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
}

/// Bottom bar while choosing several payments.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.busy, required this.onIgnore, required this.onAdd});
  final int count;
  final bool busy;
  final VoidCallback onIgnore, onAdd;

  @override
  Widget build(BuildContext context) {
    final enabled = count > 0 && !busy;
    return SafeArea(
      child: Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled ? onIgnore : null,
                icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
                label: Text(count > 0 ? 'Ignore $count' : 'Ignore'),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.expense),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: enabled ? onAdd : null,
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check, size: 18),
                label: Text(count > 0 ? 'Add $count' : 'Add'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.icon, required this.label, required this.color, required this.alignment, required this.armed});
  final IconData icon;
  final String label;
  final Color color;
  final Alignment alignment;

  /// Past the threshold: letting go will act. Shown stronger.
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final fg = armed ? Colors.white : color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: alignment,
      decoration: BoxDecoration(color: armed ? color : color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(16)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedScale(scale: armed ? 1.25 : 1, duration: const Duration(milliseconds: 180), curve: Curves.easeOutBack, child: Icon(icon, color: fg)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// "All caught up", with a small celebration after reviewing.
class _CaughtUp extends StatelessWidget {
  const _CaughtUp({required this.celebrate, required this.reviewed});
  final bool celebrate;
  final int reviewed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: Column(children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: celebrate ? 0 : 1, end: 1),
          duration: const Duration(milliseconds: 700),
          curve: Curves.elasticOut,
          builder: (_, v, child) => Transform.scale(scale: v, child: child),
          child: CircleAvatar(
            radius: 36,
            backgroundColor: AppColors.income.withValues(alpha: 0.14),
            child: const Icon(Icons.done_all, size: 36, color: AppColors.income),
          ),
        ),
        const SizedBox(height: 16),
        Text('All caught up', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          celebrate
              ? 'You reviewed $reviewed payment${reviewed == 1 ? '' : 's'}. New bank and UPI payments will appear here.'
              : 'New bank and UPI payments appear here automatically. Swipe right to add one to Money, left to ignore it.\n\n'
                  'Missing one? Share the payment screenshot to Finverse from your gallery or payment app.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
        ),
      ]),
    );
  }
}

/// Where a payment was seen: "SMS · HDFC Bank", "Google Pay notification",
/// "Screenshot".
(IconData, String) _sourceBadge(Json seen) {
  final label = seen['label'] as String?;
  return switch (seen['source']) {
    'SMS' => (Icons.sms_outlined, label == null ? 'SMS' : 'SMS · $label'),
    'UPI_NOTIFICATION' => (Icons.notifications_outlined, label == null ? 'App notification' : '$label notification'),
    'SHARE' => (Icons.image_outlined, 'Screenshot'),
    _ => (Icons.edit_note, 'Added by hand'),
  };
}

/// Why the category was chosen.
(IconData, String, Color?)? _reason(Json item, ThemeData theme) => switch (item['suggest_source']) {
      'RULE' => (Icons.auto_awesome, 'Learned from your choice', AppColors.income),
      'BUILTIN' => (Icons.rule, item['suggest_label'] as String? ?? 'Built-in rule', AppColors.info),
      'GUESS' => (Icons.help_outline, 'Guess · please check', AppColors.warning),
      'USER' => (Icons.check, 'Your choice', theme.colorScheme.outline),
      _ => null,
    };

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.item,
    required this.selecting,
    required this.selected,
    required this.onLongPress,
    required this.onTap,
    required this.onCategory,
    required this.onAccount,
    required this.onConfirm,
    required this.onIgnore,
  });

  final Json item;
  final bool selecting, selected;
  final VoidCallback onLongPress, onTap, onCategory, onAccount, onConfirm, onIgnore;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final into = (item['direction'] ?? (item['type'] == 'INCOME' ? 'IN' : 'OUT')) == 'IN';
    final transfer = item['type'] == 'TRANSFER';
    final color = transfer ? AppColors.info : (into ? AppColors.income : AppColors.expense);
    final at = DateTime.tryParse(item['occurred_at']?.toString() ?? '')?.toLocal();
    final where = [
      if (item['account_last4'] != null) '••${item['account_last4']}',
      if (at != null) DateFormat('d MMM, h:mm a').format(at),
    ].join(' · ');
    final category = item['category_name'] as String?;
    final sub = item['subcategory_name'] as String?;
    final categoryText = category == null ? null : (sub == null ? category : '$category · $sub');
    final seen = ((item['seen_via'] as List?) ?? const []).cast<Json>();
    final reason = categoryText == null && item['suggest_source'] != 'USER' ? null : _reason(item, theme);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: selected
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: theme.colorScheme.primary, width: 2))
          : null,
      color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35) : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 5, color: color),
            if (selecting)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Checkbox(value: selected, onChanged: (_) => onTap()),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: color.withValues(alpha: 0.12),
                      child: Icon(transfer ? Icons.swap_horiz : (into ? Icons.south_west : Icons.north_east), size: 18, color: color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(item['description'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (where.isNotEmpty) Text(where, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                      ]),
                    ),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(
                        '${into ? '+' : '−'}${state.money.format(item['amount'], hidden: state.hideAmounts)}',
                        style: TextStyle(fontWeight: FontWeight.w800, color: into || transfer ? color : null),
                      ),
                      if (transfer) Text('own money', style: theme.textTheme.labelSmall?.copyWith(color: color)),
                    ]),
                    const SizedBox(width: 4),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final s in seen)
                      _Badge(icon: _sourceBadge(s).$1, label: _sourceBadge(s).$2, color: theme.colorScheme.onSurfaceVariant),
                    if (reason != null) _Badge(icon: reason.$1, label: reason.$2, color: reason.$3 ?? theme.colorScheme.outline),
                  ]),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    ActionChip(
                      avatar: Icon(categoryText == null ? Icons.label_outline : Icons.label, size: 16),
                      label: Text(categoryText ?? (transfer ? 'Own money' : 'Add category')),
                      onPressed: onCategory,
                    ),
                    ActionChip(
                      avatar: Icon(Icons.account_balance_outlined, size: 16, color: item['account_name'] == null ? AppColors.warning : null),
                      label: Text(item['account_name'] as String? ?? 'Choose account'),
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
                      child: const Text('Message'),
                    ),
                    const Spacer(),
                    if (!selecting) ...[
                      TextButton(onPressed: onIgnore, child: const Text('Ignore')),
                      FilledButton.tonal(onPressed: onConfirm, child: const Text('Add')),
                    ],
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Edit a captured payment before adding it (amount, direction, description, date).
class _PendingEditForm extends StatefulWidget {
  const _PendingEditForm({required this.item});
  final Json item;

  @override
  State<_PendingEditForm> createState() => _PendingEditFormState();
}

class _PendingEditFormState extends State<_PendingEditForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _description, _amount;
  late String _direction;
  late DateTime _date;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.item['description']?.toString() ?? '');
    _amount = TextEditingController(text: toDouble(widget.item['amount']).toStringAsFixed(2));
    _direction = widget.item['direction'] as String? ?? (widget.item['type'] == 'INCOME' ? 'IN' : 'OUT');
    _date = toDate(widget.item['date']) ?? DateTime.now();
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() {
    final type = widget.item['type'] == 'TRANSFER' ? 'TRANSFER' : (_direction == 'IN' ? 'INCOME' : 'EXPENSE');
    return runSave(
      context,
      formKey: _formKey,
      setBusy: (b) => setState(() => _busy = b),
      successMessage: 'Saved',
      action: () => context.services.capture!.updatePending(widget.item['id'] as String, {
        'direction': _direction,
        if (type != widget.item['type']) 'type': type,
        'amount': parseAmount(_amount),
        'description': _description.text.trim(),
        'date': apiDate(_date),
      }),
    );
  }

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
              ButtonSegment(value: 'OUT', label: Text('Money out')),
              ButtonSegment(value: 'IN', label: Text('Money in')),
            ],
            selected: {_direction},
            onSelectionChanged: (s) => setState(() => _direction = s.first),
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

/// UPI app notifications: invitation to turn on Notification access.
class NotificationStatusCard extends StatelessWidget {
  const NotificationStatusCard({super.key, required this.sync});
  final NotificationSync sync;

  @override
  Widget build(BuildContext context) {
    if (!sync.supported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    if (sync.granted) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.notifications_active_outlined, color: theme.colorScheme.primary),
          title: const Text('Payment app notifications: on'),
          subtitle: const Text('Google Pay, PhonePe, Paytm, BHIM, CRED, Amazon Pay'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.notifications_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text('Catch UPI app payments too', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Some payments never get a bank SMS. Allow Notification access and Finverse will note payments from '
            'Google Pay, PhonePe, Paytm and other UPI apps. Notifications from other apps are ignored and nothing is uploaded.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: sync.openSettings,
            icon: const Icon(Icons.settings),
            label: const Text('Open Notification access'),
          ),
          const SizedBox(height: 4),
          Text('In the list, switch on Finverse, then come back.', style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// SMS reading: turn on, choose how far back to read, last read time,
/// read now, read older messages.
class SmsStatusCard extends StatelessWidget {
  const SmsStatusCard({super.key, required this.sync});
  final SmsSync sync;

  Future<void> _readOlder(BuildContext context) async {
    final days = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Read older SMS', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final e in SmsSync.historyChoices.entries.where((e) => e.key > 0))
            ListTile(title: Text(e.value), onTap: () => Navigator.pop(ctx, e.key)),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('Payments already in Money or waiting here are not added again. '
                'Payments you deleted from Money or ignored come back here, '
                'except ones an "Ignore" rule hides.'),
          ),
        ]),
      ),
    );
    if (days != null) await sync.readHistory(days);
  }

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
    if (sync.needsHistoryChoice) return _HistoryChoiceCard(sync: sync);
    final last = sync.lastScan;
    final result = sync.lastResult;
    final restored = (result?['restored'] as int?) ?? 0;
    final added = ((result?['added'] as int?) ?? 0) - restored;
    final auto = (result?['auto_added'] as int?) ?? 0;
    final already = (result?['duplicates'] as int?) ?? 0;
    final nothingNew = result != null && added <= 0 && auto == 0 && restored == 0;
    return Card(
      child: ListTile(
        leading: sync.scanning
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.sms_outlined, color: theme.colorScheme.primary),
        title: Text(sync.scanning ? 'Reading bank SMS…' : 'Bank SMS: on'),
        subtitle: Text(sync.error ??
            [
              if (last != null) 'Last read ${DateFormat('d MMM, h:mm a').format(last)}',
              if (added > 0) '$added new',
              if (restored > 0) '$restored back from deleted / ignored',
              if (auto > 0) '$auto added automatically',
              if (nothingNew) already > 0 ? 'Nothing new ($already already in Money or here)' : 'Nothing new',
            ].join(' · ')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: 'Read now',
            onPressed: sync.scanning ? null : () => sync.scan(force: true),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            enabled: !sync.scanning,
            onSelected: (_) => _readOlder(context),
            itemBuilder: (_) => const [PopupMenuItem(value: 'older', child: Text('Read older SMS…'))],
          ),
        ]),
      ),
    );
  }
}

/// After SMS access is allowed: how far back should Finverse read?
class _HistoryChoiceCard extends StatefulWidget {
  const _HistoryChoiceCard({required this.sync});
  final SmsSync sync;

  @override
  State<_HistoryChoiceCard> createState() => _HistoryChoiceCardState();
}

class _HistoryChoiceCardState extends State<_HistoryChoiceCard> {
  int _days = SmsSync.defaultHistoryDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.history, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text('Read past payments too?', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 8),
          const Text('Choose how far back to read bank SMS. After this, only new messages are read. '
              'You can read older ones later from this card.'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final e in SmsSync.historyChoices.entries)
              ChoiceChip(label: Text(e.value), selected: _days == e.key, onSelected: (_) => setState(() => _days = e.key)),
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.sync.scanning ? null : () => widget.sync.startReading(_days),
            icon: const Icon(Icons.play_arrow),
            label: Text(_days == 0 ? 'Start with new messages' : 'Read and start'),
          ),
        ]),
      ),
    );
  }
}
