import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../services/services.dart';
import '../widgets/common.dart';

/// Names for the kinds of captured payment, as the user sees them.
const paymentKindLabels = {
  'INCOME': 'Income',
  'EXPENSE': 'Spending',
  'TRANSFER': 'Own money',
  'IGNORE': 'Ignore',
};

const _kindHelp = {
  'INCOME': 'Money you earned: salary, interest, rent, refunds.',
  'EXPENSE': 'Money you spent.',
  'TRANSFER': 'Your own money moving: broker funds (Zerodha, Groww…), card bill, ATM cash, wallet top-up, '
      'between your accounts. The balance changes, but it is not income or spending.',
  'IGNORE': 'Not a real payment for you. It is hidden and never counted.',
};

/// Choice of kind (income / spending / own money / ignore), category and
/// subcategory for a payment that moved money [direction] ('IN' or 'OUT').
class PaymentKindPicker extends StatelessWidget {
  const PaymentKindPicker({
    super.key,
    required this.direction,
    required this.categories,
    required this.type,
    required this.categoryId,
    required this.subcategoryId,
    required this.onChanged,
  });

  final String direction;
  final List<Json> categories;
  final String type;
  final String? categoryId, subcategoryId;
  final void Function(String type, String? categoryId, String? subcategoryId) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kinds = [direction == 'IN' ? 'INCOME' : 'EXPENSE', 'TRANSFER', 'IGNORE'];
    final options = categories.where((c) => c['type'] == type).toList();
    final selected = options.where((c) => c['id'] == categoryId).firstOrNull;
    final subs = (selected?['subcategories'] as List?)?.cast<Json>() ?? const <Json>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [for (final k in kinds) ButtonSegment(value: k, label: Text(paymentKindLabels[k]!))],
        selected: {kinds.contains(type) ? type : kinds.first},
        onSelectionChanged: (s) => onChanged(s.first, null, null),
      ),
      const SizedBox(height: 6),
      Text(_kindHelp[type] ?? '', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      if (type != 'IGNORE') ...[
        const SizedBox(height: 14),
        Text('Category', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final c in options)
            ChoiceChip(
              label: Text(c['name'].toString()),
              selected: c['id'] == categoryId,
              onSelected: (on) => onChanged(type, on ? c['id'] as String : null, null),
            ),
        ]),
        if (subs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Detail (optional)', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final s in subs)
              ChoiceChip(
                label: Text(s['name'].toString()),
                selected: s['id'] == subcategoryId,
                onSelected: (on) => onChanged(type, categoryId, on ? s['id'] as String : null),
              ),
          ]),
        ],
      ],
    ]);
  }
}

/// "What is this payment?" for a pending payment, with the option to apply
/// the answer to every payment like it. Returns the classify result, or null.
Future<Json?> showTeachSheet(BuildContext context, {required Json item, required List<Json> categories}) {
  return showModalBottomSheet<Json>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TeachSheet(item: item, categories: categories),
  );
}

class _TeachSheet extends StatefulWidget {
  const _TeachSheet({required this.item, required this.categories});
  final Json item;
  final List<Json> categories;

  @override
  State<_TeachSheet> createState() => _TeachSheetState();
}

class _TeachSheetState extends State<_TeachSheet> {
  Json? _similar;
  late String _type;
  String? _categoryId, _subcategoryId;
  bool _remember = true, _autoAdd = false, _past = false, _busy = false;
  String? _error;

  CaptureService get _capture => context.services.capture!;
  String get _direction => widget.item['direction'] as String? ?? (widget.item['type'] == 'INCOME' ? 'IN' : 'OUT');

  @override
  void initState() {
    super.initState();
    _type = widget.item['type'] as String;
    _categoryId = widget.item['category_id'] as String?;
    _subcategoryId = widget.item['subcategory_id'] as String?;
    _capture.similar(widget.item['id'] as String).then((s) {
      if (!mounted) return;
      final rule = s['rule'] as Json?;
      setState(() {
        _similar = s;
        _autoAdd = rule?['auto_add'] == true;
      });
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final canRemember = _similar?['match_kind'] != null;
      final result = await _capture.classify(widget.item['id'] as String, {
        'type': _type,
        'category_id': _categoryId,
        'subcategory_id': _subcategoryId,
        'remember': canRemember && _remember,
        'auto_add': _remember && _autoAdd && _type != 'IGNORE',
        'apply_to_past': _remember && _past,
      });
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _similar;
    final otherPending = (s?['other_pending'] as int?) ?? 0;
    final past = (s?['past'] as int?) ?? 0;
    final name = widget.item['merchant'] ?? widget.item['description'];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Text('What is this payment?', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('$name · ${_direction == 'IN' ? 'money in' : 'money out'}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 16),
          PaymentKindPicker(
            direction: _direction,
            categories: widget.categories,
            type: _type,
            categoryId: _categoryId,
            subcategoryId: _subcategoryId,
            onChanged: (t, c, sub) => setState(() {
              _type = t;
              _categoryId = c;
              _subcategoryId = sub;
            }),
          ),
          const SizedBox(height: 16),
          const Divider(),
          if (s == null && _error == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else if (s?['match_kind'] == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'This message has no name or UPI ID to recognise it by, so only this payment changes.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _remember,
              onChanged: (v) => setState(() => _remember = v),
              title: const Text('Do the same for payments like this'),
              subtitle: Text('Recognised by ${s!['match_label']}'
                  '${otherPending > 0 ? '. $otherPending more waiting here will change too.' : '.'}'),
            ),
            if (_remember && _type != 'IGNORE')
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoAdd,
                onChanged: (v) => setState(() => _autoAdd = v ?? false),
                title: const Text('Add these to Money automatically'),
                subtitle: const Text("They skip the inbox (when the account is known). You can turn this off in Auto-categorise rules."),
              ),
            if (_remember && past > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _past,
                onChanged: (v) => setState(() => _past = v ?? false),
                title: Text('Also change the $past already added'),
                subtitle: const Text('Earlier payments like this in Money, with their account balances corrected.'),
              ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SaveButton(busy: _busy, onPressed: _save, label: _type == 'IGNORE' ? 'Ignore' : 'Save'),
        ]),
      ),
    );
  }
}

/// Learned rules: "payments like this are …". Edit, switch auto-add, delete.
class CaptureRulesScreen extends StatefulWidget {
  const CaptureRulesScreen({super.key});

