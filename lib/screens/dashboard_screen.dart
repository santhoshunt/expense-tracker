import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../widgets/balance_breakdown.dart';
import '../widgets/budget_detail_sheet.dart';
import '../widgets/spending_heatmap.dart';
import '../widgets/glossy.dart';
import '../widgets/motion.dart';
import '../widgets/category_donut_chart.dart';
import '../widgets/monthly_bar_chart.dart';
import '../widgets/transaction_tile.dart';

class DashboardScreen extends StatefulWidget {
  /// Called when a stat card is tapped, to open the Transactions tab
  /// pre-filtered to that type — scoped to the month the card was showing.
  final void Function(TxType type, DateTime month)? onViewTransactions;

  /// Called when a category / group spending row or a budget row is tapped,
  /// to open the Transactions tab pre-filtered to it — scoped to the month
  /// the dashboard was showing.
  final void Function(String categoryId, DateTime month)? onViewCategory;

  /// A null groupId means the "Other" (ungrouped) bucket.
  final void Function(String? groupId, DateTime month)? onViewGroup;
  final void Function(String budgetId, DateTime month)? onViewBudget;

  const DashboardScreen({
    super.key,
    this.onViewTransactions,
    this.onViewCategory,
    this.onViewGroup,
    this.onViewBudget,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  void _shiftMonth(int delta) =>
      setState(() => _month = DateTime(_month.year, _month.month + delta));

  /// Jump straight to any month that has data (plus the current month).
  Future<void> _pickMonth(BuildContext context, FinanceProvider finance) async {
    final now = DateTime.now();
    final current = DateTime(now.year, now.month);
    final months = finance.monthsWithData;
    final options = [if (!months.contains(current)) current, ...months];
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      builder: (ctx) => ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          for (final m in options)
            ListTile(
              leading: Icon(
                Icons.calendar_month,
                color: m == _month
                    ? Theme.of(ctx).colorScheme.primary
                    : Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
              title: Text(fmtMonth(m)),
              selected: m == _month,
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _month = picked);
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    // The next-month arrow steps as far as data exists: rows re-dated one
    // day ahead put real entries in next month, which the picker sheet
    // already reaches — capping the arrow at the current month made the
    // two disagree.
    final now = DateTime.now();
    var latestMonth = DateTime(now.year, now.month);
    for (final m in finance.monthsWithData) {
      if (m.isAfter(latestMonth)) latestMonth = m;
    }
    final recent = finance.transactions.take(5).toList();
    final byCategory = finance.expenseByCategory(_month);
    final monthExpense = finance.expenseInMonth(_month);
    final groupSpend = finance.groupSpendInMonth(_month);
    final groupTotal = groupSpend.fold(0.0, (sum, e) => sum + e.$2);
    final transfersBy = finance.transfersByCategoryInMonth(_month);
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _BalanceCard(finance: finance),
        const SizedBox(height: 16),
        // First-run: the landing tab used to greet a new user with ₹0.00
        // everywhere and no hint of what to do next.
        if (!finance.hasTransactions) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Get started',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No transactions yet. Import your bank SMS with the '
                    'message icon in the top bar, or add one by hand with '
                    'the + button below.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        // Month selector governs the stat cards and category breakdown.
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: () => _shiftMonth(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            // Tappable: browsing back a year used to take 12 arrow taps.
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _pickMonth(context, finance),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          fmtMonth(_month),
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: _month.isBefore(latestMonth)
                  ? () => _shiftMonth(1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Horizontally scrollable so each card is wide enough to show its
        // amount on one line, however large the number. The height follows
        // the system font scale — fixed 88dp clips at "Large" text size.
        SizedBox(
          height: MediaQuery.textScalerOf(context).scale(88),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            children: [
              _StatCard(
                label: 'Income',
                value: finance.incomeInMonth(_month),
                icon: Icons.arrow_downward,
                color: colors.green,
                onTap: widget.onViewTransactions == null
                    ? null
                    : () => widget.onViewTransactions!(TxType.income, _month),
              ),
              const SizedBox(width: 12),
              _StatCard(
                label: 'Spent',
                value: monthExpense,
                icon: Icons.arrow_upward,
                color: scheme.error,
                onTap: widget.onViewTransactions == null
                    ? null
                    : () => widget.onViewTransactions!(TxType.expense, _month),
              ),
              const SizedBox(width: 12),
              // Savings outflow — the DISPLAY figure, which keeps reporting
              // even when the user un-transferred the savings category (the
              // money then also sits inside Spent; the balance math uses the
              // gated figure separately).
              _StatCard(
                label: 'Saved',
                value: finance.savingsOutflowInMonth(_month),
                icon: Icons.savings_outlined,
                color: colors.orange,
                onTap: widget.onViewCategory == null
                    ? null
                    : () => widget.onViewCategory!(
                        kSavingsTransferCategoryId,
                        _month,
                      ),
              ),
            ],
          ),
        ),
        // Monthly budget progress — only when a cap is set. Uses the selected
        // month's spend so browsing past months shows their usage too.
        Builder(
          builder: (context) {
            final budget = context.select<SettingsProvider, double>(
              (s) => s.monthlyBudget,
            );
            if (budget <= 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _BudgetCard(
                spent: finance.budgetSpentInMonth(_month),
                cap: budget,
              ),
            );
          },
        ),
        // Custom spend limits, one compact progress row each — full ring
        // cards would dominate the page with several budgets.
        if (finance.budgets.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Budgets', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              // all(16): the dashboard's section cards had six different
              // inner paddings — edges never lined up while scrolling.
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final b in finance.budgets)
                    _SpendBudgetRow(
                      name: b.name,
                      spent: finance.budgetSpentFor(b, _month),
                      limit: b.limit,
                      // Detail sheet (ring + pie + trend); the transactions
                      // deep-link lives on a button inside it.
                      onTap: () => showBudgetDetailSheet(
                        context,
                        b,
                        _month,
                        onViewTransactions: widget.onViewBudget,
                        onViewCategory: widget.onViewCategory,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CategoryDonutChart(
              data: byCategory,
              onCategoryTap: widget.onViewCategory == null
                  ? null
                  : (id) => widget.onViewCategory!(id, _month),
            ),
          ),
        ),
        if (byCategory.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final entry in byCategory)
                    _CategoryRow(
                      icon: entry.key.icon,
                      color: entry.key.color,
                      label: entry.key.label,
                      amount: entry.value,
                      fraction: monthExpense == 0
                          ? 0
                          : entry.value / monthExpense,
                      onTap: widget.onViewCategory == null
                          ? null
                          : () => widget.onViewCategory!(entry.key.id, _month),
                    ),
                ],
              ),
            ),
          ),
        ],
        // Spending per parent group (Needs/Wants/…). Grouped transfer
        // outflows are included in their group's sum; "Other" collects
        // ungrouped categories.
        if (finance.groups.isNotEmpty && groupTotal > 0) ...[
          const SizedBox(height: 24),
          Text('By group', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final (group, amount) in groupSpend)
                    _CategoryRow(
                      icon: group == null
                          ? Icons.category
                          : Icons.workspaces_outlined,
                      color: group?.color ?? scheme.onSurfaceVariant,
                      label: group?.label ?? 'Other',
                      amount: amount,
                      fraction: groupTotal == 0 ? 0 : amount / groupTotal,
                      // null group = the "Other" (ungrouped) bucket — the
                      // callback owner maps it to the ungrouped filter key.
                      onTap: widget.onViewGroup == null
                          ? null
                          : () => widget.onViewGroup!(group?.id, _month),
                    ),
                ],
              ),
            ),
          ),
        ],
        // Spending hotspots: which DATES were hot this month, and which
        // weekdays are usually hot across history.
        if (monthExpense > 0) ...[
          const SizedBox(height: 24),
          Text(
            'Spending heatmap',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SpendingHeatmap(month: _month),
            ),
          ),
        ],
        // Transfers: own-account moves for the month. Not income or expense —
        // shown separately so the flows are still visible.
        if (transfersBy.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Transfers', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              // all(16): the dashboard's section cards had six different
              // inner paddings — edges never lined up while scrolling.
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  BreakdownRow(
                    icon: Icons.arrow_downward,
                    color: colors.green,
                    label: 'In',
                    amount: '+${fmtMoney(finance.transferInInMonth(_month))}',
                  ),
                  BreakdownRow(
                    icon: Icons.arrow_upward,
                    color: scheme.error,
                    label: 'Out',
                    amount: '−${fmtMoney(finance.transferOutInMonth(_month))}',
                  ),
                  const Divider(height: 20),
                  for (final entry in transfersBy)
                    BreakdownRow(
                      icon: entry.key.icon,
                      color: entry.key.color,
                      label: entry.key.label,
                      amount:
                          '${entry.key.type == TxType.income ? '+' : '−'}'
                          '${fmtMoney(entry.value)}',
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text('Last 6 months', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const MonthlyBarChart(),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _LegendDot(color: colors.green, label: 'Income'),
                    const SizedBox(width: 16),
                    _LegendDot(color: scheme.error, label: 'Expense'),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'Recent transactions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [for (final tx in recent) TransactionTile(tx: tx)],
            ),
          ),
        ],
        const SizedBox(height: 120),
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final FinanceProvider finance;
  const _BalanceCard({required this.finance});

  /// With accounts, the headline is the bank-stated net worth — ledger
  /// arithmetic (income − expense) is unreliable when the SMS history has no
  /// opening balances. Without accounts, fall back to the ledger figure.
  bool get _useAccounts => finance.accounts.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Neutral frosted panel with the amount as the neon accent — same
    // material as the segmented filter bar. InkWell, not GestureDetector:
    // the card is a button and should ripple and read as one to a11y.
    return FrostedPanel(
      radius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => showBalanceBreakdownSheet(context, finance),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    _useAccounts ? 'Net balance' : 'Available balance',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 6),
              // Morphs in place when the figure changes (edit, import, sync).
              MorphingAmount(
                value: _useAccounts ? finance.netWorth : finance.balance,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (finance.totalSavingsTransfers > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.savings,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${fmtMoney(finance.totalSavingsTransfers)} moved to '
                        'savings',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Monthly-cap progress: spent vs cap, colour shifting green→amber→red as
/// usage climbs past 80% and 100%.
class _BudgetCard extends StatelessWidget {
  final double spent;
  final double cap;
  const _BudgetCard({required this.spent, required this.cap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = cap <= 0 ? 0.0 : (spent / cap);
    final over = spent > cap;
    final colors = AppColors.of(context);
    final color = pct >= 1.0
        ? scheme.error
        : pct >= 0.8
        ? colors.orange
        : colors.green;
    final remaining = cap - spent;

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            // Ring sweeps to the usage fraction while the centre % counts up
            // in sync. Passing the true fraction (may exceed 1) lets the
            // label keep climbing past 100% while the arc stays full.
            RingProgress(
              value: pct,
              color: color,
              // 15% was invisible on the light surface — an empty ring read
              // as "no track at all" at low spend.
              trackColor: color.withValues(alpha: 0.3),
              labelStyle: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.account_balance_wallet_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Monthly budget',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Compact figures keep this readable even at 1000%+ overshoot.
                  Text(
                    '${fmtMoneyCompact(spent)} spent of ${fmtMoneyCompact(cap)}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    over
                        ? '${fmtMoneyCompact(-remaining)} over'
                        : '${fmtMoneyCompact(remaining)} left',
                    style: TextStyle(color: color, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final double value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 132),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 8),
              // Plain text — no increment animation. Animating on month change
              // made the figures visibly "roll", which read as glitchy.
              Text(
                fmtMoney(value),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One compact progress row per custom budget: name, spent/limit, and a bar
/// using the same green/orange/error thresholds as the monthly budget card.
class _SpendBudgetRow extends StatelessWidget {
  final String name;
  final double spent;
  final double limit;

  /// Opens Transactions filtered to this budget (wired at the call site so
  /// the budget id needn't be threaded through).
  final VoidCallback? onTap;

  const _SpendBudgetRow({
    required this.name,
    required this.spent,
    required this.limit,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pct = limit == 0 ? 0.0 : spent / limit;
    final over = spent > limit;
    final color = pct >= 1.0
        ? scheme.error
        : pct >= 0.8
        ? colors.orange
        : colors.green;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                // Width-capped + scale-down: prevents overflow at large font
                // scale without the trailing gap a loose Flexible leaves
                // (which drifted the figure off the right edge).
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${fmtMoneyCompact(spent)} / ${fmtMoneyCompact(limit)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedProgress(
              value: pct,
              minHeight: 6,
              color: color,
              // Visible track: 12% vanished on light surfaces, so a bar at 5%
              // looked like an empty region.
              backgroundColor: color.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 2),
            Text(
              over
                  ? '${fmtMoneyCompact(spent - limit)} over'
                  : '${fmtMoneyCompact(limit - spent)} left',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final double amount;
  final double fraction;

  /// Opens Transactions filtered to this category/group (wired at the call
  /// site — the two sections using this row filter differently).
  final VoidCallback? onTap;

  const _CategoryRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.amount,
    required this.fraction,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Custom category names can be arbitrarily long.
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Share of the section total (month expense for the
                      // category list, group total for By group) — the bar
                      // shows it visually, this makes it readable.
                      Text(
                        '${(fraction * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Width-capped + scale-down, not Flexible: a loose
                      // flex child leaves a trailing gap and the amount
                      // drifts off the right edge (transaction-tile pattern).
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            fmtMoney(amount),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  AnimatedProgress(
                    value: fraction,
                    minHeight: 6,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
