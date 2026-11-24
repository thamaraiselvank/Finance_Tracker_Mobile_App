import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../config.dart';

/// Free vs Pro.
///
/// Everyone installs the same app; Pro features are locked until Pro is
/// unlocked. For now the only way to unlock is the "Pretend Pro" developer
/// switch (More → Developer), so both versions can be tested on a phone.
/// Google Play Billing will set [isPro] from the user's real purchase later.
///
/// The cloud build is not sold on the Play Store, so everything is open there.
class ProStatus extends ChangeNotifier {
  ProStatus({@visibleForTesting this.forced});

  /// Tests only: fixes [isPro] to this value.
  final bool? forced;

  static const _pretendKey = 'finverse_pretend_pro';
  final _storage = const FlutterSecureStorage();

  /// Shows More → Developer. On in debug runs, and in an APK built with
  /// `--dart-define=FINVERSE_DEV=true`. Never in the Play Store build.
  static const bool devTools = kDebugMode || bool.fromEnvironment('FINVERSE_DEV');

  bool _pretendPro = false;
  bool get pretendPro => _pretendPro;

  bool get isPro => forced ?? (!AppConfig.isLocal || (devTools && _pretendPro));

  Future<void> init() async {
    if (!devTools) return;
    try {
      _pretendPro = await _storage.read(key: _pretendKey) == 'true';
    } catch (_) {
      _pretendPro = false;
    }
    notifyListeners();
  }

  Future<void> setPretendPro(bool value) async {
    _pretendPro = value;
    notifyListeners();
    await _storage.write(key: _pretendKey, value: value.toString());
  }
}

/// How much the free version allows.
class FreeLimits {
  static const accounts = 3;
  static const budgets = 3;
  static const recurring = 5;

  /// Payments from SMS, UPI notifications and screenshots added to Money
  /// from the review inbox, per calendar month.
  static const capturedPerMonth = 30;
}

/// A locked area: its name and the one line that sells it.
enum ProFeature {
  rules('Auto-categorise rules', 'Teach Finverse once and similar payments are sorted for you, even added automatically.'),
  insights('Insights', 'Budget alerts, unusual payments and bills due, worked out on your phone.'),
  trends('Trends & comparisons', 'Month by month, category by category, and how your wealth grows.'),
  import('Import', 'Bring in bank statements (CSV, Excel, PDF) and broker holdings in one go.'),
  tax('Income tax estimate', 'Old vs new regime from your own numbers.'),
  health('Financial health', 'Emergency fund, insurance cover and debt ratio at a glance.'),
  checkup('Financial check-up', '15 questions and personalised next steps.'),
  debts('Debts & loans', 'Every loan in one place, with payoff plans.'),
  insurance('Insurance', 'Policies, cover and renewal reminders.'),
  wealth('Wealth', 'Stocks, funds, gold and property with live prices and net worth.'),
  goals('Goals', 'Save for a house, a trip or retirement and track progress.'),
  calculators('All calculators', 'CAGR and FIRE (early retirement) calculators.'),
  exportFormats('Excel & PDF export', 'Spreadsheet and printable reports for any period.'),
  autoBackup('Automatic backup', 'Encrypted backup to your Google Drive every day or week.'),
  unlimited('No limits', 'Unlimited accounts, budgets, bills and automatic payments.');

  const ProFeature(this.title, this.pitch);
  final String title;
  final String pitch;
}

extension ProContext on BuildContext {
  bool get isPro => watch<ProStatus>().isPro;
  bool get isProNow => read<ProStatus>().isPro;
}

/// Shows [child] to Pro users and a locked page to everyone else. Rebuilds
/// when Pro changes, so flipping the developer switch takes effect at once.
class ProGate extends StatelessWidget {
  const ProGate({super.key, required this.feature, required this.child});
  final ProFeature feature;
  final Widget child;

  @override
  Widget build(BuildContext context) => context.isPro ? child : LockedFeatureScreen(feature: feature);
}

/// The 🔒 shown next to a Pro item for free users (nothing for Pro users).
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.isPro) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock, size: 12, color: scheme.onTertiaryContainer),
        const SizedBox(width: 3),
        Text('PRO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onTertiaryContainer)),
      ]),
    );
  }
}

