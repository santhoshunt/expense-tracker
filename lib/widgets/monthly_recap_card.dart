import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/monthly_recap.dart';
import '../services/spend_comparison.dart';
import '../utils/app_theme.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'info_tip.dart';

/// Colour for a spending change: red for more, green for less, blue for
/// about the same. Same rule as the comparison cards.
Color _deltaTone(BuildContext context, SpendCompare c) => c.negligible
    ? AppColors.of(context).blue
    : c.delta > 0
    ? Theme.of(context).colorScheme.error
    : AppColors.of(context).green;

/// Last month's recap, shown on the Overview for the first [kRecapDays]
/// days: spent and saved, then the top categories, the biggest merchant
/// and any budget that ended over. No income: the card is about spending.
///
/// No close button: it steps aside on its own for [MonthPaceCard]. The
/// links reuse the dashboard's deep-link callbacks, scoped to its month.
class MonthlyRecapCard extends StatelessWidget {
  final MonthlyRecap recap;
  final void Function(String categoryId, DateTime month)? onViewCategory;
  final void Function(String query, DateTime month)? onViewMerchant;
  final void Function(String budgetId, DateTime month)? onViewBudget;

  /// The overall cap has no budget id; it opens the month's spending.
  final void Function(DateTime month)? onViewSpending;

  const MonthlyRecapCard({
    super.key,
    required this.recap,
    this.onViewCategory,
    this.onViewMerchant,
    this.onViewBudget,
    this.onViewSpending,
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
        ? 'Same as $prevShort'
        : '${deltaPhrase(compare)} than $prevShort';
    final merchant = recap.topMerchant;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text('$monthName recap', style: text.titleMedium),
                ),
                const InfoTip(
                  title: 'Monthly recap',
                  message:
                      "Last month's totals, shown for the first $kRecapDays "
                      "days of the month; after that, this month's pace takes "
                      "its place. It updates if you edit last month's "
                      'transactions. A notification on the 1st says when a '
                      'new one is ready.',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Stat(
                    label: 'Spent',
                    value: fmtMoney(recap.spent),
                    note: showDelta ? deltaText : null,
                    noteColor: _deltaTone(context, compare),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Stat(label: 'Saved', value: fmtMoney(recap.saved)),
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
            if (recap.topCategories.isNotEmpty)
              _Line(
                label: 'Top',
                onTap: null,
                child: Wrap(
                  children: [
                    for (final (i, e) in recap.topCategories.indexed) ...[
                      if (i > 0) Text(' · ', style: muted),
                      _Link(
                        text: '${e.key.label} ${fmtMoney(e.value)}',
                        style: muted,
                        onTap: onViewCategory == null
                            ? null
                            : () => onViewCategory!(e.key.id, recap.month),
                      ),
                    ],
                  ],
                ),
              ),
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
                  '${merchant.label} ${fmtMoney(merchant.total)} '
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
          ],
        ),
      ),
    );
  }
}

/// This month so far, shown on the Overview once the recap steps aside:
/// spending through today against the same days of last month, and the
/// budgets close to or past their limit.
class MonthPaceCard extends StatelessWidget {
  final MonthPace pace;
  final void Function(String budgetId, DateTime month)? onViewBudget;
  final void Function(DateTime month)? onViewSpending;

  const MonthPaceCard({
    super.key,
    required this.pace,
    this.onViewBudget,
    this.onViewSpending,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final c = pace.comparison;
    final month = c.month;
    final monthName = DateFormat('MMMM').format(month);
    final short = DateFormat('MMM').format(month);
    final prevShort = DateFormat('MMM').format(c.previousMonth);
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text('$monthName so far', style: text.titleMedium),
                ),
                const InfoTip(
                  title: 'This month so far',
                  message:
                      'Spending from the 1st to today, against the same days '
                      'of last month, so a half-finished month is not '
                      'measured against a whole one. Budgets show here once '
                      'they reach 80% of their limit. Last month\'s recap '
                      'shows here instead for the first $kRecapDays days.',
                ),
              ],
            ),
            Text(
              compared
                  ? window
                  : 'Not enough of $prevShort on record to compare',
              style: muted,
            ),
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
              if (prev.state == CompareState.ok) ...[
                const SizedBox(height: 8),
                Text(
                  prev.negligible
                      ? 'About the same as $prevShort by this day'
                      : '${deltaPhrase(prev)} than $prevShort by this day',
                  style: text.bodySmall?.copyWith(
                    color: _deltaTone(context, prev),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
            if (pace.budgets.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 4),
              for (final b in pace.budgets)
                _BudgetLine(
                  standing: b,
                  month: month,
                  onViewBudget: onViewBudget,
                  onViewSpending: onViewSpending,
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
      label: '$label ${fmtMoney(amount)}',
      excludeSemantics: true,
      child: Row(
        children: [
          // At least the width of "Sep", growing with the font scale rather
          // than wrapping the month name.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 36),
            child: Text(
              label,
              softWrap: false,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
            constraints: const BoxConstraints(minWidth: 72),
            child: Text(
              fmtMoney(amount),
              textAlign: TextAlign.end,
              style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
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
            TextSpan(
              text: '${b.label}: ',
              style: TextStyle(
                color: over ? scheme.error : scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text:
                  '${fmtMoney(b.spent)} of ${fmtMoney(b.limit)} · '
                  '${over ? 'over by ${fmtMoney(b.spent - b.limit)}' : '${fmtMoney(b.limit - b.spent)} left'}',
              style: TextStyle(
                color: over ? scheme.error : scheme.onSurfaceVariant,
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
      child: body,
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final Color? noteColor;

  const _Stat({
    required this.label,
    required this.value,
    this.note,
    this.noteColor,
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
        if (note != null)
          Text(
            note!,
            style: text.labelSmall?.copyWith(color: noteColor),
            maxLines: 2,
          ),
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
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: text.bodySmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: body,
    );
  }
}

/// A tappable run of text inside a [_Line], for lines that hold several
/// targets (the top categories).
class _Link extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;

  const _Link({required this.text, required this.style, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: style);
    if (onTap == null) return label;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: label,
    );
  }
}
