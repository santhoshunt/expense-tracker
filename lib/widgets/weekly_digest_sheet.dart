import 'dart:async';

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
import '../services/spend_comparison.dart' show negligibleDelta;
import '../services/upcoming_items.dart';
import '../services/weekly_digest.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import 'delta_note.dart';
import 'figure_tile.dart';

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
  // The Undo bar for a delete or Unpair made from the digest, and its
  // timer. Kept out here: the sheet runs its builder again on a drag.
  final undoBar = ValueNotifier<_UndoOffer?>(null);
  Timer? undoTimer;
  void offerUndo(String message, IconData icon, VoidCallback undo) {
    undoTimer?.cancel();
    var fired = false;
    late final _UndoOffer offer;
    offer = _UndoOffer(message, icon, () {
      // The button can be tapped again before the bar is gone.
      if (fired) return;
      fired = true;
      undoTimer?.cancel();
      if (identical(undoBar.value, offer)) undoBar.value = null;
      undo();
    });
    undoBar.value = offer;
    // As long as the app-level Undo toast stays up; with a screen reader
    // on it stays until replaced or the sheet closes, as the toast's
    // persist does, so Undo can still be reached.
    if (MediaQuery.maybeOf(context)?.accessibleNavigation ?? false) return;
    undoTimer = Timer(const Duration(seconds: 5), () {
      if (identical(undoBar.value, offer)) undoBar.value = null;
    });
  }

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
          // Under a rupee is the same, as the recap's = mark has it.
          compareLine = negligibleDelta(diff)
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

        // The sheet's 20dp sides go on each child but the day bars, which
        // take 4dp: 7 columns get 44.6dp at 320dp and 48dp from 344dp up.
        Widget pad(Widget child) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: child,
        );

        // The Undo bar sits under the scrolling body, at the bottom of the
        // sheet, so it shows wherever the list is scrolled.
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      pad(
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
                                    weekRangeLabel(week, withWeekday: true),
                                    style: muted,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Next week',
                              icon: const Icon(Icons.chevron_right),
                              onPressed: week.isBefore(current)
                                  ? () => step(1)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      pad(
                        Text(
                          isCurrent ? 'Spent so far' : 'Spent',
                          style: muted,
                        ),
                      ),
                      pad(
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
                      ),
                      const SizedBox(height: 2),
                      // No usual week, no change to mark: the line stays plain.
                      pad(
                        usual == null
                            ? Text(compareLine, style: muted)
                            : DeltaNote(
                                text: compareLine,
                                delta: d.spent - usual,
                                style: text.bodySmall,
                                // The digest's line runs longer than the
                                // recap's: let it wrap at large text.
                                maxLines: null,
                              ),
                      ),
                      const SizedBox(height: 12),
                      pad(
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!settings.hideIncome) ...[
                                Expanded(
                                  child: FigureTile(
                                    title: 'In',
                                    value: fmtMoney(d.income),
                                    color: moneyColor(ctx, type: TxType.income),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: FigureTile(
                                  title: 'Transactions',
                                  value: '${d.count}',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (d.spent <= 0)
                        pad(
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
                          ),
                        )
                      else ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: _DayBars(
                            digest: d,
                            color: out,
                            onDay: onOpenTransactions == null
                                ? null
                                : (day) => open(
                                    TxFilterRequest(
                                      range: DateTimeRange(
                                        start: day,
                                        end: day,
                                      ),
                                      rangeCounted: true,
                                    ),
                                  )?.call(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        pad(_Heading('Top categories')),
                        for (final e in d.topCategories)
                          pad(
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
                          ),
                        const SizedBox(height: 12),
                        pad(_Heading('Biggest payments')),
                        for (final t in d.biggest)
                          pad(
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
                              // Over the digest, which shows an edit at once. A
                              // delete's Undo shows on the digest, which stays
                              // open; the app-level toast would draw under it.
                              onTap: () => showAddTransactionSheet(
                                ctx,
                                existing: t,
                                onUndoable: offerUndo,
                              ),
                            ),
                          ),
                      ],
                      if (due.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        pad(_Heading('Due in the next 7 days')),
                        for (final u in due)
                          pad(
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
                              sub: u.days < 0
                                  ? 'Overdue'
                                  : 'Due ${fmtInDays(u.days)}',
                              amount: u.amount == null
                                  ? ''
                                  : fmtMoney(u.amount!),
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
                          ),
                      ],
                      if (d.toReview > 0) ...[
                        const SizedBox(height: 12),
                        pad(
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
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              ValueListenableBuilder<_UndoOffer?>(
                valueListenable: undoBar,
                builder: (_, offer, _) =>
                    offer == null ? const SizedBox.shrink() : _UndoBar(offer),
              ),
            ],
          ),
        );
      },
    ),
    // The notifier is left to the garbage collector: the sheet's widgets can
    // still listen to it during the closing animation.
  ).whenComplete(() => undoTimer?.cancel());
}

/// A delete's or Unpair's Undo offer on the digest: the toast's message,
/// the icon naming what is undone, and the action.
class _UndoOffer {
  final String message;
  final IconData icon;
  final VoidCallback undo;
  const _UndoOffer(this.message, this.icon, this.undo);
}

/// The Undo offer drawn on the digest itself, as the app's removal toast
/// looks: the snackbar theme's pill, a bin on a rose tint, the message and
/// Undo.
class _UndoBar extends StatelessWidget {
  final _UndoOffer offer;
  const _UndoBar(this.offer);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bar = theme.snackBarTheme;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Material(
          color: bar.backgroundColor ?? scheme.surfaceContainerHigh,
          shape:
              bar.shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
              ),
          elevation: bar.elevation ?? 6,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(offer.icon, size: 16, color: scheme.error),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    offer.message,
                    // Outside a SnackBar the theme's text style is not
                    // inherited, so it is set here.
                    style:
                        bar.contentTextStyle ??
                        theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                        ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: bar.actionTextColor ?? scheme.primary,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: offer.undo,
                  child: const Text('Undo'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Week of 12 Oct", with the year when it is not this one.
String _weekTitle(DateTime week, DateTime now) =>
    'Week of ${DateFormat(week.year == now.year ? 'd MMM' : 'd MMM yyyy').format(week)}';

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
