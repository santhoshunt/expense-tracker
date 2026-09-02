import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/backup_service.dart';
import '../services/merchant_stats.dart';
import '../services/recurring_detector.dart';
import '../services/reminder_schedule.dart';
import '../utils/app_theme.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import '../widgets/animated_fold.dart';
import '../widgets/balance_breakdown.dart';
import '../widgets/budget_detail_sheet.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/reminder_editor_dialog.dart';
import '../widgets/undo_snackbar.dart';
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

  /// Called when a Top-merchants row is tapped: [query] is the normalized
  /// merchant identity, pre-filled into the Transactions search.
  final void Function(String query, DateTime month)? onViewMerchant;

  const DashboardScreen({
    super.key,
    this.onViewTransactions,
    this.onViewCategory,
    this.onViewGroup,
    this.onViewBudget,
    this.onViewMerchant,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late DateTime _month;

  /// Year view: the stat cards, category breakdown and bar chart cover
  /// `_month.year`; the month-only sections (budgets, merchants, heatmap,
  /// transfers) step aside.
  bool _yearMode = false;

  /// Recurring detection scans the whole ledger — memoized on the provider's
  /// revision token so it reruns only when data actually changes.
  Object? _recurringRev;
  List<RecurringHit> _recurringHits = const [];

  List<RecurringHit> _recurring(FinanceProvider finance) {
    if (!identical(_recurringRev, finance.revision)) {
      _recurringRev = finance.revision;
      _recurringHits = detectRecurring(
        finance.transactions,
        now: DateTime.now(),
        alias: finance.merchantAlias,
      );
    }
    return _recurringHits;
  }

  /// Per-merchant totals scan every row's SMS body — memoized on
  /// (revision, month) like the recurring hits.
  Object? _merchantsRev;
  DateTime? _merchantsMonth;
  List<MerchantSpend> _merchants = const [];

  List<MerchantSpend> _topMerchants(FinanceProvider finance) {
    if (!identical(_merchantsRev, finance.revision) ||
        _merchantsMonth != _month) {
      _merchantsRev = finance.revision;
      _merchantsMonth = _month;
      _merchants = topMerchants(
        finance.transactions,
        month: _month,
        alias: finance.merchantAlias,
      );
    }
    return _merchants;
  }

  /// Long-press on a Top-merchants row: give the payee a readable name.
  /// Parsed identities can be a VPA fragment or an FD reference ("Fd No"),
  /// and the alias follows the identity into Upcoming and search too.
  Future<void> _renameMerchant(
    BuildContext context,
    FinanceProvider finance,
    MerchantSpend m,
  ) async {
    final identity = m.key.substring(m.key.indexOf('|') + 1);
    final existing = finance.merchantAlias(identity);
    final ctrl = TextEditingController(text: m.label);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => DisposeScope(
        disposables: [ctrl],
        child: AlertDialog(
          title: const Text('Rename merchant'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Display name',
              helperText: 'Detected as "$identity"',
              helperMaxLines: 2,
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            if (existing != null)
              TextButton(
                // Empty string = clear the alias (distinct from Cancel's null).
                onPressed: () => Navigator.pop(ctx, ''),
                child: const Text('Reset'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await finance.setMerchantAlias(identity, result);
  }

  /// The budget that caps exactly this one category (include mode, single
  /// id), if the user made one — the category row's long-press edits it
  /// instead of creating a duplicate.
  static SpendBudget? _singleCategoryBudget(
    FinanceProvider finance,
    String categoryId,
  ) {
    for (final b in finance.budgets) {
      if (b.mode == BudgetMode.include &&
          b.categoryIds.length == 1 &&
          b.categoryIds.contains(categoryId)) {
        return b;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  /// Steps one month, or one year in Year view (the month is kept so
  /// switching back lands on the same month of the new year).
  void _shiftMonth(int delta) => setState(
    () => _month = _yearMode
        ? DateTime(_month.year + delta, _month.month)
        : DateTime(_month.year, _month.month + delta),
  );

  /// Jump straight to any month (or, in Year view, year) that has data,
  /// plus the current one.
  Future<void> _pickMonth(BuildContext context, FinanceProvider finance) async {
    final now = DateTime.now();
    final current = DateTime(now.year, now.month);
    final months = finance.monthsWithData;
    final List<DateTime> options;
    if (_yearMode) {
      final years = <int>{now.year, for (final m in months) m.year}.toList()
        ..sort((a, b) => b.compareTo(a));
      options = [for (final y in years) DateTime(y, _month.month)];
    } else {
      options = [if (!months.contains(current)) current, ...months];
    }
    bool isCurrent(DateTime m) =>
        _yearMode ? m.year == _month.year : m == _month;
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
                color: isCurrent(m)
                    ? Theme.of(ctx).colorScheme.primary
                    : Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
              title: Text(_yearMode ? '${m.year}' : fmtMonth(m)),
              selected: isCurrent(m),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _month = picked);
  }

  Future<void> _exportYearPdf(
    BuildContext context,
    FinanceProvider finance,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final year = _month.year;
    try {
      final path = await BackupService.exportPdf(finance, year: year);
      if (path == null) return;
      messenger.showSnackBar(SnackBar(content: Text('Saved report $year')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
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
    final year = _month.year;
    // In Year view the "month" figures below are the year's: same widgets,
    // wider window.
    final byCategory = _yearMode
        ? finance.expenseByCategoryInYear(year)
        : finance.expenseByCategory(_month);
    final monthExpense = _yearMode
        ? finance.expenseInYear(year)
        : finance.expenseInMonth(_month);
    final groupSpend = finance.groupSpendInMonth(_month);
    final groupTotal = groupSpend.fold(0.0, (sum, e) => sum + e.$2);
    final transfersBy = finance.transfersByCategoryInMonth(_month);
    final topMerchantsList = _topMerchants(finance);
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
        // Card bills coming due + detected recurring payments. Not
        // month-scoped, so it sits above the month selector.
        _UpcomingCard(finance: finance, hits: _recurring(finance)),
        // Month selector governs the stat cards and category breakdown.
        Row(
          children: [
            IconButton(
              tooltip: _yearMode ? 'Previous year' : 'Previous month',
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
                          _yearMode ? '$year' : fmtMonth(_month),
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
              tooltip: _yearMode ? 'Next year' : 'Next month',
              onPressed:
                  (_yearMode
                      ? year < latestMonth.year
                      : _month.isBefore(latestMonth))
                  ? () => _shiftMonth(1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
            // Scope switch as a quiet text button: a full-width segmented
            // control here read as a primary action and drew the eye away
            // from the figures. Month is the default; nothing is persisted.
            if (_yearMode)
              IconButton(
                tooltip: 'Export year report (PDF)',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.picture_as_pdf_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: () => _exportYearPdf(context, finance),
              ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: scheme.onSurfaceVariant,
                textStyle: Theme.of(context).textTheme.labelMedium,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => setState(() => _yearMode = !_yearMode),
              child: Text(_yearMode ? 'Month' : 'Year'),
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
              // Year-view taps stay month-scoped deep links (the Transactions
              // filter has no year), so they are disabled there.
              _StatCard(
                label: 'Income',
                value: _yearMode
                    ? finance.incomeInYear(year)
                    : finance.incomeInMonth(_month),
                icon: Icons.arrow_downward,
                color: colors.green,
                onTap: widget.onViewTransactions == null || _yearMode
                    ? null
                    : () => widget.onViewTransactions!(TxType.income, _month),
              ),
              const SizedBox(width: 12),
              _StatCard(
                label: 'Spent',
                value: monthExpense,
                icon: Icons.arrow_upward,
                color: scheme.error,
                onTap: widget.onViewTransactions == null || _yearMode
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
                value: _yearMode
                    ? finance.savingsOutflowInYear(year)
                    : finance.savingsOutflowInMonth(_month),
                icon: Icons.savings_outlined,
                color: colors.orange,
                onTap: widget.onViewCategory == null || _yearMode
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
            if (budget <= 0 || _yearMode) return const SizedBox.shrink();
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
        // cards would dominate the page with several budgets. Budgets are
        // monthly, so the Year view skips them.
        if (finance.budgets.isNotEmpty && !_yearMode) ...[
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
              onCategoryTap: widget.onViewCategory == null || _yearMode
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
                      budgetLimit: _yearMode
                          ? null
                          : _singleCategoryBudget(finance, entry.key.id)?.limit,
                      onTap: widget.onViewCategory == null || _yearMode
                          ? null
                          : () => widget.onViewCategory!(entry.key.id, _month),
                      // Shortcut to a per-category cap: opens the shared
                      // budget dialog pre-filled (or the existing one).
                      onLongPress: () => showBudgetDialog(
                        context,
                        existing: _singleCategoryBudget(finance, entry.key.id),
                        presetName: entry.key.label,
                        presetMode: BudgetMode.include,
                        presetCategoryIds: {entry.key.id},
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        // Where the money actually went: per-payee totals for the month,
        // re-derived from SMS bodies / manual notes. Display-only — the
        // transactions filter can't express a free-text payee (yet).
        // Shown whenever the month has spending: an empty month-start used to
        // make the whole section vanish, which read as a bug rather than
        // "nothing identifiable yet".
        if (!_yearMode &&
            (topMerchantsList.isNotEmpty || monthExpense > 0)) ...[
          const SizedBox(height: 24),
          Text('Top merchants', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (topMerchantsList.isEmpty)
                    Text(
                      'No identifiable merchants in ${fmtMonth(_month)} yet. '
                      'Payments to phone numbers, VPAs without a name and '
                      'bank references are left out; add a note to a '
                      'transaction to name it.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  for (final m in topMerchantsList)
                    InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      onTap: widget.onViewMerchant == null
                          ? null
                          // The search matches notes/bodies, so the query is
                          // the normalized identity, not the cased label.
                          : () => widget.onViewMerchant!(
                              m.key.substring(m.key.indexOf('|') + 1),
                              _month,
                            ),
                      onLongPress: () => _renameMerchant(context, finance, m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(
                              Icons.storefront_outlined,
                              size: 20,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    m.count == 1
                                        ? '1 payment'
                                        : '${m.count} payments',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 120),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  fmtMoney(m.total),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        // Spending per parent group (Needs/Wants/…). Grouped transfer
        // outflows are included in their group's sum; "Other" collects
        // ungrouped categories.
        if (finance.groups.isNotEmpty && groupTotal > 0 && !_yearMode) ...[
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
        if (monthExpense > 0 && !_yearMode) ...[
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
        if (transfersBy.isNotEmpty && !_yearMode) ...[
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
        Text(
          _yearMode ? 'Months of $year' : 'Last 6 months',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                MonthlyBarChart(
                  months: _yearMode
                      ? [for (var m = 1; m <= 12; m++) DateTime(year, m)]
                      : null,
                ),
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

/// "Upcoming": card bills coming due plus detected monthly payments,
/// soonest first. Renders nothing (zero height) when there is nothing to
/// show, so the sections around it keep their spacing.
class _UpcomingCard extends StatelessWidget {
  final FinanceProvider finance;
  final List<RecurringHit> hits;
  const _UpcomingCard({required this.finance, required this.hits});

  /// One duration for the fold, the chevron flip and the count fade, so the
  /// three movements read as a single gesture.
  static const _foldDuration = Duration(milliseconds: 250);

  static String _inDays(int days) => days == 0
      ? 'today'
      : days == 1
      ? 'tomorrow'
      : 'in $days days';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final entries =
        <
          ({
            DateTime due,
            IconData icon,
            Color color,
            String label,
            String sub,
            double? amount,
            bool urgent,
            String? hideKey,
            Reminder? reminder,
          })
        >[];

    for (final a in finance.openAccounts) {
      if (!a.isCard || a.dueDay == null) continue;
      final out = finance.accountOutstanding(a);
      if (out == null || out <= 0) continue;
      final due = nextMonthlyOccurrence(a.dueDay!, now);
      final days = due.difference(today).inDays;
      entries.add((
        due: due,
        icon: Icons.credit_card,
        color: scheme.error,
        label: '${a.name} bill',
        sub: 'Due ${fmtDateCompact(due)} · ${_inDays(days)}',
        amount: out,
        urgent: days <= 3,
        hideKey: null,
        reminder: null,
      ));
    }

    for (final h in hits) {
      if (settings.hiddenUpcoming.contains(h.key)) continue;
      final c = categoryById(h.categoryId, fallbackType: h.type);
      final days = h.daysUntil(now);
      entries.add((
        due: h.nextDue,
        icon: c.icon,
        color: c.color,
        label: h.label,
        sub: days < 0
            ? 'Overdue · expected ${fmtDateCompact(h.nextDue)}'
            : 'Expected ${fmtDateCompact(h.nextDue)} · ${_inDays(days)}',
        amount: h.expectedAmount,
        urgent: days < 0,
        hideKey: h.key,
        reminder: null,
      ));
    }
    // Manual reminders: shown from a week before the due day (the schedule
    // already skips a month marked paid).
    for (final r in finance.reminders) {
      final due = reminderNextDue(r, now);
      final days = reminderDaysUntil(r, now);
      if (days > 7) continue;
      final c = categoryById(r.categoryId, fallbackType: TxType.expense);
      entries.add((
        due: due,
        icon: c.icon,
        color: c.color,
        label: r.name,
        sub: days < 0
            ? 'Overdue · was due ${fmtDateCompact(due)}'
            : 'Due ${fmtDateCompact(due)} · ${_inDays(days)}',
        amount: r.expectedAmount,
        urgent: days <= 0,
        hideKey: null,
        reminder: r,
      ));
    }
    if (entries.isEmpty && finance.reminders.isEmpty) {
      return const SizedBox.shrink();
    }
    entries.sort((a, b) => a.due.compareTo(b.due));
    final collapsed = settings.isSectionCollapsed('upcoming');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tappable header: the card can dominate the top of the dashboard,
        // so it folds to this row (persisted per device).
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: () =>
              context.read<SettingsProvider>().toggleSection('upcoming'),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(
                  'Upcoming',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                // Static in both states. Fading the count in step with the
                // fold rendered its glyphs in two halves on Impeller, so the
                // header no longer animates any text.
                Text(
                  '${entries.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Add reminder',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.add_alert_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: () => showReminderEditor(context),
                ),
                AnimatedRotation(
                  turns: collapsed ? 0.5 : 0,
                  duration: _foldDuration,
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.expand_less,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Pure height reveal, no fade: cross-fading made the amounts appear
        // half-transparent while the card expanded.
        AnimatedFold(
          collapsed: collapsed,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (entries.isEmpty)
                        Text(
                          'Nothing due in the next week.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      for (final e in entries.take(6))
                        InkWell(
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                          // Manual reminders: tap for mark paid / edit /
                          // delete.
                          onTap: e.reminder == null
                              ? null
                              : () => _showReminderActions(
                                  context,
                                  e.reminder!,
                                  e.due,
                                ),
                          // Detected patterns can be wrong — long-press hides one.
                          // Card bills aren't hideable; clear the card's due day
                          // instead.
                          onLongPress: e.hideKey == null
                              ? null
                              : () =>
                                    _confirmHide(context, e.label, e.hideKey!),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Icon(e.icon, size: 20, color: e.color),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        e.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        e.sub,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: e.urgent
                                                  ? scheme.error
                                                  : null,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 120,
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      e.amount == null
                                          ? ''
                                          : fmtMoney(e.amount!),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// Three plain actions for a manual reminder row. (showPickerSheet was
  /// rejected here: its always-on search field is wrong for a 3-item menu.)
  void _showReminderActions(BuildContext context, Reminder r, DateTime due) {
    final finance = context.read<FinanceProvider>();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(r.name, style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text('Due ${fmtDate(due)}'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Mark paid this month'),
              onTap: () {
                Navigator.pop(ctx);
                final before = r;
                finance.markReminderPaid(r.id, due);
                showUndoSnackBar(
                  context,
                  '${r.name} marked paid',
                  () => finance.updateReminder(before),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                showReminderEditor(context, existing: r);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                final before = r;
                finance.deleteReminder(r.id);
                showUndoSnackBar(
                  context,
                  'Deleted reminder "${r.name}"',
                  () => finance.restoreReminder(before),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmHide(BuildContext context, String label, String key) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hide "$label"?'),
        content: const Text(
          'This detected payment will no longer appear in Upcoming or fire '
          'reminders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ctx.read<SettingsProvider>().hideUpcoming(key);
              Navigator.pop(ctx);
            },
            child: const Text('Hide'),
          ),
        ],
      ),
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
  final VoidCallback? onLongPress;

  /// Cap of the single-category budget on this row, if any — shown as an
  /// "of ₹X" suffix rather than a second bar in an already dense list.
  final double? budgetLimit;

  const _CategoryRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.amount,
    required this.fraction,
    this.onTap,
    this.onLongPress,
    this.budgetLimit,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
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
                            budgetLimit == null
                                ? fmtMoney(amount)
                                : '${fmtMoney(amount)} of '
                                      '${fmtMoneyCompact(budgetLimit!)}',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color:
                                  budgetLimit != null && amount > budgetLimit!
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
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
