import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/theme.dart';
import 'common.dart';

Color parseHexColor(String? hex, Color fallback) {
  if (hex == null) return fallback;
  final clean = hex.replaceFirst('#', '');
  if (clean.length != 6) return fallback;
  final value = int.tryParse(clean, radix: 16);
  return value == null ? fallback : Color(0xFF000000 | value);
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.tx, this.onTap});
  final Map<String, dynamic> tx;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = (tx['type'] as String? ?? '').toUpperCase();
    final isIncome = type == 'INCOME';
    final isTransfer = type == 'TRANSFER';
    final color = isTransfer ? AppColors.info : (isIncome ? AppColors.income : AppColors.expense);
    final catColor = parseHexColor(tx['category_color'] as String?, color);
    final subtitleParts = [
      if (tx['category_name'] != null) tx['category_name'],
      if (tx['account_name'] != null) tx['account_name'],
      shortDate(toDate(tx['date'])),
    ];
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CircleAvatar(
        backgroundColor: catColor.withValues(alpha: 0.15),
        child: Icon(
          isTransfer ? Icons.swap_horiz : (isIncome ? Icons.south_west : Icons.north_east),
          color: catColor,
          size: 20,
        ),
      ),
      title: Text(tx['description']?.toString() ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitleParts.join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(isTransfer ? '' : (isIncome ? '+' : '−'), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        MoneyText(tx['amount'], color: color, style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
