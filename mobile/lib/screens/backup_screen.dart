import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../backup/backup_file.dart';
import '../backup/backup_manager.dart';
import '../backup/drive_store.dart';
import '../capture/sms_sync.dart';
import '../core/app_state.dart';
import '../widgets/common.dart';
import 'export_screen.dart';

/// Backup & restore (phone-only version), plus the way into exports.
class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  static final _when = DateFormat('d MMM yyyy, h:mm a');

  Future<void> _run(BuildContext context, Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null && context.mounted) context.showSnack(done);
    } on DriveCancelled {
      // The user closed Google's screen: nothing to say.
    } catch (e) {
      if (context.mounted) context.showSnack(e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<BackupManager>();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final last = m.lastBackupAt;

    Future<bool> needPassword() async {
      if (m.hasPassword) return true;
      return await showPasswordSetup(context) ?? false;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup & export'),
        bottom: m.busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: last == null ? colors.errorContainer : null,
            child: ListTile(
              leading: Icon(
                last == null ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
                color: last == null ? colors.onErrorContainer : colors.primary,
              ),
              title: Text(last == null ? 'No backup yet' : 'Last backup: ${_when.format(last)}'),
              subtitle: Text(
                last == null
                    ? 'Your data is only on this phone. If the phone is lost or reset, a backup is the only way to get it back.'
                    : 'Saved to ${m.lastBackupPlace == 'file'
                          ? 'a file you chose'
                          : m.lastBackupPlace == 'shared'
                          ? 'a shared file'
                          : m.lastBackupPlace}.',
              ),
            ),
          ),
          if (m.autoProblem != null)
            Card(
              color: colors.tertiaryContainer,
              child: ListTile(leading: const Icon(Icons.cloud_off_outlined), title: Text(m.autoProblem!)),
            ),

          // ---- password -------------------------------------------------------
          const SectionHeader('Backup password'),
          Card(
            child: _ActionTile(
              icon: Icons.password,
              title: m.hasPassword ? 'Saved on this phone' : 'Not set yet',
              subtitle: 'Backups are locked with this password. You need it to restore on a new phone.',
              actions: [
                FilledButton.tonal(
                  onPressed: m.busy ? null : () => showPasswordSetup(context, change: m.hasPassword),
                  child: Text(m.hasPassword ? 'Change password' : 'Set password'),
                ),
              ],
            ),
          ),

          // ---- Google Drive -----------------------------------------------------
          const SectionHeader('Google Drive'),
          Card(
            child: m.driveConnected
                ? Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.add_to_drive),
                        title: Text(m.driveEmail ?? 'Connected'),
                        subtitle: Text(
                          m.lastDriveBackupAt == null
                              ? 'No backup in Drive yet'
                              : 'Last Drive backup ${_when.format(m.lastDriveBackupAt!)} · keeps the newest ${DriveBackupStore.keep}',
                        ),
                      ),
                      _ActionTile(
                        icon: Icons.schedule,
                        title: 'Automatic backup',
                        subtitle: 'When you open the app and one is due',
                        actions: [
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<AutoBackup>(
                              showSelectedIcon: false,
                              segments: [for (final a in AutoBackup.values) ButtonSegment(value: a, label: Text(a.label))],
                              selected: {m.auto},
                              onSelectionChanged: (s) async {
                                if (s.first != AutoBackup.off && !await needPassword()) return;
                                await m.setAuto(s.first);
                              },
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              onPressed: m.busy
                                  ? null
                                  : () async {
                                      final ok = await confirmDialog(
                                        context,
                                        title: 'Disconnect Google Drive?',
                                        message: 'Backups already in Drive stay there. Automatic backup will stop.',
                                        confirmLabel: 'Disconnect',
                                      );
                                      if (ok) await m.disconnectDrive();
                                    },
                              child: const Text('Disconnect'),
                            ),
                            FilledButton.icon(
                              onPressed: m.busy
                                  ? null
                                  : () async {
                                      if (!await needPassword()) return;
                                      if (context.mounted) await _run(context, m.backupToDrive, done: 'Backed up to Google Drive.');
                                    },
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: const Text('Back up now'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  )
                : _ActionTile(
                    icon: Icons.add_to_drive,
                    title: 'Back up to your Google Drive',
                    subtitle: 'Saved in a hidden Finverse folder. Google only stores the locked file and cannot read it.',
                    actions: [
                      FilledButton.icon(
                        onPressed: m.busy ? null : () => _run(context, m.connectDrive, done: 'Google Drive connected.'),
                        icon: const Icon(Icons.link),
                        label: const Text('Connect Google Drive'),
                      ),
                    ],
                  ),
          ),

          // ---- file -------------------------------------------------------------
          const SectionHeader('Backup file'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: const Text('Save backup file'),
                  subtitle: const Text('Choose where: Downloads, Google Drive, a pen drive…'),
                  enabled: !m.busy,
                  onTap: () async {
                    if (!await needPassword()) return;
                    if (!context.mounted) return;
                    await _run(context, () async {
                      if (await m.saveToDevice() && context.mounted) context.showSnack('Backup saved.');
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share backup file'),
                  subtitle: const Text('Send it to yourself on WhatsApp, email…'),
                  enabled: !m.busy,
                  onTap: () async {
                    if (!await needPassword()) return;
                    if (context.mounted) await _run(context, m.share);
                  },
                ),
              ],
            ),
          ),

          // ---- restore ----------------------------------------------------------
          const SectionHeader('Restore'),
          Card(
            child: Column(
              children: [
                if (m.driveConnected)
                  ListTile(
                    leading: const Icon(Icons.cloud_download_outlined),
                    title: const Text('Restore from Google Drive'),
                    enabled: !m.busy,
                    onTap: () => restoreFromDrive(context),
                  ),
                ListTile(
                  leading: const Icon(Icons.restore_page_outlined),
                  title: const Text('Restore from a backup file'),
                  subtitle: const Text('Replaces everything on this phone with the backup'),
                  enabled: !m.busy,
                  onTap: () => restoreFromFile(context),
                ),
              ],
            ),
          ),

          // ---- export -----------------------------------------------------------
          const SectionHeader('Export'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.table_view_outlined),
              title: const Text('Export to Excel, CSV or PDF'),
              subtitle: const Text('Transactions, holdings, goals and more, in a file you can open anywhere'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ExportScreen())),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Backups are encrypted on this phone before they are saved anywhere. If you forget the backup password, '
            'nobody can open them, not even Finverse.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.outline),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Password
// ---------------------------------------------------------------------------

/// Asks for a new backup password (twice). With [change], first asks for the
/// current one. Returns true when saved.
Future<bool?> showPasswordSetup(BuildContext context, {bool change = false}) => showDialog<bool>(
  context: context,
  builder: (_) => _PasswordSetupDialog(change: change),
);

class _PasswordSetupDialog extends StatefulWidget {
  const _PasswordSetupDialog({required this.change});
  final bool change;

  @override
  State<_PasswordSetupDialog> createState() => _PasswordSetupDialogState();
}

class _PasswordSetupDialogState extends State<_PasswordSetupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _password = TextEditingController();
  final _again = TextEditingController();
  bool _show = false;
  String? _currentError;

  @override
  void dispose() {
    for (final c in [_current, _password, _again]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final manager = context.read<BackupManager>();
    if (widget.change && !await manager.isCurrentPassword(_current.text)) {
      setState(() => _currentError = 'That is not the current backup password');
      return;
    }
    await manager.setPassword(_password.text);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    InputDecoration deco(String label, {String? error}) => InputDecoration(
      labelText: label,
      errorText: error,
      suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
    );
    return AlertDialog(
      title: Text(widget.change ? 'Change backup password' : 'Set a backup password'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.change
                    ? 'New backups will use the new password. Backups you already made still open with the old one.'
                    : 'You will need this password to restore your data on a new phone. It is saved securely on this phone for future backups.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (widget.change) ...[
                TextFormField(
                  controller: _current,
                  obscureText: !_show,
                  decoration: deco('Current password', error: _currentError),
                ),
                const SizedBox(height: 8),
              ],
              TextFormField(
                controller: _password,
                obscureText: !_show,
                decoration: deco('Backup password'),
                validator: (v) => (v ?? '').length < minBackupPasswordLength ? 'At least $minBackupPasswordLength characters' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _again,
                obscureText: !_show,
                decoration: deco('Type it again'),
                validator: (v) => v != _password.text ? 'The passwords do not match' : null,
              ),
              const SizedBox(height: 12),
              Text(
                'Write it down somewhere safe. If it is forgotten, nobody can open your backups, not even Finverse.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Restore
// ---------------------------------------------------------------------------

/// Picks a backup file and restores it (also used from onboarding).
Future<void> restoreFromFile(BuildContext context) async {
  final m = context.read<BackupManager>();
  try {
    final path = await m.pickFile();
    if (path != null && context.mounted) await _restore(context, path);
  } catch (e) {
    if (context.mounted) context.showSnack(e.toString(), error: true);
  }
}

/// Lists the backups in Drive and restores the chosen one.
Future<void> restoreFromDrive(BuildContext context) async {
  final m = context.read<BackupManager>();
  try {
    final backups = await m.driveBackups();
    if (!context.mounted) return;
    if (backups.isEmpty) {
      context.showSnack('There are no Finverse backups in this Google Drive yet.');
      return;
    }
    final when = DateFormat('d MMM yyyy, h:mm a');
    final chosen = await showModalBottomSheet<DriveBackup>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Choose a backup', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (final b in backups)
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: Text(when.format(b.createdAt)),
                subtitle: Text('${(b.size / 1024).ceil()} KB'),
                onTap: () => Navigator.pop(ctx, b),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !context.mounted) return;
    final path = await m.downloadFromDrive(chosen);
    if (context.mounted) await _restore(context, path);
  } on DriveCancelled {
    // Closed Google's screen.
  } catch (e) {
    if (context.mounted) context.showSnack(e.toString(), error: true);
  }
}

Future<void> _restore(BuildContext context, String path) async {
  final m = context.read<BackupManager>();
  try {
    // Ask for the password, then show what's inside before replacing anything.
    final (password, summary) = await _unlock(context, path) ?? (null, null);
    if (password == null || summary == null || !context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _RestoreConfirmDialog(summary: summary),
    );
    if (ok != true || !context.mounted) return;
    await m.restore(path, password);
    if (!context.mounted) return;
    // This screen closes below, so take what is needed first.
    final sms = context.read<SmsSync?>();
    final appState = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((r) => r.isFirst);
    await appState.reload();
    await sms?.refreshCount();
    messenger.showSnackBar(const SnackBar(content: Text('Backup restored.')));
  } catch (e) {
    if (context.mounted) context.showSnack(e.toString(), error: true);
  } finally {
    m.discard(path);
  }
}

/// Returns the working password and the backup's summary, or null if cancelled.
Future<(String, Map<String, dynamic>)?> _unlock(BuildContext context, String path) => showDialog<(String, Map<String, dynamic>)>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _UnlockDialog(path: path),
);

class _UnlockDialog extends StatefulWidget {
  const _UnlockDialog({required this.path});
  final String path;

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _password = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final summary = await context.read<BackupManager>().inspect(widget.path, _password.text);
      if (mounted) Navigator.pop(context, (_password.text, summary));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Backup password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter the password this backup was made with.'),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: !_show,
            enabled: !_busy,
            onSubmitted: (_) => _open(),
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
            ),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _open, child: const Text('Open')),
      ],
    );
  }
}

