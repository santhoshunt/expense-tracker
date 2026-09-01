import 'package:flutter/material.dart';

import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import 'glossy.dart';

/// Bottom sheet explaining how the headline balance is computed — shared by
/// the Dashboard balance card and the Accounts summary.
///
/// With accounts, it decomposes the bank-stated net worth; without, the
/// ledger fallback (income − expenses − savings transfers).
Future<void> showBalanceBreakdownSheet(
  BuildContext context,
  FinanceProvider finance,
) {
  final useAccounts = finance.accounts.isNotEmpty;
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    // Up to six wrapping rows — scroll instead of clipping at the default
    // 9/16-height cap when fonts are large.
    isScrollControlled: true,
    // Keeps a tall sheet below the status bar / notch.
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: FrostedPanel(
          radius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Balance breakdown',
                    // titleLarge: every other bottom sheet titles itself with
                    // this style — this one was the odd titleMedium out.
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  if (useAccounts) ...[
                    BreakdownRow(
                      icon: Icons.account_balance_outlined,
                      color: AppColors.of(ctx).green,
                      label: 'Bank balances',
                      amount: '+${fmtMoney(finance.bankBalanceTotal)}',
                    ),
                    BreakdownRow(
                      icon: Icons.credit_card,
                      color: Theme.of(ctx).colorScheme.error,
                      label: 'Credit card outstanding',
                      amount: '-${fmtMoney(finance.cardOutstandingTotal)}',
                    ),
                    // Cards with no total credit limit contribute nothing above,
                    // so say so — otherwise the net figure reads as complete
                    // when it is quietly optimistic.
                    if (finance.cardsMissingLimit > 0)
                      BreakdownRow(
                        icon: Icons.help_outline,
                        color: AppColors.of(ctx).orange,
                        label:
                            '${finance.cardsMissingLimit} card'
                            '${finance.cardsMissingLimit == 1 ? '' : 's'} '
                            'need a credit limit — not counted',
                        amount: '?',
                      ),
                    const Divider(height: 24),
                    BreakdownRow(
                      icon: Icons.account_balance_wallet,
                      color: Theme.of(ctx).colorScheme.primary,
                      label: 'Net balance (liquid)',
                      amount: fmtMoney(finance.netWorth),
                      bold: true,
                    ),
                    if (finance.savingsBalanceTotal > 0) ...[
                      const SizedBox(height: 8),
                      BreakdownRow(
                        icon: Icons.savings_outlined,
                        color: AppColors.of(ctx).orange,
                        label: 'In savings & assets (not liquid)',
                        amount: fmtMoney(finance.savingsBalanceTotal),
                      ),
                    ],
                  ] else ...[
                    BreakdownRow(
                      icon: Icons.arrow_downward,
                      color: AppColors.of(ctx).green,
                      label: 'Income (all time)',
                      amount: '+${fmtMoney(finance.totalIncome)}',
                    ),
                    BreakdownRow(
                      icon: Icons.arrow_upward,
                      color: Theme.of(ctx).colorScheme.error,
                      label: 'Expenses (all time)',
                      amount: '-${fmtMoney(finance.totalExpense)}',
                    ),
                    if (finance.totalSavingsTransfers > 0)
                      BreakdownRow(
                        icon: Icons.savings_outlined,
                        color: AppColors.of(ctx).orange,
                        label: 'Moved to savings',
                        amount: '-${fmtMoney(finance.totalSavingsTransfers)}',
                      ),
                    const Divider(height: 24),
                    BreakdownRow(
                      icon: Icons.account_balance_wallet,
                      color: Theme.of(ctx).colorScheme.primary,
                      label: 'Available balance',
                      amount: fmtMoney(finance.balance),
                      bold: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class BreakdownRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String amount;
  final bool bold;

  const BreakdownRow({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.amount,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      fontSize: bold ? 16 : 14,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          // Labels here are full sentences — wrap to two lines, then
          // ellipsize; the amount shrinks under its cap rather than
          // overflowing the sheet.
          Expanded(
            child: Text(
              label,
              style: style,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(amount, style: style.copyWith(color: color)),
            ),
          ),
        ],
      ),
    );
  }
}