/// What a free user sees in place of a Pro screen.
class LockedFeatureScreen extends StatelessWidget {
  const LockedFeatureScreen({super.key, required this.feature});
  final ProFeature feature;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(feature.title)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 36, backgroundColor: scheme.tertiaryContainer, child: Icon(Icons.lock_outline, size: 36, color: scheme.onTertiaryContainer)),
            const SizedBox(height: 20),
            Text('${feature.title} is in Finverse Pro', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(feature.pitch, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => openUpgrade(context),
              icon: const Icon(Icons.workspace_premium_outlined),
              label: const Text('See Finverse Pro'),
            ),
          ]),
        ),
      ),
    );
  }
}

Future<void> openUpgrade(BuildContext context, {String? reason}) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => UpgradeScreen(reason: reason)));

/// For free limits: true when the user may add [adding] more (Pro, or the
/// total stays within [limit]); otherwise explains, offers Pro, returns false.
Future<bool> checkFreeLimit(BuildContext context, {required int current, int adding = 1, required int limit, required String what}) async {
  if (context.isProNow || current + adding <= limit) return true;
  final upgrade = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.lock_outline),
      title: Text('Free version: up to $limit $what'),
      content: Text(adding == 1
          ? 'You have $current $what. Finverse Pro has no limits.'
          : 'You have $current, and this would add $adding more. Finverse Pro has no limits.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('See Pro')),
      ],
    ),
  );
  if (upgrade == true && context.mounted) await openUpgrade(context, reason: 'Free version: up to $limit $what.');
  return false;
}

/// Free vs Pro, with prices. Buying is not connected yet (Google Play
/// Billing comes next); in test builds it points to the developer switch.
class UpgradeScreen extends StatelessWidget {
  const UpgradeScreen({super.key, this.reason});
  final String? reason;

  static const _free = [
    'Add income and expenses, search and edit',
    'Up to ${FreeLimits.accounts} accounts and ${FreeLimits.budgets} budgets',
    'Up to ${FreeLimits.recurring} bills & recurring items',
    '${FreeLimits.capturedPerMonth} automatic payments a month (SMS, UPI, screenshots)',
    'Monthly summary and reports',
    'SIP, lumpsum and EMI calculators',
    'App lock, encrypted data, backup & restore',
    'CSV export',
  ];

  @override
  Widget build(BuildContext context) {
    final pro = context.isPro;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Finverse Pro')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (pro)
          Card(
            color: scheme.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.verified, color: scheme.onPrimaryContainer),
              title: Text('Pro is on', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer)),
              subtitle: Text('Every feature is unlocked.', style: TextStyle(color: scheme.onPrimaryContainer)),
            ),
          )
        else if (reason != null)
          Card(child: ListTile(leading: const Icon(Icons.info_outline), title: Text(reason!))),
        const SizedBox(height: 8),
        Text('Pro: Finverse does it for you', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            for (final f in ProFeature.values)
              ListTile(
                dense: true,
                leading: Icon(Icons.check_circle, color: scheme.primary),
                title: Text(f.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(f.pitch),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        Text('Free, always', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            for (final f in _free) ListTile(dense: true, leading: const Icon(Icons.check), title: Text(f)),
          ]),
        ),
        if (!pro) ...[
          const SizedBox(height: 16),
          for (final (plan, price, note) in const [
            ('Yearly', '₹399 / year', 'Best value'),
            ('Monthly', '₹49 / month', null),
            ('Lifetime', '₹999 once', 'Pay once, Pro forever'),
          ])
            Card(
              child: ListTile(
                title: Text(plan, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: note == null ? null : Text(note),
                trailing: Text(price, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                onTap: () => _buy(context),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _buy(context),
            icon: const Icon(Icons.workspace_premium_outlined),
            label: const Text('Upgrade to Pro'),
          ),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }

  void _buy(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ProStatus.devTools
          ? 'Buying is not connected yet. To test Pro, turn on More → Developer → Pretend Pro.'
          : 'Finverse Pro is coming soon.'),
    ));
  }
}

/// More → Developer (test builds only).
class DeveloperScreen extends StatelessWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pro = context.watch<ProStatus>();
    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.workspace_premium_outlined),
            title: const Text('Pretend Pro'),
            subtitle: Text(pro.isPro ? 'On: every feature is unlocked' : 'Off: you see the free version, with 🔒 on Pro features'),
            value: pro.pretendPro,
            onChanged: AppConfig.isLocal ? (v) => context.read<ProStatus>().setPretendPro(v) : null,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Only in test builds; never shown in the Play Store version. '
            'Your data is never touched: turning Pro off only locks screens again.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}
