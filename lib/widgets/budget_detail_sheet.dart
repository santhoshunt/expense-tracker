import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import 'category_donut_chart.dart';
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
          final colors = AppColors.of(ctx);
          final scheme = Theme.of(ctx).colorScheme;
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
          final color = pct >= 1.0
              ? scheme.error
              : pct >= 0.8
              ? colors.orange
              : colors.green;
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
class _BudgetTrendBars extends StatelessWidget {
  final List<DateTime> months;
  final List<double> spent;
  final double limit;

  const _BudgetTrendBars({
    required this.months,
    required this.spent,
    required this.limit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final maxVal = [...spent, limit].fold(0.0, (m, v) => v > m ? v : m);
    final mmm = DateFormat('MMM');

    Color barColor(double v) {
      final pct = limit == 0 ? 0.0 : v / limit;
      return pct >= 1.0
          ? scheme.error
          : pct >= 0.8
          ? colors.orange
          : colors.green;
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
                Positioned.fill(
                  child: slots(
                    (i) => Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: maxVal == 0
                            ? 0
                            : (spent[i] / maxVal).clamp(0.02, 1.0),
                        child: Container(
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
                // The limit, on the same scale as the bars ([maxVal]
                // includes it, so the line always fits).
                if (limit > 0 && maxVal > 0)
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        key: const ValueKey('budget-limit-line'),
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
