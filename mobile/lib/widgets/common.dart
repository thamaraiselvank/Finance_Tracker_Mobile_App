import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../services/services.dart';

/// Shortcuts for screens.
extension AppContext on BuildContext {
  AppState get appState => read<AppState>();

  /// The data layer. Screens use this instead of calling the API directly.
  Services get services => read<Services>();

  void showSnack(String message, {bool error = false}) {
    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(this).colorScheme.error : null,
      ));
  }
}

/// Loads data with [load] and renders loading / error / data states,
/// with pull-to-refresh built in.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({super.key, required this.load, required this.builder});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;

  @override
  State<AsyncView<T>> createState() => AsyncViewState<T>();
}

class AsyncViewState<T> extends State<AsyncView<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
      if (_data != null) context.showSnack(e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_data == null) {
      return ErrorView(message: _error?.toString() ?? 'Something went wrong.', onRetry: reload);
    }
    return RefreshIndicator(onRefresh: reload, child: widget.builder(context, _data as T, reload));
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_rounded, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
        ]),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(children: [
        Icon(icon, size: 48, color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(message!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline), textAlign: TextAlign.center),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
        ?trailing,
      ]),
    );
  }
}

/// Small labelled figure, used in summary grids.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.color, this.icon, this.subtitle});
  final String label;
  final String value;
  final Color? color;
  final IconData? icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[Icon(icon, size: 16, color: color ?? theme.colorScheme.outline), const SizedBox(width: 6)],
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ]),
      ),
    );
  }
}

/// Two-column grid of [StatTile]s.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: children[i]),
            const SizedBox(width: 10),
            Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox()),
          ]),
        ),
      ));
    }
    return Column(children: rows);
  }
}

class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value, this.color});
  final double value; // 0..1
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1).toDouble(),
        minHeight: 8,
        color: color,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}

Future<bool> confirmDialog(BuildContext context,
    {required String title, required String message, String confirmLabel = 'Delete', bool destructive = true}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error, minimumSize: const Size(80, 40)) : FilledButton.styleFrom(minimumSize: const Size(80, 40)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Opens a full-height bottom sheet for add/edit forms.
Future<T?> showFormSheet<T>(BuildContext context, {required String title, required Widget child}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        builder: (ctx, controller) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(children: [
              Expanded(child: Text(title, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
          ),
          Expanded(child: SingleChildScrollView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), child: child)),
        ]),
      ),
    ),
  );
}

// ---------- Form fields ----------

final _amountFormatter = FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'));

class AmountField extends StatelessWidget {
  const AmountField({super.key, required this.controller, required this.label, this.required = true, this.allowZero = false, this.prefix, this.suffix});
  final TextEditingController controller;
  final String label;
  final bool required;
  final bool allowZero;
  final String? prefix;
  final String? suffix;

  /// With a currency [prefix] (₹ $ € £), shows the amount formatted and in
  /// words while typing: "₹1,50,000 · One lakh fifty thousand rupees".
  @override
  Widget build(BuildContext context) {
    final currency = prefix == null ? null : (currencyForSymbol(prefix) ?? context.read<AppState>().money.code);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextFormField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [_amountFormatter],
          decoration: InputDecoration(
            labelText: label,
            prefixText: prefix != null ? '$prefix ' : null,
            suffixText: suffix,
            helperText: currency == null ? null : amountHelperText(value.text, currency),
            helperMaxLines: 3,
            helperStyle: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          validator: (v) {
            if (v == null || v.trim().isEmpty) return required ? 'Required' : null;
            final n = double.tryParse(v);
            if (n == null) return 'Enter a valid number';
            if (!allowZero && required && n <= 0) return 'Must be greater than 0';
            return null;
          },
        ),
      ),
    );
  }
}

/// The same "formatted · in words" line, for custom number fields.
class AmountWords extends StatelessWidget {
  const AmountWords({super.key, required this.controller, required this.currency});
  final TextEditingController controller;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final text = amountHelperText(value.text, currency);
        if (text == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6, left: 12),
          child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );
      },
    );
  }
}

class TextInput extends StatelessWidget {
  const TextInput({super.key, required this.controller, required this.label, this.required = false, this.maxLines = 1, this.keyboardType, this.obscure = false, this.validator});
  final TextEditingController controller;
  final String label;
  final bool required;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool obscure;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        obscureText: obscure,
        textCapitalization: keyboardType == null ? TextCapitalization.sentences : TextCapitalization.none,
        decoration: InputDecoration(labelText: label),
        validator: validator ?? (required ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null),
      ),
    );
  }
}

class DropdownInput<T> extends StatelessWidget {
  const DropdownInput({super.key, required this.label, required this.value, required this.items, required this.onChanged, this.required = true});
  final String label;
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<T>(
        initialValue: items.containsKey(value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: items.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
        onChanged: onChanged,
        validator: required ? (v) => v == null ? 'Required' : null : null,
      ),
    );
  }
}

class DateInput extends StatelessWidget {
  const DateInput({super.key, required this.label, required this.value, required this.onChanged, this.firstDate, this.lastDate, this.required = true});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: FormField<DateTime>(
        initialValue: value,
        validator: required ? (_) => value == null ? 'Required' : null : null,
        builder: (state) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? now,
              firstDate: firstDate ?? DateTime(now.year - 50),
              lastDate: lastDate ?? DateTime(now.year + 60),
            );
            if (picked != null) {
              onChanged(picked);
              state.didChange(picked);
            }
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              errorText: state.errorText,
              suffixIcon: value != null && !required
                  ? IconButton(icon: const Icon(Icons.clear), onPressed: () { onChanged(null); state.didChange(null); })
                  : const Icon(Icons.calendar_today_outlined, size: 20),
            ),
            child: Text(value == null ? 'Select date' : displayDate(value)),
          ),
        ),
      ),
    );
  }
}

