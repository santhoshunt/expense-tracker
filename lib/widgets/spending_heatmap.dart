import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../screens/add_transaction_sheet.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';

/// Calendar heatmap of money-out for one month (which DATES were hot) plus
/// the recurring weekday pattern underneath (which DAYS are usually hot).
/// Day cells tint toward the error colour with spend; tapping a day lists
/// its transactions. Hour-of-day is deliberately not shown: midnight is the
/// app's "time unknown" sentinel and would fake a spike.
class SpendingHeatmap extends StatelessWidget {
  final DateTime month;

  const SpendingHeatmap({super.key, required this.month});

  static const _weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _weekdayNames = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final byDay = finance.expenseByDayInMonth(month);
    final maxDay = byDay.values.fold(0.0, (m, v) => v > m ? v : m);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Column index (0 = Monday) of the month's first day.
    final leading = DateTime(month.year, month.month, 1).weekday - 1;
    final weeks = ((leading + daysInMonth) / 7).ceil();
    final weekdayAvg = finance.avgExpenseByWeekday();
    final maxAvg = weekdayAvg.fold(0.0, (m, v) => v > m ? v : m);

    Widget dayCell(int day) {
      final spend = byDay[day] ?? 0;
      final intensity = maxDay == 0 ? 0.0 : (spend / maxDay).clamp(0.0, 1.0);
      // Zero-spend days stay neutral; hot days deepen toward the error
      // tint. Once the fill is strong enough that the default text colour
      // would wash out, the date flips to whichever of black/white actually
      // reads on THAT fill — hardcoded white measured 2.4:1 on the hottest
      // dark-mode cell (the fill is exactly scheme.error there).
      final fill = spend == 0
          ? scheme.surfaceContainerHigh
          : Color.lerp(
              scheme.surfaceContainerHigh,
              scheme.error,
              0.25 + 0.75 * intensity,
            )!;
      final textColor = spend == 0
          ? scheme.onSurfaceVariant
          : intensity >= 0.35
          ? onSwatch(fill)
          : scheme.onSurface;
      return Expanded(
        child: AspectRatio(
          aspectRatio: 1,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Semantics(
              label:
                  '$day ${fmtMonth(month)}'
                  '${spend == 0 ? '' : ', spent ${fmtMoney(spend)}'}',
              button: spend > 0,
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: spend == 0
                    ? null
                    : () => _showDaySheet(
                        context,
                        DateTime(month.year, month.month, day),
                        spend,
                      ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '$day',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: textColor,
                        fontWeight: spend == 0
                            ? FontWeight.w400
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget blank() => const Expanded(child: SizedBox.shrink());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final l in _weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(
                    l,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var w = 0; w < weeks; w++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                switch (w * 7 + col - leading + 1) {
                  final d when d >= 1 && d <= daysInMonth => dayCell(d),
                  _ => blank(),
                },
            ],
          ),
        const SizedBox(height: 16),
        Text('By weekday', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          'Average per weekday, all history.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (var wd = 0; wd < 7; wd++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                // Both label boxes scale with the text: an unbreakable
                // "Wed" in a fixed 36px box wraps mid-word ("We"/"d") at
                // large system font sizes.
                SizedBox(
                  width: MediaQuery.textScalerOf(context).scale(36),
                  child: Text(
                    _weekdayNames[wd],
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxAvg == 0 ? 0 : weekdayAvg[wd] / maxAvg,
                      minHeight: 8,
                      color: scheme.error,
                      backgroundColor: scheme.error.withValues(alpha: 0.15),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: MediaQuery.textScalerOf(context).scale(64),
                  child: Text(
                    fmtMoneyCompact(weekdayAvg[wd]),
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// One day's money-out rows; row tap opens the normal edit sheet.
  void _showDaySheet(BuildContext context, DateTime day, double total) {
    final finance = context.read<FinanceProvider>();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      builder: (ctx) {
        final rows = finance.expensesOnDay(day);
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '${fmtDate(day)} · ${fmtMoney(total)} spent',
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
              ),
              for (final t in rows)
                ListTile(
                  dense: true,
                  leading: Icon(
                    t.category.icon,
                    color: t.category.color,
                    size: 20,
                  ),
                  title: Text(
                    t.note.isNotEmpty ? t.note : t.category.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The header total counts only the user's own share of a
                  // split bill — say so on the row, or a ₹125 header over a
                  // single −₹500 row doesn't add up (same annotation as the
                  // main transaction tile).
                  subtitle: Text(
                    t.isSplit
                        ? '${t.category.label} · your share '
                              '${fmtMoney(t.myShare!)}'
                        : t.category.label,
                  ),
                  trailing: Text(
                    '−${fmtMoney(t.amount)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    showAddTransactionSheet(context, existing: t);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