  @override
  State<CaptureRulesScreen> createState() => _CaptureRulesScreenState();
}

class _CaptureRulesScreenState extends State<CaptureRulesScreen> {
  List<Json>? _rules;
  List<Json> _categories = [];
  String? _error;

  CaptureService get _capture => context.services.capture!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_capture.rules(), context.services.categories.list()]);
      if (!mounted) return;
      setState(() {
        _rules = r[0];
        _categories = r[1];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    }
    await _load();
  }

  Future<void> _edit(Json rule) async {
    final changes = await showModalBottomSheet<Json>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RuleEditSheet(rule: rule, categories: _categories),
    );
    if (changes == null) return;
    if (changes['delete'] == true) {
      await _run(() => _capture.deleteRule(rule['id'] as String));
      if (mounted) context.showSnack('Rule deleted');
    } else {
      await _run(() => _capture.updateRule(rule['id'] as String, changes));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = _rules;
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-categorise rules')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (_error != null)
            ErrorView(message: _error!, onRetry: _load)
          else if (rules == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (rules.isEmpty)
            const EmptyState(
              icon: Icons.auto_awesome_outlined,
              title: 'No rules yet',
              message: 'When you add a payment from the review inbox, or tap its category and choose '
                  '"Do the same for payments like this", Finverse remembers it here.',
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'New payments that match a rule arrive already filled in. Tap a rule to change it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final r in rules) _RuleTile(rule: r, onTap: () => _edit(r), onAutoAdd: (v) => _run(() => _capture.updateRule(r['id'] as String, {'auto_add': v}))),
          ],
        ]),
      ),
    );
  }
}

String _matchPrefix(String kind) => switch (kind) { 'UPI' => 'UPI ID', 'PARTY' => 'Name', _ => 'Wording' };

class _RuleTile extends StatelessWidget {
  const _RuleTile({required this.rule, required this.onTap, required this.onAutoAdd});
  final Json rule;
  final VoidCallback onTap;
  final ValueChanged<bool> onAutoAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = rule['type'] as String;
    final into = rule['direction'] == 'IN';
    final color = switch (type) { 'TRANSFER' => AppColors.info, 'IGNORE' => theme.colorScheme.outline, _ => into ? AppColors.income : AppColors.expense };
    final what = [
      paymentKindLabels[type],
      if (rule['category_name'] != null) rule['category_name'],
      if (rule['subcategory_name'] != null) rule['subcategory_name'],
      if (rule['account_name'] != null) rule['account_name'],
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(type == 'IGNORE' ? Icons.visibility_off_outlined : (into ? Icons.south_west : Icons.north_east), color: color, size: 18),
        ),
        title: Text('${_matchPrefix(rule['match_kind'] as String)}: ${rule['label']}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${into ? 'Money in' : 'Money out'} → $what\nUsed ${rule['hits']} time${rule['hits'] == 1 ? '' : 's'}'),
        isThreeLine: true,
        trailing: type == 'IGNORE'
            ? null
            : Tooltip(
                message: 'Add automatically',
                child: Switch(value: rule['auto_add'] == true, onChanged: onAutoAdd),
              ),
      ),
    );
  }
}

class _RuleEditSheet extends StatefulWidget {
  const _RuleEditSheet({required this.rule, required this.categories});
  final Json rule;
  final List<Json> categories;

  @override
  State<_RuleEditSheet> createState() => _RuleEditSheetState();
}

class _RuleEditSheetState extends State<_RuleEditSheet> {
  late String _type = widget.rule['type'] as String;
  late String? _categoryId = widget.rule['category_id'] as String?;
  late String? _subcategoryId = widget.rule['subcategory_id'] as String?;
  late bool _autoAdd = widget.rule['auto_add'] == true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
        Text('${_matchPrefix(widget.rule['match_kind'] as String)}: ${widget.rule['label']}',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        Text(widget.rule['direction'] == 'IN' ? 'Money in' : 'Money out', style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        PaymentKindPicker(
          direction: widget.rule['direction'] as String,
          categories: widget.categories,
          type: _type,
          categoryId: _categoryId,
          subcategoryId: _subcategoryId,
          onChanged: (t, c, s) => setState(() {
            _type = t;
            _categoryId = c;
            _subcategoryId = s;
          }),
        ),
        if (_type != 'IGNORE')
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _autoAdd,
            onChanged: (v) => setState(() => _autoAdd = v),
            title: const Text('Add automatically'),
            subtitle: const Text('Skip the review inbox for these payments'),
          ),
        const SizedBox(height: 12),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.pop(context, <String, dynamic>{
            'type': _type,
            'category_id': _categoryId,
            'subcategory_id': _subcategoryId,
            'auto_add': _autoAdd && _type != 'IGNORE',
          }),
          child: const Text('Save'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => Navigator.pop(context, <String, dynamic>{'delete': true}),
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          label: Text('Delete rule', style: TextStyle(color: theme.colorScheme.error)),
        ),
      ]),
    );
  }
}
