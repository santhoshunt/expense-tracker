import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import 'category_donut_chart.dart';
import 'motion.dart';

/// Visual detail for one custom budget in [month]: progress ring, category
/// pie, 6-month trend, and the jump into the budget-filtered transaction
/// list. Opened by tapping a budget row on the dashboard.
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
    builder: (ctx) {
      final finance = ctx.watch<FinanceProvider>();
      final colors = AppColors.of(ctx);
      final scheme = Theme.of(ctx).colorScheme;
      final spent = finance.budgetSpentFor(budget, month);
      final limit = budget.limit;
      final pct = limit == 0 ? 0.0 : spent / limit;
      final over = spent > limit;
      final color = pct >= 1.0
          ? scheme.error
          : pct >= 0.8
          ? colors.orange
          : colors.green;
      final breakdown = finance.budgetBreakdownFor(budget, month);
      final months = List.generate(
        6,
        (i) => DateTime(month.year, month.month - (5 - i)),
      );
      final trend = [for (final m in months) finance.budgetSpentFor(budget, m)];

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
              Text(fmtMonth(month), style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 16),
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
                          onViewCategory(id, month);
                        },
                ),
                const SizedBox(height: 20),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No spending counted toward this budget in '
                    '${fmtMonth(month)}.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ],
              Text('Last 6 months', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 8),
              _BudgetTrendBars(months: months, spent: trend, limit: limit),
              const SizedBox(height: 20),
              if (onViewTransactions != null)
                FilledButton.icon(
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('View transactions'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    onViewTransactions(budget.id, month);
                  },
                ),
            ],
          ),
        ),
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

    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, m) in months.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      fmtMoneyCompact(spent[i]),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Align(
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
                  const SizedBox(height: 4),
                  Text(
                    mmm.format(m),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
