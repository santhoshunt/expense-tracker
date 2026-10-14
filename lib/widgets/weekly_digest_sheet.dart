import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/add_transaction_sheet.dart';
import '../screens/app_nav.dart';
import '../screens/transactions_screen.dart' show TxFilterRequest;
import '../services/recurring_detector.dart' show RecurringHit;
import '../services/upcoming_items.dart';
import '../services/weekly_digest.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';

/// Last week (or any week) at a glance: spent against the usual week, a
/// bar per day, the top categories, the biggest payments, what is due and
/// what waits for review. Opened from the Overview's This week row, the
/// Dashboard's ⋮ menu and the Monday note. ‹ and › step through weeks,
/// from the week of the first transaction to this one. It watches the
/// ledger, so edits made from it show at once.
///
/// [hits] are the Dashboard's detected repeats, for Due in the next 7
/// days. [onOpenTransactions] opens the Transactions tab; null leaves the
/// day, category and payment taps that need it off.
Future<void> showWeeklyDigestSheet(
  BuildContext context, {
  required DateTime week,
  required List<RecurringHit> hits,
  void Function(TxFilterRequest request)? onOpenTransactions,
}) {
  var shown = weekStartOf(week);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final finance = ctx.watch<FinanceProvider>();
        final settings = ctx.watch<SettingsProvider>();
        final now = weekClock();
        final current = weekStartOf(now);
        final first = finance.firstTransactionDate;
        final lastWeekStart = DateTime(
          current.year,
          current.month,
          current.day - 7,
        );
        // Last week always: the Monday note books for it even when the
        // records start this week (a first row added Monday morning).
        final recordsStart = first == null ? current : weekStartOf(first);
        final firstWeek = first != null && recordsStart.isAfter(lastWeekStart)
            ? lastWeekStart
            : recordsStart;
        // Never past this week, never before the records start.
        final week = shown.isAfter(current)
            ? current
            : shown.isBefore(firstWeek)
            ? firstWeek
            : shown;
        final d = buildWeekDigest(finance, week, now: now);
        final isCurrent = week == current;
        final lastWeek = lastWeekStart;
        final theme = Theme.of(ctx);
        final text = theme.textTheme;
        final scheme = theme.colorScheme;
        final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
        final out = moneyColor(ctx, type: TxType.expense);
        final range = DateTimeRange(start: d.start, end: d.end);

        void step(int weeks) => setSheet(
          () => shown = DateTime(week.year, week.month, week.day + 7 * weeks),
        );

        // Closes the sheet first, so Transactions opens with nothing on top.
        VoidCallback? open(TxFilterRequest request) {
          final go = onOpenTransactions;
          if (go == null) return null;
          return () {
            Navigator.pop(ctx);
            go(request);
          };
        }

        final usual = d.usual;
        final soFar = isCurrent ? ' so far' : '';
        final String compareLine;
        if (usual == null) {
          compareLine = 'Not enough weeks yet for a usual week';
        } else {
          final diff = d.spent - usual;
          final usualText = fmtMoneyTidy(usual);
          compareLine = diff.abs() < 0.5
              ? 'The same as your usual week$soFar ($usualText)'
              : diff > 0
              ? '${fmtMoneyTidy(diff)} more than your usual week$soFar '
                    '($usualText)'
              : '${fmtMoneyTidy(-diff)} less than your usual week$soFar '
                    '($usualText)';
        }

        final due = (isCurrent || week == lastWeek)
            ? [
                for (final u in buildUpcomingItems(
                  finance,
                  hits: hits,
                  hidden: settings.hiddenUpcoming,
                  now: now,
                ))
                  if (!u.muted && u.days <= 7) u,
              ]
            : const <UpcomingItem>[];

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous week',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: week.isAfter(firstWeek)
                          ? () => step(-1)
                          : null,
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            _weekTitle(week, now),
                            style: text.titleLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _weekDays(week),
                            style: muted,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next week',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: week.isBefore(current) ? () => step(1) : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(isCurrent ? 'Spent so far' : 'Spent', style: muted),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    fmtMoney(d.spent),
                    style: text.headlineSmall?.copyWith(
                      color: out,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                _CompareLine(
                  text: compareLine,
                  diff: usual == null ? null : d.spent - usual,
                ),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!settings.hideIncome) ...[
                        Expanded(
                          child: _Tile(
                            title: 'In',
                            value: fmtMoney(d.income),
                            color: moneyColor(ctx, type: TxType.income),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: _Tile(
                          title: 'Transactions',
                          value: '${d.count}',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (d.spent <= 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      // "that week" once stepped back from this one.
                      d.count == 0
                          ? 'No transactions ${isCurrent ? 'this' : 'that'} week'
                          : 'Nothing spent ${isCurrent ? 'this' : 'that'} week',
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else ...[
                  _DayBars(
                    digest: d,
                    color: out,
                    onDay: onOpenTransactions == null
                        ? null
                        : (day) => open(
                            TxFilterRequest(
                              range: DateTimeRange(start: day, end: day),
                              rangeCounted: true,
                            ),
                          )?.call(),
                  ),
                  const SizedBox(height: 16),
                  _Heading('Top categories'),
                  for (final e in d.topCategories)
                    _Row(
                      leading: Icon(
                        e.key.icon,
                        size: 20,
                        color: categoryGlyphColor(ctx, e.key.color),
                      ),
                      label: e.key.label,
                      amount: fmtMoney(e.value),
                      amountColor: out,
                      onTap: open(
                        TxFilterRequest(
                          categoryId: e.key.id,
                          type: TxType.expense,
                          range: range,
                          rangeCounted: true,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  _Heading('Biggest payments'),
                  for (final t in d.biggest)
                    _Row(
                      leading: Icon(
                        categoryById(
                          t.categoryId,
                          fallbackType: TxType.expense,
                        ).icon,
                        size: 20,
                        color: categoryGlyphColor(
                          ctx,
                          categoryById(
                            t.categoryId,
                            fallbackType: TxType.expense,
                          ).color,
                        ),
                      ),
                      // The category on top, the merchant and day under
                      // it: one joined line wrapped "· Mon" onto a line of
                      // its own at 320dp.
                      label: categoryById(
                        t.categoryId,
                        fallbackType: TxType.expense,
                      ).label,
                      sub: [
                        ?finance.merchantLabelFor(t),
                        DateFormat('EEE').format(t.effectiveDate),
                      ].join(' · '),
                      amount: fmtMoney(t.spendAmount),
                      amountColor: out,
                      // Over the digest, which shows an edit at once.
                      onTap: () => showAddTransactionSheet(ctx, existing: t),
                    ),
                ],
                if (due.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Heading('Due in the next 7 days'),
                  for (final u in due)
                    _Row(
                      leading: Icon(
                        u.kind == UpcomingKind.cardBill
                            ? Icons.credit_card
                            : categoryById(
                                u.categoryId!,
                                fallbackType: u.type,
                              ).icon,
                        size: 20,
                        color: u.kind == UpcomingKind.cardBill
                            ? scheme.onSurfaceVariant
                            : categoryGlyphColor(
                                ctx,
                                categoryById(
                                  u.categoryId!,
                                  fallbackType: u.type,
                                ).color,
                              ),
                      ),
                      label: u.label,
                      sub: _dueText(u.days),
                      amount: u.amount == null ? '' : fmtMoney(u.amount!),
                      // As the Upcoming card colours them: a card bill and a
                      // transfer move your own money, so they stay plain.
                      amountColor: moneyColor(
                        ctx,
                        type: u.type,
                        transfer:
                            u.kind == UpcomingKind.cardBill ||
                            (u.categoryId != null &&
                                isTransferCategory(u.categoryId!)),
                      ),
                    ),
                ],
                if (d.toReview > 0) ...[
                  const SizedBox(height: 12),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.card,
                        4,
                        4,
                        4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.inbox_outlined,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              d.toReview == 1
                                  ? '1 import to review'
                                  : '${d.toReview} imports to review',
                              style: text.bodyMedium,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              AppNav.instance.openHomeTab(
                                context,
                                kHomeTabTransactions,
                              );
                            },
                            child: const Text('Review'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// "Week of 12 Oct", with the year when it is not this one.
String _weekTitle(DateTime week, DateTime now) =>
    'Week of ${DateFormat(week.year == now.year ? 'd MMM' : 'd MMM yyyy').format(week)}';

/// "Mon 12 to Sun 18 Oct", or "Mon 28 Sep to Sun 4 Oct" across a month end.
String _weekDays(DateTime week) {
  final end = DateTime(week.year, week.month, week.day + 6);
  final from = DateFormat(
    week.month == end.month ? 'EEE d' : 'EEE d MMM',
  ).format(week);
  return '$from to ${DateFormat('EEE d MMM').format(end)}';
}

String _dueText(int days) => days < 0
    ? 'Overdue'
    : days == 0
    ? 'Due today'
    : days == 1
    ? 'Due tomorrow'
    : 'Due in $days days';

/// The line under the spent figure. The arrow carries the colour, red for
/// more and green for less; the text stays plain, as on the recap card.
class _CompareLine extends StatelessWidget {
  final String text;
  final double? diff;
  const _CompareLine({required this.text, required this.diff});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    final diff = this.diff;
    if (diff == null || diff.abs() < 0.5) {
      return Text(text, style: style?.copyWith(color: scheme.onSurfaceVariant));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          diff > 0 ? Icons.trending_up : Icons.trending_down,
          size: 16,
          color: diff > 0 ? scheme.error : AppColors.of(context).green,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(text, style: style?.copyWith(color: scheme.onSurface)),
        ),
      ],
    );
  }
}

/// One figure on a plain card.
class _Tile extends StatelessWidget {
  final String title;
  final String value;
  final Color? color;
  const _Tile({required this.title, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Monday to Sunday, one bar each on one scale. A day after today draws
/// no bar and takes no tap.
class _DayBars extends StatelessWidget {
  final WeekDigest digest;
  final Color color;

  /// A tap on [day]'s bar; null leaves the bars untappable.
  final ValueChanged<DateTime>? onDay;

  const _DayBars({
    required this.digest,
    required this.color,
    required this.onDay,
  });

  static const _barHeight = 72.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final top = digest.byDay.fold(0.0, (m, v) => v > m ? v : m);
    final start = digest.start;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final day = DateTime(start.year, start.month, start.day + i);
                final shown = i < digest.daysShown;
                final amount = digest.byDay[i];
                final bar = SizedBox(
                  height: _barHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: !shown
                        ? null
                        : Container(
                            width: 18,
                            // A 2dp stub marks a day with no spending.
                            height: amount <= 0 || top <= 0
                                ? 2
                                : (amount / top * _barHeight).clamp(
                                    2.0,
                                    _barHeight,
                                  ),
                            decoration: BoxDecoration(
                              color: amount <= 0
                                  ? scheme.surfaceContainerHighest
                                  : color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                  ),
                );
                final column = ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      bar,
                      const SizedBox(height: 4),
                      Text(DateFormat('EEE').format(day), style: muted),
                    ],
                  ),
                );
                final label =
                    '${DateFormat('EEEE').format(day)} ${fmtMoney(amount)}';
                final tap = onDay;
                if (!shown || tap == null) {
                  return Semantics(
                    label: shown ? label : null,
                    excludeSemantics: shown,
                    child: column,
                  );
                }
                return Semantics(
                  button: true,
                  label: label,
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    onTap: () => tap(day),
                    child: column,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String label;
  const _Heading(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(
      label,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// One list row: an icon, a label (and a muted line under it), and the
/// amount on the right. At least 48dp tall; the whole row is the tap
/// target when [onTap] is set.
class _Row extends StatelessWidget {
  final Widget leading;
  final String label;
  final String? sub;
  final String amount;
  final Color amountColor;
  final VoidCallback? onTap;

  const _Row({
    required this.leading,
    required this.label,
    this.sub,
    required this.amount,
    required this.amountColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: text.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (sub case final sub?)
                    Text(
                      sub,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Up to half the row; a lakh-sized figure shrinks past that.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.5),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  amount,
                  maxLines: 1,
                  style: text.bodyMedium?.copyWith(
                    color: amountColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: row,
      ),
    );
  }
}
