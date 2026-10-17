import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../models/transaction.dart' show TxCategory, TxType;
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import 'budget_dialog.dart';
import 'category_donut_chart.dart';
import 'info_tip.dart';
import 'motion.dart';

/// How many months the sheet's bar chart shows.
const int kBudgetChartMonths = 6;

/// Categories the legend names one by one; the rest share one entry.
const _kLegendShown = 5;

/// The legend entry that sums every category past the [_kLegendShown]
/// largest. No single category filter matches it, so a tap opens the
/// budget's transactions. Not "Other": the built-in Other category can be
/// one of the five, and two "Other" rows would read as one.
const _kOtherId = '_budget_other';

const _kOther = TxCategory(
  id: _kOtherId,
  label: 'More categories',
  icon: Icons.more_horiz,
  color: Colors.blueGrey,
  type: TxType.expense,
);

/// [data] (largest first) cut to its 5 largest entries plus one 'Other'
/// entry summing the rest, so the legend never grows past 6 rows.
List<MapEntry<TxCategory, double>> _capped(
  List<MapEntry<TxCategory, double>> data,
) {
  if (data.length <= _kLegendShown) return data;
  final rest = data.skip(_kLegendShown).fold(0.0, (s, e) => s + e.value);
  return [...data.take(_kLegendShown), MapEntry(_kOther, rest)];
}

/// The chart window's last month when the sheet opens on [shown]: [latest]
/// when [shown] is one of the [kBudgetChartMonths] months ending there,
/// else [shown] itself.
@visibleForTesting
DateTime initialBudgetWindowEnd(DateTime shown, DateTime latest) {
  final first = DateTime(latest.year, latest.month - (kBudgetChartMonths - 1));
  return !shown.isBefore(first) && !shown.isAfter(latest) ? latest : shown;
}

/// The chart window's last month after the sheet steps to [shown]. The
/// window holds still while [shown] stays inside it. Stepping before its
/// first month pages it back [kBudgetChartMonths] months; stepping past its
/// last month pages it forward as far, but never past [latest].
@visibleForTesting
DateTime pageBudgetWindow({
  required DateTime windowEnd,
  required DateTime shown,
  required DateTime latest,
}) {
  var end = DateTime(windowEnd.year, windowEnd.month);
  while (shown.isBefore(
    DateTime(end.year, end.month - (kBudgetChartMonths - 1)),
  )) {
    end = DateTime(end.year, end.month - kBudgetChartMonths);
  }
  while (shown.isAfter(end)) {
    final paged = DateTime(end.year, end.month + kBudgetChartMonths);
    final capped = paged.isAfter(latest) ? latest : paged;
    // [shown] lies past [latest]: the window ends on it instead.
    if (!capped.isAfter(end)) return shown;
    end = capped;
  }
  return end;
}

