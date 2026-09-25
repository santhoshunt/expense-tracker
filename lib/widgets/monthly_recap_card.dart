import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/monthly_recap.dart';
import '../services/spend_comparison.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import 'info_tip.dart';

/// Last month's recap on the Overview: spent, income and saved, then the
/// top categories, the biggest merchant and any budget that ended over.
///
/// Stays for the whole month, with no close button: it is the month's
/// summary, not a notice to clear. The links reuse the dashboard's own
/// deep-link callbacks, scoped to the recap's month.
class MonthlyRecapCard extends StatelessWidget {
  final MonthlyRecap recap;
  final bool hideIncome;
  final void Function(String categoryId, DateTime month)? onViewCategory;
  final void Function(String query, DateTime month)? onViewMerchant;
  final void Function(String budgetId, DateTime month)? onViewBudget;

  /// The overall cap has no budget id; it opens the month's spending.
  final void Function(DateTime month)? onViewSpending;

  const MonthlyRecapCard({
    super.key,
    required this.recap,
    required this.hideIncome,
    this.onViewCategory,
    this.onViewMerchant,
    this.onViewBudget,
    this.onViewSpending,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final monthName = DateFormat('MMMM').format(recap.month);
    final prevShort = DateFormat(
      'MMM',
    ).format(DateTime(recap.month.year, recap.month.month - 1));
    final compare = recap.vsPrevious;
    final showDelta = compare.state == CompareState.ok;
    final deltaTone = compare.negligible
        ? colors.blue
        : compare.delta > 0
        ? scheme.error
        : colors.green;
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
                      "Last month's totals. It stays here all month and "
                      "updates if you edit last month's transactions. A "
                      'notification on the 1st says when a new one is ready.',
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
                    noteColor: deltaTone,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(
                    label: 'Income',
                    value: hideIncome ? kMaskedAmount : fmtMoney(recap.income),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(
                    label: 'Saved',
                    value: hideIncome ? kMaskedAmount : fmtMoney(recap.saved),
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
              _Line(
                label: 'Over budget',
                labelColor: scheme.error,
                onTap: b.budgetId == null
                    ? (onViewSpending == null
                          ? null
                          : () => onViewSpending!(recap.month))
                    : (onViewBudget == null
                          ? null
                          : () => onViewBudget!(b.budgetId!, recap.month)),
                child: Text(
                  '${b.label} (${(b.pct * 100).round()}%)',
                  style: muted?.copyWith(color: scheme.error),
                ),
              ),
          ],
        ),
      ),
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
  final Color? labelColor;
  final VoidCallback? onTap;
  final Widget child;

  const _Line({
    required this.label,
    required this.onTap,
    required this.child,
    this.labelColor,
  });

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
              color: labelColor ?? scheme.onSurface,
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
