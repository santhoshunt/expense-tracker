import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/accounts_screen.dart' show showCreditLimitDialog;
import '../screens/app_nav.dart';
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
  // Wallets alone don't: they are never part of net balance.
  final useAccounts = finance.hasNetAccounts;
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    // Up to six wrapping rows — scroll instead of clipping at the default
    // 9/16-height cap when fonts are large.
    isScrollControlled: true,
    // Keeps a tall sheet below the status bar / notch.
    useSafeArea: true,
    // With accounts, some rows open a page and carry a chevron.
    builder: (ctx) => BreakdownChevronSpace(
      enabled: useAccounts,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: FrostedPanel(
            radius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The handle sits on the floating panel (as on the month
                    // picker): the framework's would float over the dimmed
                    // backdrop above it.
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Balance breakdown',
                      // titleLarge: every other bottom sheet titles itself with
                      // this style — this one was the odd titleMedium out.
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    if (useAccounts) ...[
                      // Opens Accounts on its Banks filter.
                      BreakdownRow(
                        icon: Icons.account_balance_outlined,
                        color: AppColors.of(ctx).green,
                        label: 'Bank balances',
                        amount: '+${fmtMoney(finance.bankBalanceTotal)}',
                        onTap: () {
                          Navigator.pop(ctx);
                          AppNav.instance.openAccounts(
                            context,
                            type: AccountType.bank,
                          );
                        },
                      ),
                      // Opens Accounts on its Cash filter.
                      if (finance.cashBalanceCount > 0)
                        BreakdownRow(
                          icon: Icons.payments_outlined,
                          color: AppColors.of(ctx).green,
                          label: 'Cash in hand',
                          // A hand-kept Cash total can be below zero; it
                          // then keeps fmtMoney's own minus.
                          amount:
                              fmtMoney(finance.cashBalanceTotal).startsWith('−')
                              ? fmtMoney(finance.cashBalanceTotal)
                              : '+${fmtMoney(finance.cashBalanceTotal)}',
                          onTap: () {
                            Navigator.pop(ctx);
                            AppNav.instance.openAccounts(
                              context,
                              type: AccountType.cash,
                            );
                          },
                        ),
                      BreakdownRow(
                        icon: Icons.credit_card,
                        color: Theme.of(ctx).colorScheme.error,
                        label: 'Credit card outstanding',
                        amount: '−${fmtMoney(finance.cardOutstandingTotal)}',
                      ),
                      // Cards with no total credit limit contribute nothing above,
                      // so say so — otherwise the net figure reads as complete
                      // when it is quietly optimistic.
                      if (finance.cardsMissingLimit > 0)
                        // One card: its credit limit dialog. Several: Accounts
                        // on its Credit cards filter, where each has the button.
                        BreakdownRow(
                          icon: Icons.help_outline,
                          color: AppColors.of(ctx).orange,
                          label:
                              '${finance.cardsMissingLimit} card'
                              '${finance.cardsMissingLimit == 1 ? ' needs' : 's need'}'
                              ' a credit limit, not counted',
                          amount: '?',
                          onTap: () {
                            final missing = [
                              for (final a in finance.accounts)
                                // As cardsMissingLimit: an emptied card
                                // counts in no total, so it needs no limit.
                                if (!a.isClosed &&
                                    a.isCard &&
                                    !finance.isOrphanedAccount(a) &&
                                    finance.accountOutstanding(a) == null)
                                  a,
                            ];
                            Navigator.pop(ctx);
                            if (missing.length == 1) {
                              showCreditLimitDialog(context, missing.single);
                            } else {
                              AppNav.instance.openAccounts(
                                context,
                                type: AccountType.creditCard,
                              );
                            }
                          },
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
                        amount:
                            ctx.select<SettingsProvider, bool>(
                              (s) => s.hideIncome,
                            )
                            ? '+$kMaskedAmount'
                            : '+${fmtMoney(finance.totalIncome)}',
                      ),
                      BreakdownRow(
                        icon: Icons.arrow_upward,
                        color: Theme.of(ctx).colorScheme.error,
                        label: 'Expenses (all time)',
                        amount: '−${fmtMoney(finance.totalExpense)}',
                      ),
                      if (finance.totalSavingsTransfers > 0)
                        BreakdownRow(
                          icon: Icons.savings_outlined,
                          color: AppColors.of(ctx).orange,
                          label: 'Moved to savings',
                          amount: '−${fmtMoney(finance.totalSavingsTransfers)}',
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
                    // Either way, beside the total and never in it: wallet
                    // money only spends on its own platform.
                    if (finance.walletBalanceTotal > 0) ...[
                      const SizedBox(height: 8),
                      BreakdownRow(
                        icon: Icons.account_balance_wallet_outlined,
                        color: AppColors.of(ctx).orange,
                        label: 'In wallets (not in net balance)',
                        amount: fmtMoney(finance.walletBalanceTotal),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Set over a list of [BreakdownRow]s where some rows carry a chevron:
/// when [enabled], the others keep its width at their end.
class BreakdownChevronSpace extends InheritedWidget {
  final bool enabled;

  const BreakdownChevronSpace({
    super.key,
    required this.enabled,
    required super.child,
  });

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BreakdownChevronSpace>()
          ?.enabled ??
      false;

  @override
  bool updateShouldNotify(BreakdownChevronSpace old) => old.enabled != enabled;
}

class BreakdownRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String amount;
  final bool bold;

  /// Makes the row a button, with a chevron after the amount.
  final VoidCallback? onTap;

  const BreakdownRow({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.amount,
    this.bold = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      fontSize: bold ? 16 : 14,
    );
    final tap = onTap;
    // Among rows that open something, a plain row keeps a chevron-wide
    // space, so every amount ends at the same edge.
    if (tap == null && BreakdownChevronSpace.of(context)) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 18),
        child: _row(style),
      );
    }
    if (tap != null) {
      // One button node: the label and amount read as its name.
      return Semantics(
        container: true,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: tap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Expanded(child: _row(style)),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return _row(style);
  }

  Widget _row(TextStyle style) {
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
              // The icon carries the colour; the figure is plain text.
              child: Text(amount, style: style),
            ),
          ),
        ],
      ),
    );
  }
}