/// Visual detail for one custom budget, starting at [month]: progress ring,
/// category pie, 6-month trend, and the jump into the budget-filtered
/// transaction list. Opened by tapping a budget row on the dashboard.
/// Chevrons in the sheet step through months without leaving it; the
/// arrows round the name, or a sideways swipe, step through the budgets.
Future<void> showBudgetDetailSheet(
  BuildContext context,
  SpendBudget initial,
  DateTime month, {
  void Function(String budgetId, DateTime month)? onViewTransactions,
  void Function(String categoryId, DateTime month)? onViewCategory,
}) {
  // The shown month and budget are sheet-local state: switching here must
  // not move the dashboard behind the sheet. Outside the builder: the
  // sheet rebuilds it on a drag, which would put back the opening budget,
  // month and window.
  var shown = DateTime(month.year, month.month);
  var shownId = initial.id;
  // The last stored copy of the shown budget, kept if it is deleted.
  var lastSeen = initial;
  // The chart's last month, set on the first build (it needs [latest]).
  DateTime? windowEnd;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final finance = ctx.watch<FinanceProvider>();
          final scheme = Theme.of(ctx).colorScheme;
          // The stored budget, so an edit from the pencil shows here at
          // once; its last copy if it was deleted meanwhile.
          final budgets = finance.budgets;
          for (final b in budgets) {
            if (b.id == shownId) lastSeen = b;
          }
          final budget = lastSeen;
          // -1 when the shown budget was deleted: the arrows and the count
          // hide until the sheet closes.
          final index = budgets.indexWhere((b) => b.id == shownId);
          final switchable = index != -1 && budgets.length > 1;
          void stepBudget(int delta) {
            final next = index + delta;
            if (index == -1 || next < 0 || next >= budgets.length) return;
            // The month and the chart window stay put.
            setSheetState(() => shownId = budgets[next].id);
          }

          // Same bound as the dashboard's next-month arrow: the current
          // month, or a later one when rows dated ahead put data there.
          final now = DateTime.now();
          final current = DateTime(now.year, now.month);
          var latest = current;
          for (final m in finance.monthsWithData) {
            if (m.isAfter(latest)) latest = m;
          }
          final end = windowEnd ??= initialBudgetWindowEnd(shown, latest);
          // The ledger's first month: nothing before it is on record, so the
          // chevron stops there and earlier bars stay empty.
          final first = finance.firstTransactionDate;
          final firstMonth = first == null
              ? null
              : DateTime(first.year, first.month);
          void showMonth(DateTime m) => setSheetState(() {
            shown = m;
            windowEnd = pageBudgetWindow(
              windowEnd: end,
              shown: m,
              latest: latest,
            );
          });

          // "left this month" only while it is this month.
          final when = shown == current
              ? 'this month'
              : 'in ${DateFormat('MMM').format(shown)}';
          final spent = finance.budgetSpentFor(budget, shown);
          final limit = budget.limit;
          final pct = limit == 0 ? 0.0 : spent / limit;
          final over = spent > limit;
          final color = budgetColor(ctx, pct);
          final breakdown = _capped(finance.budgetBreakdownFor(budget, shown));
          // The fixed window: it moves only when a step pages it.
          final months = List.generate(
            kBudgetChartMonths,
            (i) => DateTime(end.year, end.month - (kBudgetChartMonths - 1 - i)),
          );
          final trend = [
            for (final m in months) finance.budgetSpentFor(budget, m),
          ];
          String emptyText(DateTime m) =>
              'Nothing counted toward this budget in ${fmtMonth(m)}.';

          // Room for the window's busiest month, so stepping months inside
          // the window never changes the sheet's height. An empty month's
          // ring and text are reserved too, since its text can wrap past
          // a one-category legend.
          final windowData = [
            for (final m in months)
              (month: m, data: _capped(finance.budgetBreakdownFor(budget, m))),
          ];
          final busiest = windowData.reduce(
            (a, b) => b.data.length > a.data.length ? b : a,
          );
          final emptyMonths = [
            for (final w in windowData)
              if (w.data.isEmpty) w.month,
          ];
          final reserves = [
            if (busiest.data.isNotEmpty) busiest,
            if (emptyMonths.isNotEmpty)
              (
                month: emptyMonths.reduce(
                  (a, b) => fmtMonth(b).length > fmtMonth(a).length ? b : a,
                ),
                data: const <MapEntry<TxCategory, double>>[],
              ),
          ];

          final onCategoryTap =
              onViewCategory == null && onViewTransactions == null
              ? null
              : (String id) {
                  if (id == _kOtherId) {
                    if (onViewTransactions == null) return;
                    Navigator.pop(ctx);
                    onViewTransactions(budget.id, shown);
                    return;
                  }
                  if (onViewCategory == null) return;
                  Navigator.pop(ctx);
                  onViewCategory(id, shown);
                };

          return SafeArea(
            // A sideways fling steps through the budgets, as the arrows do.
            // Nothing else in the sheet takes a horizontal drag.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: switchable
                  ? (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v < -300) stepBudget(1);
                      if (v > 300) stepBudget(-1);
                    }
                  : null,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  key: const ValueKey('budget-sheet-content'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        if (switchable)
                          IconButton(
                            tooltip: 'Previous budget',
                            icon: const Icon(Icons.chevron_left),
                            onPressed: index > 0 ? () => stepBudget(-1) : null,
                          ),
                        Expanded(
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Grey on grey: the icon carries no
                                  // colour of its own here.
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor:
                                        scheme.surfaceContainerHigh,
                                    foregroundColor: scheme.onSurfaceVariant,
                                    child: Icon(budgetIcon(budget), size: 18),
                                  ),
                                  const SizedBox(width: 8),
                                  // Two lines rather than an ellipsis: between
                                  // the budget arrows a 320dp phone cut even
                                  // "Personal" short. The pencil sits on the
                                  // month row for the same reason.
                                  Flexible(
                                    child: Text(
                                      budget.name,
                                      style: Theme.of(ctx).textTheme.titleLarge,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                              if (switchable)
                                Text(
                                  'Budget ${index + 1} of ${budgets.length}',
                                  style: Theme.of(ctx).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                            ],
                          ),
                        ),
                        if (switchable)
                          IconButton(
                            tooltip: 'Next budget',
                            icon: const Icon(Icons.chevron_right),
                            onPressed: index < budgets.length - 1
                                ? () => stepBudget(1)
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous month',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.chevron_left, size: 20),
                          onPressed:
                              firstMonth != null && !shown.isAfter(firstMonth)
                              ? null
                              : () => showMonth(
                                  DateTime(shown.year, shown.month - 1),
                                ),
                        ),
                        Text(
                          fmtMonth(shown),
                          style: Theme.of(ctx).textTheme.bodyMedium,
                        ),
                        IconButton(
                          tooltip: 'Next month',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.chevron_right, size: 20),
                          onPressed: shown.isBefore(latest)
                              ? () => showMonth(
                                  DateTime(shown.year, shown.month + 1),
                                )
                              : null,
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Edit budget',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () =>
                              showBudgetDialog(ctx, existing: budget),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        RingProgress(
                          // Sweeps up once as the sheet opens; stepping
                          // months then eases between values.
                          sweepIn: true,
                          value: pct,
                          color: color,
                          trackColor: color.withValues(alpha: 0.25),
                          labelStyle: Theme.of(ctx).textTheme.titleSmall,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // FittedBox, not Flexible: keeps its intrinsic
                              // right edge (transaction-tile pattern).
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '${fmtMoneyWhole(spent)} / '
                                  '${fmtMoneyWhole(limit)}',
                                  style: Theme.of(ctx).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(height: 4),
                              // In the ring's colour.
                              Text(
                                over
                                    ? '${fmtMoneyWhole(spent - limit)} '
                                          'over the limit'
                                          '${shown == current ? '' : ' $when'}'
                                    : '${fmtMoneyWhole(limit - spent)} '
                                          'left $when',
                                style: Theme.of(
                                  ctx,
                                ).textTheme.bodySmall?.copyWith(color: color),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Above Where it went: that section holds the window's
                    // tallest month, and below the chart the room it keeps
                    // on a one-category month sits at the sheet's end.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: InfoLabel(
                        // Names its months: once the window pages back,
                        // they are no longer the last six.
                        label: Text(
                          '${months.length} months: '
                          '${DateFormat('MMM').format(months.first)} to '
                          '${DateFormat('MMM').format(months.last)}',
                          style: Theme.of(ctx).textTheme.titleSmall,
                        ),
                        tip: const InfoTip(
                          title: '$kBudgetChartMonths months',
                          message:
                              "Each bar is that month's spending in this "
                              'budget, with its amount above it when there '
                              'is any. The line '
                              'marks the limit. Months before your records '
                              'start show a flat line. The six months stay '
                              'put while you step through them; stepping '
                              'past either end moves six months. Tap a bar '
                              'to show that month.',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _BudgetTrendBars(
                      months: months,
                      spent: trend,
                      limit: limit,
                      selected: shown,
                      firstMonth: firstMonth,
                      // A bar shows its month: the sheet steps there, as
                      // the chevrons do.
                      onSelect: showMonth,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Where it went',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    Stack(
                      fit: StackFit.passthrough,
                      children: [
                        // Invisible copies that hold the section at the
                        // window's tallest month; the shown month sits on
                        // top.
                        for (final r in reserves)
                          ExcludeSemantics(
                            child: Visibility(
                              visible: false,
                              maintainSize: true,
                              maintainAnimation: true,
                              maintainState: true,
                              child: CategoryDonutChart(
                                data: r.data,
                                emptyRing: true,
                                emptyText: emptyText(r.month),
                              ),
                            ),
                          ),
                        // One category is not a split: a full ring says
                        // nothing a line cannot.
                        if (breakdown.length == 1)
                          Align(
                            alignment: Alignment.topCenter,
                            child: _OneCategoryLine(
                              entry: breakdown.single,
                              onTap: onCategoryTap,
                            ),
                          )
                        else
                          CategoryDonutChart(
                            key: const ValueKey('budget-donut'),
                            data: breakdown,
                            emptyRing: true,
                            emptyText: emptyText(shown),
                            onCategoryTap: onCategoryTap,
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (onViewTransactions != null)
                      FilledButton.icon(
                        icon: const Icon(Icons.receipt_long_outlined, size: 18),
                        label: const Text('View transactions'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          onViewTransactions(budget.id, shown);
                        },
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Six vertical bars of budget spend, tinted by the same green/orange/error
/// thresholds the budget rows use, with a subtle line where the limit sits.
/// The bars are a fixed window on one scale; the [selected] month's bar
/// keeps its colour and its label turns bold, the rest fade. Tapping a bar
/// shows its month in the sheet ([onSelect]).
class _BudgetTrendBars extends StatelessWidget {
  final List<DateTime> months;
  final List<double> spent;
  final double limit;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  /// The ledger's first month; a slot before it shows a flat line and its
  /// month name, and takes no tap.
  final DateTime? firstMonth;

  const _BudgetTrendBars({
    required this.months,
    required this.spent,
    required this.limit,
    required this.selected,
    required this.onSelect,
    this.firstMonth,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxVal = [...spent, limit].fold(0.0, (m, v) => v > m ? v : m);
    final mmm = DateFormat('MMM');
    final morph = motionDuration(context, const Duration(milliseconds: 450));

    Color barColor(double v) {
      final pct = limit == 0 ? 0.0 : v / limit;
      return budgetColor(context, pct);
    }

    final label = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    // The highlight does not rest on colour alone: the month's label is
    // bold too.
    final selectedLabel = label?.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    );

    // A month before the records start is not on record at all.
    bool before(int i) => firstMonth != null && months[i].isBefore(firstMonth!);

    // One row of six equal slots, so the value labels, the bars and the
    // month labels line up column for column. [blank] builds a month
    // before the records start; without it the slot is empty.
    Widget slots(
      Widget Function(int i) cell, {
      Widget Function(int i)? blank,
    }) => Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < months.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: !before(i)
                ? cell(i)
                : blank?.call(i) ?? const SizedBox.shrink(),
          ),
        ],
      ],
    );

    Widget monthLabel(int i) => Center(
      child: Text(
        mmm.format(months[i]),
        style: months[i] == selected ? selectedLabel : label,
      ),
    );

    // A month with nothing to draw: a flat line along the base, brighter
    // when it is the shown month.
    Widget flatLine({bool selected = false}) => Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        height: 2,
        color: selected ? scheme.onSurfaceVariant : scheme.outlineVariant,
      ),
    );

    Widget bar(int i) {
      final heightFactor = maxVal == 0
          ? 0.0
          : (spent[i] / maxVal).clamp(0.02, 1.0);
      final base = barColor(spent[i]);
      final isSelected = months[i] == selected;
      // The whole column is the target: a short bar is too small to hit.
      return Semantics(
        button: true,
        selected: isSelected,
        label: 'Show ${DateFormat('MMMM yyyy').format(months[i])}',
        excludeSemantics: true,
        onTap: () => onSelect(months[i]),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(months[i]),
          // Nothing spent: the same flat line as a month before the
          // records, so every empty month reads alike.
          child: spent[i] == 0
              ? flatLine(selected: isSelected)
              : Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedFractionallySizedBox(
              duration: morph,
              curve: Curves.easeOutCubic,
              heightFactor: heightFactor,
              child: AnimatedContainer(
                duration: morph,
                decoration: BoxDecoration(
                  color: isSelected ? base : base.withValues(alpha: 0.35),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 120,
      child: Column(
        children: [
          slots(
            // Only above a bar with something in it: a row of "₹0" said
            // nothing.
            (i) => FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                spent[i] > 0 ? fmtMoneyCompact(spent[i]) : '',
                style: label,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Stack(
              children: [
                // A month before the records: a flat line, no tap, so the
                // slot reads as no data rather than a blank.
                Positioned.fill(
                  child: slots(bar, blank: (_) => flatLine()),
                ),
                // The limit, on the same scale as the bars ([maxVal]
                // includes it, so the line always fits). It ignores taps so
                // the bars beneath it stay tappable.
                if (limit > 0 && maxVal > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        // Eases with the bars, so a bar under the limit
                        // never pokes above the line mid-step.
                        child: AnimatedFractionallySizedBox(
                          key: const ValueKey('budget-limit-line'),
                          duration: morph,
                          curve: Curves.easeOutCubic,
                          heightFactor: limit / maxVal,
                          widthFactor: 1,
                          alignment: Alignment.bottomCenter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: scheme.onSurfaceVariant.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Every slot is named, months before the records too.
          slots(monthLabel, blank: monthLabel),
        ],
      ),
    );
  }
}

/// A month whose budget spending sits in one category: "All in Groceries"
/// and the amount, in place of a ring that would be one full circle. The
/// row opens that category, as a legend entry does.
class _OneCategoryLine extends StatelessWidget {
  final MapEntry<TxCategory, double> entry;
  final void Function(String categoryId)? onTap;

  const _OneCategoryLine({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = entry.key;
    final tap = onTap;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: tap == null ? null : () => tap(c.id),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(c.icon, size: 20, color: categoryGlyphColor(context, c.color)),
            const SizedBox(width: 12),
            Expanded(child: Text('All in ${c.label}')),
            const SizedBox(width: 8),
            Text(
              fmtMoneyWhole(entry.value),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
