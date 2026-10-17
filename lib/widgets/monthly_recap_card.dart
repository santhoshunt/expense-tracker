import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/monthly_recap.dart';
import '../services/spend_comparison.dart';
import '../utils/app_theme.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import '../utils/text_scale.dart';
import 'dashboard_fold.dart';
import 'delta_note.dart';
import 'info_tip.dart';
import 'status_dot.dart';

/// "This month so far"'s tip; the Trends fold heading shows it too.
const String kPaceTipMessage =
    'Spending from the 1st to today, against the same days of last month, '
    'so a half-finished month is not measured against a whole one. On track '
    'for is the Month-end forecast: spent so far, plus bills still due, plus '
    'your usual everyday spending for the days left. Without an everyday '
    'estimate it is a floor and reads At least. See chart opens both months '
    'day by day.';

/// The monthly recap's tip, on the card's own title or on the Overview
/// label above it.
const InfoTip kMonthlyRecapTip = InfoTip(
  title: 'Monthly recap',
  message:
      "Last month's totals, shown for the first $kRecapDays days of the "
      "month; after that, Trends' This month so far card covers the month. "
      "It updates if you edit last month's transactions. A notification on "
      "the 1st says when a new one is ready. Any month's recap also opens "
      'from the ⋮ menu.',
);

/// Last month's recap, shown on the Overview for the first [kRecapDays]
/// days: spent and saved, then the top categories, the biggest merchant
/// and any budget that ended over. No income: the card is about spending.
///
/// It steps aside on its own once [kRecapDays] pass, when Trends' This
/// month so far card ([MonthPaceCard]) covers the month; [onDone] puts it
/// away sooner. The links reuse the dashboard's deep-link callbacks, scoped
/// to its month.
class MonthlyRecapCard extends StatelessWidget {
  final MonthlyRecap recap;
  final void Function(String categoryId, DateTime month)? onViewCategory;
  final void Function(String query, DateTime month)? onViewMerchant;
  final void Function(String budgetId, DateTime month)? onViewBudget;

  /// The overall cap has no budget id; it opens the month's spending.
  final void Function(DateTime month)? onViewSpending;

  /// The Done button: hides this month's recap. Null leaves the button out.
  final VoidCallback? onDone;

  /// False leaves out the "September recap" title and its gap, for a host
  /// that draws its own header (the recap sheet).
  final bool showTitle;

  const MonthlyRecapCard({
    super.key,
    required this.recap,
    this.onViewCategory,
    this.onViewMerchant,
    this.onViewBudget,
    this.onViewSpending,
    this.onDone,
    this.showTitle = true,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final monthName = DateFormat('MMMM').format(recap.month);
    final prevShort = DateFormat(
      'MMM',
    ).format(DateTime(recap.month.year, recap.month.month - 1));
    final compare = recap.vsPrevious;
    final showDelta = compare.state == CompareState.ok;
    final deltaText = compare.negligible
        ? 'About the same as $prevShort'
        : deltaPhrase(compare, than: ' than $prevShort');
    final merchant = recap.topMerchant;

    // No margin: the Overview spaces its cards itself, and the default 4dp
    // made this card narrower than the cards above and below it.
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.card,
          12,
          AppSpace.card,
          AppSpace.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The title is its own tip.
            if (showTitle) ...[
              InfoLabel(
                label: Text('$monthName recap', style: text.titleMedium),
                tip: kMonthlyRecapTip,
              ),
              const SizedBox(height: 8),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Stat(
                    label: 'Spent',
                    value: fmtMoneyWhole(recap.spent),
                    note: showDelta ? deltaText : null,
                    noteCompare: compare,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Stat(
                    label: 'Saved',
                    value: fmtMoneyWhole(recap.saved),
                  ),
                ),
              ],
            ),
            if (recap.topCategories.isNotEmpty ||
                merchant != null ||
                recap.budgetsOver.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 4),
            ],
            if (recap.topCategories.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Top categories',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final e in recap.topCategories)
                _AmountRow(
                  label: e.key.label,
                  amount: fmtMoneyWhole(e.value),
                  style: muted,
                  onTap: onViewCategory == null
                      ? null
                      : () => onViewCategory!(e.key.id, recap.month),
                ),
            ],
            if (merchant != null)
              _Line(
                label: 'Biggest merchant',
                onTap: onViewMerchant == null
                    ? null
                    : () => onViewMerchant!(
                        merchant.key.substring(merchant.key.indexOf('|') + 1),
                        recap.month,
                      ),
                child: Text(
                  '${merchant.label} ${fmtMoneyWhole(merchant.total)} '
                  '(${merchant.count} '
                  '${merchant.count == 1 ? 'payment' : 'payments'})',
                  style: muted,
                ),
              ),
            for (final b in recap.budgetsOver)
              _BudgetLine(
                standing: b,
                month: recap.month,
                onViewBudget: onViewBudget,
                onViewSpending: onViewSpending,
              ),
            if (onDone case final done?)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: done, child: const Text('Done')),
              ),
          ],
        ),
      ),
    );
  }
}