class _RestoreConfirmDialog extends StatelessWidget {
  const _RestoreConfirmDialog({required this.summary});
  final Map<String, dynamic> summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = Map<String, dynamic>.from(summary['counts'] as Map);
    final created = DateTime.tryParse('${summary['created_at']}')?.toLocal();
    const labels = {
      'accounts': 'Accounts',
      'transactions': 'Transactions',
      'inbox': 'Waiting in the review inbox',
      'budgets': 'Budgets',
      'goals': 'Goals',
      'debts': 'Debts & loans',
      'insurance': 'Insurance policies',
      'holdings': 'Wealth holdings',
      'recurring': 'Bills & recurring',
      'rules': 'Auto-categorise rules',
    };
    return AlertDialog(
      title: const Text('Restore this backup?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (created != null) Text('Made on ${DateFormat('d MMM yyyy, h:mm a').format(created)}', style: theme.textTheme.titleSmall),
            if (summary['profile_name'] != null) Text('Profile: ${summary['profile_name']}'),
            const SizedBox(height: 8),
            for (final MapEntry(:key, :value) in labels.entries)
              if ((counts[key] as int? ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(value)),
                      Text('${counts[key]}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            const SizedBox(height: 12),
            Text(
              'Everything currently on this phone will be replaced by this backup.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

/// Icon, title and explanation, with the buttons underneath (not squeezed in
/// beside the text, which breaks on narrow phones and with large fonts).
class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.title, required this.subtitle, required this.actions});
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
            ),
          ]),
        ),
      ]),
    );
  }
}
