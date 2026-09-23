import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/haptics.dart';
import 'category_donut_chart.dart';
import 'chart_popup.dart';
import 'info_tip.dart';
import 'motion.dart';

/// Visual detail for one custom budget, starting at [month]: progress ring,
/// category pie, 6-month trend, and the jump into the budget-filtered
/// transaction list. Opened by tapping a budget row on the dashboard.
/// Chevrons in the sheet step through months without leaving it.
Future<void> showBudgetDetailSheet(
  BuildContext context,
  SpendBudget budget,
  DateTime month, {
  void Function(String budgetId, DateTime month)? onViewTransactions,
  void Function(String categoryId, DateTime month)? onViewCategory,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetCtx) {
      // The shown month is sheet-local state: switching months here must
      // not move the dashboard behind the sheet.
      var shown = DateTime(month.year, month.month);
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final finance = ctx.watch<FinanceProvider>();
          // Same bound as the dashboard's next-month arrow: the current
          // month, or a later one when rows dated ahead put data there.
          final now = DateTime.now();
          var latest = DateTime(now.year, now.month);
          for (final m in finance.monthsWithData) {
            if (m.isAfter(latest)) latest = m;
          }
          final spent = finance.budgetSpentFor(budget, shown);
          final limit = budget.limit;
          final pct = limit == 0 ? 0.0 : spent / limit;
          final over = spent > limit;
          final color = budgetColor(ctx, pct);
          final breakdown = finance.budgetBreakdownFor(budget, shown);
          final months = List.generate(
            6,
            (i) => DateTime(shown.year, shown.month - (5 - i)),
          );
          final trend = [
            for (final m in months) finance.budgetSpentFor(budget, m),
          ];

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    budget.name,
                    style: Theme.of(ctx).textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous month',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.chevron_left, size: 20),
                        onPressed: () => setSheetState(
                          () => shown = DateTime(shown.year, shown.month - 1),
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
                            ? () => setSheetState(
                                () => shown = DateTime(
                                  shown.year,
                                  shown.month + 1,
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      RingProgress(
                        // Sweeps up once as the sheet opens; stepping months
                        // then eases between values.
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
                                '${fmtMoney(spent)} / ${fmtMoney(limit)}',
                                style: Theme.of(ctx).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              over
                                  ? '${fmtMoneyCompact(spent - limit)} over the '
                                        'limit'
                                  : '${fmtMoneyCompact(limit - spent)} left this '
                                        'month',
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
                  if (breakdown.isNotEmpty) ...[
                    Text(
                      'Where it went',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    CategoryDonutChart(
                      data: breakdown,
                      onCategoryTap: onViewCategory == null
                          ? null
                          : (id) {
                              Navigator.pop(ctx);
                              onViewCategory(id, shown);
                            },
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No spending counted toward this budget in '
                        '${fmtMonth(shown)}.',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: InfoLabel(
                      label: Text(
                        'Last 6 months',
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                      tip: const InfoTip(
                        title: 'Last 6 months',
                        message:
                            "Each bar is that month's spending in this "
                            'budget, coloured like the ring. The line marks '
                            'the limit.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _BudgetTrendBars(months: months, spent: trend, limit: limit),
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
          );
        },
      );
    },
  );
}

/// Six vertical bars of budget spend, tinted by the same green/orange/error
/// thresholds the budget rows use, with a subtle line where the limit sits.
/// Stepping months eases the bars to their new heights. Tapping a bar lifts
/// it, dims the rest and opens that month's spend against the limit.
class _BudgetTrendBars extends StatefulWidget {
  final List<DateTime> months;
  final List<double> spent;
  final double limit;

  const _BudgetTrendBars({
    required this.months,
    required this.spent,
    required this.limit,
  });

  @override
  State<_BudgetTrendBars> createState() => _BudgetTrendBarsState();
}

class _BudgetTrendBarsState extends State<_BudgetTrendBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _select = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  int? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _select.duration = motionDuration(
      context,
      const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _select.dispose();
    super.dispose();
  }

  Future<void> _open(BuildContext cell, int i, double heightFactor) async {
    final spent = widget.spent[i];
    final limit = widget.limit;
    final pct = limit == 0 ? 0.0 : spent / limit;
    final box = cell.findRenderObject()! as RenderBox;
    Haptics.tick();
    // A different bar starts from flat, not from the last one's lift.
    if (_selected != i) _select.value = 0;
    setState(() => _selected = i);
    _select.forward();
    await showAnchoredBubble(
      context,
      anchor: chartAnchor(
        cell,
        Offset(box.size.width / 2, box.size.height * (1 - heightFactor)),
      ),
      maxWidth: kChartPopupWidth,
      content: (_) => ChartPopup(
        title: DateFormat('MMMM yyyy').format(widget.months[i]),
        rows: [('Spent', fmtMoney(spent)), ('Limit', fmtMoney(limit))],
        footnote: limit == 0 ? null : '${(pct * 100).round()}% of limit',
        footnoteColor: limit == 0 ? null : budgetColor(context, pct),
        host: context,
      ),
    );
    if (!mounted || _selected != i) return;
    await _select.reverse();
    if (mounted && _selected == i && _select.value == 0) {
      setState(() => _selected = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final months = widget.months;
    final spent = widget.spent;
    final limit = widget.limit;
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

    // One row of six equal slots, so the value labels, the bars and the
    // month labels line up column for column.
    Widget slots(Widget Function(int i) cell) => Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < months.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: cell(i)),
        ],
      ],
    );

    Widget bar(int i) {
      final heightFactor = maxVal == 0
          ? 0.0
          : (spent[i] / maxVal).clamp(0.02, 1.0);
      return Builder(
        // The whole column is the target: a short bar is too small to hit.
        builder: (cell) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(cell, i, heightFactor),
          child: AnimatedBuilder(
            animation: _select,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(_select.value);
              final isSelected = _selected == i;
              return Opacity(
                opacity: _selected == null || isSelected ? 1 : 1 - 0.7 * t,
                child: Transform.translate(
                  offset: Offset(0, isSelected ? -4 * t : 0),
                  child: child,
                ),
              );
            },
            child: Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedFractionallySizedBox(
                duration: morph,
                curve: Curves.easeOutCubic,
                heightFactor: heightFactor,
                child: AnimatedContainer(
                  duration: morph,
                  decoration: BoxDecoration(
                    color: spent[i] == 0
                        ? scheme.surfaceContainerHigh
                        : barColor(spent[i]),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
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
            (i) => FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(fmtMoneyCompact(spent[i]), style: label),
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: slots(bar)),
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
          slots(
            (i) => Center(child: Text(mmm.format(months[i]), style: label)),
          ),
        ],
      ),
    );
  }
}