/// Trends' month against the one before it, for any month in Month view:
/// spending through today (or the whole month once it has ended) against
/// the same days of the previous month, the gap between them, and while the
/// month runs where it is heading, from the Month-end forecast when there
/// is one.
class MonthPaceCard extends StatelessWidget {
  final MonthComparison comparison;

  /// The Month-end forecast's total; null falls back to the comparison's
  /// own projection.
  final double? forecastTotal;

  /// The forecast has no everyday estimate, so its total is a floor and
  /// reads "At least".
  final bool forecastIsFloor;

  /// Opens the day-by-day chart sheet. Null leaves the button out.
  final VoidCallback? onSeeChart;

  const MonthPaceCard({
    super.key,
    required this.comparison,
    this.forecastTotal,
    this.forecastIsFloor = false,
    this.onSeeChart,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final c = comparison;
    final month = c.month;
    final monthName = DateFormat('MMMM').format(month);
    final short = DateFormat('MMM').format(month);
    final prevShort = DateFormat('MMM').format(c.previousMonth);
    final prevLong = DateFormat('MMMM').format(c.previousMonth);
    final byDay = c.partial ? ' by this day' : '';
    final prev = c.vsPrevious;
    final compared = prev.state != CompareState.notEnoughHistory;
    // Both bars share one scale, so their lengths compare.
    final top = compared && prev.reference > prev.actual
        ? prev.reference
        : prev.actual;
    // A shorter last month is taken whole once today passes its length:
    // on 30 March the reference is all of February, not "1 to 30 Feb".
    final prevDays = daysInMonth(c.previousMonth.year, c.previousMonth.month);
    final prevWindow = c.throughDay >= prevDays
        ? 'all of $prevShort'
        : '1 to ${c.throughDay} $prevShort';
    final window = c.partial
        ? '1 to ${c.throughDay} $short against $prevWindow'
        : 'All of $short against all of $prevShort';
    // Where the month is heading: the forecast's total when there is one,
    // so Trends and the Overview give the same figure.
    final projected = c.partial ? (forecastTotal ?? prev.actualFull) : null;
    final hasFull = compared && prev.referenceFull > 0;
    String? projection;
    if (projected != null) {
      projection =
          (forecastIsFloor
              ? 'At least ${fmtMoneyWhole(projected)} by month end'
              : 'On track for ${fmtMoneyWhole(projected)}') +
          (hasFull
              ? ', against ${fmtMoneyWhole(prev.referenceFull)} in all of '
                    '$prevLong'
              : '');
    } else if (c.partial && hasFull) {
      projection = 'All of $prevLong: ${fmtMoneyWhole(prev.referenceFull)}';
    }

    // No margin, as the recap card.
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.card,
          12,
          AppSpace.card,
          AppSpace.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A fold heading above carries the title and tip already; on its
            // own the title is the tip.
            if (!DashboardFoldScope.of(context))
              InfoLabel(
                label: Text(
                  c.partial ? '$monthName so far' : monthName,
                  style: text.titleMedium,
                ),
                tip: InfoTip(
                  title: c.partial ? 'This month so far' : monthName,
                  message: kPaceTipMessage,
                ),
              ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                fmtMoneyWhole(prev.actual),
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              compared
                  ? window
                  : 'Not enough of $prevShort on record to compare',
              style: muted,
            ),
            if (prev.empty) ...[
              const SizedBox(height: 8),
              Text(
                c.partial
                    ? 'Nothing recorded this month or in $prevLong.'
                    : 'Nothing recorded in $monthName or in $prevLong.',
                style: muted,
              ),
            ] else ...[
              const SizedBox(height: 10),
              _PaceBar(
                label: short,
                amount: prev.actual,
                max: top,
                color: scheme.primary,
              ),
              if (compared) ...[
                const SizedBox(height: 6),
                _PaceBar(
                  label: prevShort,
                  amount: prev.reference,
                  max: top,
                  color: scheme.outline,
                ),
              ],
              switch (prev.state) {
                CompareState.ok => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DeltaNote(
                    text: prev.negligible
                        ? 'About the same as $prevShort$byDay'
                        : deltaPhrase(prev, than: ' than $prevShort$byDay'),
                    delta: prev.delta,
                    style: text.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CompareState.newThisMonth => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    c.partial
                        ? 'All of it new. Nothing in $prevLong by this day.'
                        : 'All of it new. Nothing in all of $prevLong.',
                    style: muted,
                  ),
                ),
                CompareState.noneThisMonth => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    c.partial
                        ? 'Nothing yet this month. $prevLong had reached '
                              '${fmtMoneyWhole(prev.reference)} by now.'
                        : 'Nothing in $monthName. $prevLong came to '
                              '${fmtMoneyWhole(prev.reference)}.',
                    style: muted,
                  ),
                ),
                CompareState.notEnoughHistory => const SizedBox.shrink(),
              },
              if (projection != null) ...[
                Divider(height: 20, color: scheme.outlineVariant),
                Text(projection, style: muted),
              ],
              if (onSeeChart case final see?)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: see,
                    // The label shortens rather than overflowing at large
                    // text on a narrow phone.
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'See chart',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One month's bar on the pace card: label, bar scaled to [max], amount.
class _PaceBar extends StatelessWidget {
  final String label;
  final double amount;
  final double max;
  final Color color;

