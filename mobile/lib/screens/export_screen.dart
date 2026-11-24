import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../export/export_data.dart';
import '../export/export_files.dart';
import '../widgets/common.dart';

/// Quick periods for transaction exports.
enum _Period {
  thisMonth('This month'),
  lastMonth('Last month'),
  thisFy('This financial year'),
  lastFy('Last financial year'),
  thisYear('This calendar year'),
  all('All time'),
  custom('Choose dates…');

  const _Period(this.label);
  final String label;
}

/// Exports data to Excel, CSV or PDF, then saves or shares the file.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, this.sections, this.start, this.end, this.type, this.categoryId});

  /// Preselected sections (default: transactions).
  final Set<ExportSection>? sections;

  /// Preselected transaction filters (e.g. what the Money screen shows).
  final DateTime? start;
  final DateTime? end;
  final String? type;
  final String? categoryId;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  late Set<ExportSection> _sections;
  _Period _period = _Period.thisMonth;
  DateTime? _start, _end;
  String _type = 'ALL';
  String? _accountId, _categoryId, _assetClass;
  late DateTime _budgetMonth;
  ExportFormat _format = ExportFormat.xlsx;
  bool _busy = false;

  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _categories = [];
  List<String> _assetClasses = [];

  @override
  void initState() {
    super.initState();
    _sections = {...?widget.sections};
    if (_sections.isEmpty) _sections.add(ExportSection.transactions);
    final now = DateTime.now();
    _budgetMonth = DateTime(now.year, now.month);
    _type = widget.type ?? 'ALL';
    _categoryId = widget.categoryId;
    if (widget.start != null || widget.end != null) {
      _period = _Period.custom;
      _start = widget.start;
      _end = widget.end;
    } else {
      _setPeriod(_Period.thisMonth);
    }
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final s = context.services;
    try {
      final results = await Future.wait([s.accounts.list(), s.categories.list(), s.assets.summary()]);
      if (!mounted) return;
      setState(() {
        _accounts = results[0] as List<Map<String, dynamic>>;
        _categories = results[1] as List<Map<String, dynamic>>;
        _assetClasses = [for (final c in ((results[2] as Map)['asset_classes'] as List? ?? const [])) '${(c as Map)['asset_class']}'];
        if (_categoryId != null && !_categories.any((c) => c['id'] == _categoryId)) _categoryId = null;
      });
    } catch (_) {
      // Filters are optional; the export still works without them.
    }
  }

  void _setPeriod(_Period p) {
    final now = DateTime.now();
    // Indian financial year: 1 April to 31 March.
    final fyStart = now.month >= 4 ? now.year : now.year - 1;
    final (start, end) = switch (p) {
      _Period.thisMonth => (DateTime(now.year, now.month, 1), DateTime(now.year, now.month + 1, 0)),
      _Period.lastMonth => (DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
      _Period.thisFy => (DateTime(fyStart, 4, 1), DateTime(fyStart + 1, 3, 31)),
      _Period.lastFy => (DateTime(fyStart - 1, 4, 1), DateTime(fyStart, 3, 31)),
      _Period.thisYear => (DateTime(now.year, 1, 1), DateTime(now.year, 12, 31)),
      _Period.all => (null, null),
      _Period.custom => (_start, _end),
    };
    _period = p;
    _start = start;
    _end = end;
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _start != null && _end != null ? DateTimeRange(start: _start!, end: _end!) : null,
    );
    if (range != null) {
      setState(() {
        _period = _Period.custom;
        _start = range.start;
        _end = range.end;
      });
    }
  }

  Future<ExportFile> _build() async {
    final state = context.read<AppState>();
    final services = context.services;
    final tables = await buildExportTables(
      services,
      ExportOptions(
        sections: _sections,
        start: _start,
        end: _end,
        type: _type,
        accountId: _accountId,
        categoryId: _categoryId,
        budgetMonth: _budgetMonth.month,
        budgetYear: _budgetMonth.year,
        assetClass: _assetClass,
      ),
    );
    ReportFonts? fonts;
    if (_format == ExportFormat.pdf) {
      fonts = ReportFonts(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'), await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    }
    return buildExportFile(tables, _format, currency: state.money.code, now: DateTime.now(), ownerName: state.displayName, fonts: fonts);
  }

  Future<void> _export({required bool share}) async {
    if (_sections.isEmpty) {
      context.showSnack('Choose at least one thing to export.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final file = await _build();
      if (share) {
        final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}export');
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        final path = '${dir.path}${Platform.pathSeparator}${file.name}';
        await File(path).writeAsBytes(file.bytes, flush: true);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path, mimeType: file.mimeType)],
            subject: file.name,
          ),
        );
      } else {
        final saved = await FilePicker.saveFile(fileName: file.name, bytes: file.bytes, mimeType: file.mimeType, dialogTitle: 'Save export');
        if (saved != null && mounted) context.showSnack('Saved ${file.name}');
      }
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final months = [for (var i = 0; i < 24; i++) DateTime(DateTime.now().year, DateTime.now().month - i)];

    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const SectionHeader('What to export'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in ExportSection.values)
                FilterChip(
                  label: Text(s.label),
                  selected: _sections.contains(s),
                  onSelected: (on) => setState(() => on ? _sections.add(s) : _sections.remove(s)),
                ),
            ],
          ),

          if (_sections.contains(ExportSection.transactions)) ...[
            const SectionHeader('Transactions'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownInput<_Period>(
                      key: ValueKey(_period),
                      label: 'Period',
                      value: _period,
                      items: {for (final p in _Period.values) p: p.label},
                      onChanged: (p) {
                        if (p == null) return;
                        if (p == _Period.custom) {
                          _pickDates();
                        } else {
                          setState(() => _setPeriod(p));
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          Expanded(child: Text(periodLabel(_start, _end), style: theme.textTheme.bodySmall)),
                          TextButton(onPressed: _pickDates, child: const Text('Change dates')),
                        ],
                      ),
                    ),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'ALL', label: Text('All')),
                        ButtonSegment(value: 'INCOME', label: Text('Income')),
                        ButtonSegment(value: 'EXPENSE', label: Text('Expense')),
                        ButtonSegment(value: 'TRANSFER', label: Text('Transfer')),
                      ],
                      selected: {_type},
                      onSelectionChanged: (s) => setState(() {
                        _type = s.first;
                        // A category of another type would match nothing.
                        if (_type != 'ALL' && !_categories.any((c) => c['id'] == _categoryId && c['type'] == _type)) _categoryId = null;
                      }),
                    ),
                    const SizedBox(height: 12),
                    DropdownInput<String?>(
                      key: ValueKey('account-${_accounts.length}'),
                      label: 'Account',
                      required: false,
                      value: _accountId,
                      items: {null: 'All accounts', for (final a in _accounts) a['id'] as String: '${a['name']}'},
                      onChanged: (v) => setState(() => _accountId = v),
                    ),
                    DropdownInput<String?>(
                      key: ValueKey('category-$_type-${_categories.length}'),
                      label: 'Category',
                      required: false,
                      value: _categoryId,
                      items: {
                        null: 'All categories',
                        for (final c in _categories.where((c) => _type == 'ALL' || c['type'] == _type)) c['id'] as String: '${c['name']}',
                      },
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                  ],
                ),
              ),
            ),
          ],

          if (_sections.contains(ExportSection.budgets)) ...[
            const SectionHeader('Budgets'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: DropdownInput<DateTime>(
                  label: 'Month',
                  value: _budgetMonth,
                  items: {for (final m in months) m: DateFormat('MMMM yyyy').format(m)},
                  onChanged: (v) => setState(() => _budgetMonth = v ?? _budgetMonth),
                ),
              ),
            ),
          ],

          if (_sections.contains(ExportSection.holdings) && _assetClasses.length > 1) ...[
            const SectionHeader('Wealth holdings'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: DropdownInput<String?>(
                  label: 'Type',
                  required: false,
                  value: _assetClass,
                  items: {null: 'All holdings', for (final c in _assetClasses) c: humanize(c)},
                  onChanged: (v) => setState(() => _assetClass = v),
                ),
              ),
            ),
          ],

          const SectionHeader('Format'),
          SegmentedButton<ExportFormat>(
            segments: const [
              ButtonSegment(value: ExportFormat.xlsx, label: Text('Excel'), icon: Icon(Icons.grid_on)),
              ButtonSegment(value: ExportFormat.csv, label: Text('CSV'), icon: Icon(Icons.notes)),
              ButtonSegment(value: ExportFormat.pdf, label: Text('PDF'), icon: Icon(Icons.picture_as_pdf_outlined)),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 8),
          Text(switch (_format) {
            ExportFormat.xlsx => 'One sheet per section. Opens in Excel or Google Sheets; amounts and dates can be summed and sorted.',
            ExportFormat.csv => _sections.length > 1 ? 'One CSV file per section, together in a .zip file.' : 'A plain table for other apps and spreadsheets.',
            ExportFormat.pdf => 'A printable report with totals, ready to send to your CA or keep for records.',
          }, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: ListTile(
              leading: const Icon(Icons.lock_open_outlined),
              title: const Text('Exported files are not password-protected'),
              subtitle: const Text('Anyone who gets the file can read it. Nothing is sent anywhere unless you share it.'),
            ),
          ),
          const SizedBox(height: 16),
          if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: _busy ? null : () => _export(share: true),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: _busy ? null : () => _export(share: false),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// App bar button that opens [ExportScreen] with [sections] preselected.
class ExportButton extends StatelessWidget {
  const ExportButton({super.key, required this.sections});
  final Set<ExportSection> sections;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Export',
    icon: const Icon(Icons.ios_share),
    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExportScreen(sections: sections))),
  );
}