/// Primary save button that shows a spinner while [busy].
class SaveButton extends StatelessWidget {
  const SaveButton({super.key, required this.busy, required this.onPressed, this.label = 'Save'});
  final bool busy;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : Text(label),
      ),
    );
  }
}

/// Wrap form-save logic: validates, toggles busy, shows API errors.
Future<void> runSave(
  BuildContext context, {
  required GlobalKey<FormState> formKey,
  required void Function(bool) setBusy,
  required Future<void> Function() action,
  String? successMessage,
}) async {
  if (!(formKey.currentState?.validate() ?? false)) return;
  setBusy(true);
  try {
    await action();
    if (!context.mounted) return;
    Navigator.pop(context, true);
    if (successMessage != null) context.showSnack(successMessage);
  } catch (e) {
    if (context.mounted) context.showSnack(e.toString(), error: true);
  } finally {
    if (context.mounted) setBusy(false);
  }
}

double? parseAmount(TextEditingController c) => double.tryParse(c.text.trim());

/// Watches the hide-amounts toggle and currency for money text.
class MoneyText extends StatelessWidget {
  const MoneyText(this.value, {super.key, this.style, this.compact = false, this.color});
  final dynamic value;
  final TextStyle? style;
  final bool compact;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final text = compact ? state.money.compact(value, hidden: state.hideAmounts) : state.money.format(value, hidden: state.hideAmounts);
    return Text(text, style: (style ?? const TextStyle()).copyWith(color: color));
  }
}

// ---------- Delete all ----------
//
// Each dialog owns its controllers/notifiers and disposes them in its own
// dispose(), i.e. only after the close animation has finished. Disposing them
// right after showDialog() returns crashes the still-animating dialog.

/// Strong confirmation for bulk deletes: shows the count and requires typing DELETE.
Future<bool> confirmDeleteAll(BuildContext context, {required int count, required String what, String? extraWarning}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _ConfirmDeleteAllDialog(count: count, what: what, extraWarning: extraWarning),
  );
  return ok ?? false;
}

class _ConfirmDeleteAllDialog extends StatefulWidget {
  const _ConfirmDeleteAllDialog({required this.count, required this.what, this.extraWarning});
  final int count;
  final String what;
  final String? extraWarning;

  @override
  State<_ConfirmDeleteAllDialog> createState() => _ConfirmDeleteAllDialogState();
}

class _ConfirmDeleteAllDialogState extends State<_ConfirmDeleteAllDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final matches = _controller.text.trim().toUpperCase() == 'DELETE';
    return AlertDialog(
      icon: Icon(Icons.delete_forever, color: error, size: 32),
      title: Text('Delete ${widget.count} ${widget.what}?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This permanently deletes ${widget.count} ${widget.what}. It cannot be undone.'),
          if (widget.extraWarning != null) ...[const SizedBox(height: 8), Text(widget.extraWarning!)],
          const SizedBox(height: 16),
          const Text('Type DELETE to confirm:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(hintText: 'DELETE', isDense: true),
            onChanged: (_) => setState(() {}),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: error, minimumSize: const Size(80, 40)),
          onPressed: matches ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete all'),
        ),
      ],
    );
  }
}

/// Runs each delete (a few at a time) behind a progress dialog.
/// Returns how many failed.
Future<int> bulkDelete(BuildContext context, List<Future<void> Function()> deletes) async {
  final failed = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BulkDeleteDialog(deletes: deletes),
  );
  return failed ?? 0;
}

class _BulkDeleteDialog extends StatefulWidget {
  const _BulkDeleteDialog({required this.deletes});
  final List<Future<void> Function()> deletes;

  @override
  State<_BulkDeleteDialog> createState() => _BulkDeleteDialogState();
}

class _BulkDeleteDialogState extends State<_BulkDeleteDialog> {
  int _done = 0;
  int _failed = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    const batch = 5;
    for (var i = 0; i < widget.deletes.length; i += batch) {
      await Future.wait(widget.deletes.skip(i).take(batch).map((deleteOne) async {
        try {
          await deleteOne();
        } catch (_) {
          _failed++;
        }
        if (mounted) setState(() => _done++);
      }));
    }
    if (mounted) Navigator.of(context).pop(_failed);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.deletes.length;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: total == 0 ? null : _done / total),
          const SizedBox(height: 16),
          Text('Deleting $_done of $total…'),
        ]),
      ),
    );
  }
}

/// Red "Delete all" button placed at the end of a list.
class DeleteAllButton extends StatelessWidget {
  const DeleteAllButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: error, side: BorderSide(color: error.withValues(alpha: 0.5)), minimumSize: const Size.fromHeight(46)),
        onPressed: onPressed,
        icon: const Icon(Icons.delete_sweep_outlined),
        label: Text(label),
      ),
    );
  }
}

/// Confirm, delete every item via [deleteItem], report the result, then [onDone].
Future<void> deleteAllFlow<T>(
  BuildContext context, {
  required List<T> items,
  required String what,
  required Future<void> Function(T) deleteItem,
  required VoidCallback onDone,
  String? extraWarning,
}) async {
  if (items.isEmpty) return;
  final ok = await confirmDeleteAll(context, count: items.length, what: what, extraWarning: extraWarning);
  if (!ok || !context.mounted) return;
  final failed = await bulkDelete(context, [for (final item in items) () => deleteItem(item)]);
  if (!context.mounted) return;
  context.showSnack(failed == 0 ? 'Deleted ${items.length} $what' : 'Deleted ${items.length - failed} $what; $failed could not be deleted', error: failed > 0);
  onDone();
}