  const _PaceBar({
    required this.label,
    required this.amount,
    required this.max,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final share = max <= 0 ? 0.0 : (amount / max).clamp(0.0, 1.0);
    return Semantics(
      label: '$label ${fmtMoneyWhole(amount)}',
      excludeSemantics: true,
      // Caps on the label and amount so the bar keeps a share of the row: at
      // a large font size on a narrow phone the two texts alone overflowed
      // it. Below the caps nothing changes; above them the text scales down.
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            // At least the width of "Sep", growing with the font scale rather
            // than wrapping the month name.
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: 36.0.clamp(0.0, box.maxWidth * 0.25),
                maxWidth: box.maxWidth * 0.25,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  label,
                  softWrap: false,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  value: share,
                  minHeight: 10,
                  color: color,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: 72.0.clamp(0.0, box.maxWidth * 0.4),
                maxWidth: box.maxWidth * 0.4,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  fmtMoneyWhole(amount),
                  textAlign: TextAlign.end,
                  style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Personal spendings: ₹40,800 of ₹20,000 · over by ₹20,800", or
/// "· ₹1,900 left". Amounts rather than a percentage: "204%" read as a
/// figure for the wrong month.
class _BudgetLine extends StatelessWidget {
  final BudgetStanding standing;
  final DateTime month;
  final void Function(String budgetId, DateTime month)? onViewBudget;
  final void Function(DateTime month)? onViewSpending;

  const _BudgetLine({
    required this.standing,
    required this.month,
    required this.onViewBudget,
    required this.onViewSpending,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final b = standing;
    final over = b.spent > b.limit;
    final id = b.budgetId;
    final onTap = id == null
        ? (onViewSpending == null ? null : () => onViewSpending!(month))
        : (onViewBudget == null ? null : () => onViewBudget!(id, month));
    // One wrapping paragraph, not a label column: the name is the user's
    // own and can be long enough to squeeze the amounts to nothing.
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            // Over the limit, a red dot leads the line; the text keeps the
            // plain colours.
            if (over)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: StatusDot(color: scheme.error),
                ),
              ),
            TextSpan(
              text: '${b.label}: ',
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: '${fmtMoneyWhole(b.spent)} of ${fmtMoneyWhole(b.limit)} · ',
              style: TextStyle(
                color: over ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
            // The overshoot in plain text: the red dot leads the line.
            TextSpan(
              text: over
                  ? 'over by ${fmtMoneyWhole(b.spent - b.limit)}'
                  : '${fmtMoneyWhole(b.limit - b.spent)} left',
              style: TextStyle(
                color: over ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        style: text.bodySmall,
      ),
    );
    if (onTap == null) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: _TapHeight(child: body),
    );
  }
}

/// At least [_kTapHeight] tall, content centred: a bare line of small text
/// was a 20 to 24dp target.
class _TapHeight extends StatelessWidget {
  final Widget child;
  const _TapHeight({required this.child});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: _kTapHeight),
    child: Align(alignment: Alignment.centerLeft, widthFactor: 1, child: child),
  );
}

const _kTapHeight = 40.0;

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String? note;

  /// The change [note] describes, for its arrow's direction and colour.
  final SpendCompare? noteCompare;

  const _Stat({
    required this.label,
    required this.value,
    this.note,
    this.noteCompare,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        // Scales down rather than wrapping: a lakh-sized figure must stay on
        // one line beside its neighbours.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (note case final note?)
          if (noteCompare case final compare?)
            DeltaNote(text: note, delta: compare.delta, style: text.labelSmall)
          else
            Text(note, style: text.labelSmall, maxLines: 2),
      ],
    );
  }
}

/// One labelled line under the stats; the whole line is the tap target when
/// [onTap] is set.
class _Line extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Widget child;

  const _Line({required this.label, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // At large text the label sits above the value, so the value gets the
    // card's whole width instead of a narrow second column.
    final stacked = isLargeTextScale(context);
    final labelText = Text(
      stacked ? label : '$label: ',
      style: text.bodySmall?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    );
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, child],
            )
          // The label wraps within half the row instead of pushing the
          // value off the card.
          : LayoutBuilder(
              builder: (context, box) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.5),
                    child: labelText,
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
    );
    if (onTap == null) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: _TapHeight(child: body),
    );
  }
}

/// One top category: its name on the left, its amount on the right, at
/// least [_kTapHeight] tall. The whole row is the tap target when [onTap]
/// is set.
class _AmountRow extends StatelessWidget {
  final String label;
  final String amount;
  final TextStyle? style;
  final VoidCallback? onTap;

  const _AmountRow({
    required this.label,
    required this.amount,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _kTapHeight),
      // The amount keeps up to half the row and shrinks past that, so a
      // lakh-sized figure at large text never pushes the name off the card.
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
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
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.5),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: Text(amount, style: style, maxLines: 1),
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
