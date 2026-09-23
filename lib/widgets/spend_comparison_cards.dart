import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../providers/settings_provider.dart' show CategorySort;
import '../screens/app_nav.dart' show goCockpitRules;
import '../services/spend_comparison.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'animated_fold.dart';
import 'comparison_bar.dart';
import 'info_tip.dart';

/// The dashboard's three spending comparisons: this month against the last
/// one, against what a month usually costs, and the same question per
/// category. Each renders a whole section (heading plus card) so the
/// dashboard call site stays one line.
///
/// All the arithmetic is in services/spend_comparison.dart; these widgets
/// only choose colours and words for the state they are handed.

final DateFormat _monthName = DateFormat('MMMM');

/// Spending more than the reference is the warning colour, less is the
/// income green, and a difference under a rupee is neither.
Color _toneFor(BuildContext context, double delta) {
  if (negligibleDelta(delta)) return AppColors.of(context).blue;
  return delta > 0
      ? Theme.of(context).colorScheme.error
      : AppColors.of(context).green;
}

class PreviousMonthCard extends StatelessWidget {
  final MonthComparison comparison;

  const PreviousMonthCard({super.key, required this.comparison});

  @override
  Widget build(BuildContext context) {
    final c = comparison.vsPrevious;
    final name = _monthName.format(comparison.previousMonth);
    final tip =
        'While the month is running, compares spending up to the same day '
        "of last month. The projection scales this month's spending by how "
        'last month grew from this day to its end, and appears from day '
        '$kMinDaysForProjection. When last month is not fully on record, it '
        "uses this month's daily pace instead, once $kMinDaysOfData days are "
        'on record.';

    // Records that start part-way through last month (or later) leave no
    // fair "same day" figure; say so rather than compare a few days.
    if (c.state == CompareState.notEnoughHistory) {
      final projected = c.actualFull;
      final muted = Theme.of(context).textTheme.bodySmall;
      return _Section(
        title: 'This month vs last month',
        tip: tip,
        example: () => projectionExample(comparison),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$name is not fully on record, so there is no fair comparison '
              'yet.',
              style: muted,
            ),
            if (comparison.partial && projected != null) ...[
              const SizedBox(height: 4),
              Text(
                'At its current pace this month is on track for '
                '${fmtMoney(projected)}.',
                style: muted,
              ),
            ],
          ],
        ),
      );
    }

    return _Section(
      title: 'This month vs last month',
      tip: tip,
      example: () => projectionExample(comparison),
      child: _CompareBody(
        comparison: comparison,
        compare: c,
        referenceLine: comparison.partial
            ? '$name reached ${fmtMoney(c.reference)} by the same day'
            : '$name: ${fmtMoney(c.reference)}',
        projectionLine: (projected) =>
            'On track for $projected, against '
            '${fmtMoney(c.referenceFull)} in all of $name',
        fullReferenceLine: 'All of $name: ${fmtMoney(c.referenceFull)}',
        emptyLine: 'Nothing recorded this month or in $name.',
        newLine: 'All of it new. Nothing in $name by this day.',
        noneLine:
            'Nothing yet this month. $name had reached '
            '${fmtMoney(c.reference)} by now.',
      ),
    );
  }
}

/// The "This month vs last month" projection worked with its real inputs,
/// mirroring `_project` in services/spend_comparison.dart: the reference
/// month's curve when it has one, the flat daily pace otherwise. Null when
/// the card shows no projection (month over, before day
/// [kMinDaysForProjection], or nothing on either side).
String? projectionExample(MonthComparison comparison) {
  final c = comparison.vsPrevious;
  final projected = c.actualFull;
  if (!comparison.partial || projected == null || c.empty) return null;
  final days = daysInMonth(comparison.month.year, comparison.month.month);
  final ratio = c.reference <= 0 || c.referenceFull <= 0
      ? '$days days ÷ ${comparison.paceDays} days on record'
      : '${fmtMoney(c.referenceFull)} ÷ ${fmtMoney(c.reference)}';
  return '${fmtMoney(c.actual)} so far × ($ratio) = '
      '${fmtMoney(projected)} projected';
}

/// The shortfall note shown instead of a "usual" figure while fewer than
/// [kMinUsualMonths] complete months are on record.
String usualShortfallNote(int months) =>
    'A usual figure needs at least $kMinUsualMonths complete months to '
    'mean anything. There '
    '${months == 1 ? 'is 1 month' : 'are $months months'} on record so '
    'far, so this fills in as you keep importing.';

class UsualSpendCard extends StatelessWidget {
  final MonthComparison comparison;

  const UsualSpendCard({super.key, required this.comparison});

  @override
  Widget build(BuildContext context) {
    final c = comparison.vsUsual;
    final months = comparison.usualMonths;
    const tip =
        '"Usual" is the middle value of up to 6 complete months before '
        'this one, so one unusual month does not move it the way an average '
        'would. While the month is running, both sides count only up to '
        "today's date. It needs at least 2 complete months.";
    String? example() {
      if (c.state == CompareState.notEnoughHistory || c.reference <= 0) {
        return null;
      }
      final d = c.actual - c.reference;
      return 'This month ${fmtMoney(c.actual)} vs usual '
          '${fmtMoney(c.reference)} = ${d < 0 ? '−' : '+'}${fmtMoney(d.abs())}';
    }

    if (c.state == CompareState.notEnoughHistory) {
      return _Section(
        title: 'This month vs usual',
        tip: tip,
        child: Text(
          usualShortfallNote(months),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    return _Section(
      // "This month" leads in every comparison title, so the two headline
      // cards read as one series instead of juggling the order.
      title: 'This month vs usual',
      tip: tip,
      example: example,
      subtitle:
          'The middle of your last $months complete '
          '${months == 1 ? 'month' : 'months'}, so one unusual bill does not '
          'move it.',
      child: _CompareBody(
        comparison: comparison,
        compare: c,
        referenceLine: comparison.partial
            ? 'Usually ${fmtMoney(c.reference)} by this day'
            : 'Usually ${fmtMoney(c.reference)} in a month',
        projectionLine: (projected) =>
            'On track for $projected, against a usual '
            '${fmtMoney(c.referenceFull)} a month',
        fullReferenceLine:
            'Usually ${fmtMoney(c.referenceFull)} in a full month',
        emptyLine: 'Nothing recorded this month, and nothing usually.',
        newLine: 'All of it new. You do not usually spend by this day.',
        noneLine:
            'Nothing yet this month. You usually reach '
            '${fmtMoney(c.reference)} by now.',
      ),
    );
  }
}

/// Shared body of the two headline cards: amount, signed difference, the
/// bar, and the projected full month while one is still running.
class _CompareBody extends StatelessWidget {
  final MonthComparison comparison;
  final SpendCompare compare;
  final String referenceLine;
  final String Function(String projected) projectionLine;

  /// Stands in for [projectionLine] on the first few days of a month, when
  /// there is no projection yet but the full reference month is still worth
  /// naming ("show both" holds from day 1).
  final String fullReferenceLine;
  final String emptyLine;
  final String newLine;
  final String noneLine;

  const _CompareBody({
    required this.comparison,
    required this.compare,
    required this.referenceLine,
    required this.projectionLine,
    required this.fullReferenceLine,
    required this.emptyLine,
    required this.newLine,
    required this.noneLine,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    if (compare.empty) {
      return Text(emptyLine, style: muted);
    }

    final tone = _toneFor(context, compare.delta);
    final projected = compare.actualFull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      fmtMoney(compare.actual),
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    comparison.partial
                        ? 'Through ${fmtDateCompact(DateTime(comparison.month.year, comparison.month.month, comparison.throughDay))}'
                        : 'Full month',
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (compare.state == CompareState.ok)
              // Colour on the card surface, never on a filled background.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    compare.negligible
                        ? Icons.drag_handle
                        : compare.delta > 0
                        ? Icons.trending_up
                        : Icons.trending_down,
                    size: 18,
                    color: tone,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      deltaPhrase(compare),
                      textAlign: TextAlign.end,
                      style: text.bodyMedium?.copyWith(
                        color: tone,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        ComparisonBar(
          actual: compare.actual,
          reference: compare.reference,
          color: tone,
          trackColor: scheme.surfaceContainerHigh,
          notchColor: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 8),
        _ReferenceLine(
          // The key only earns its place while there is a notch to explain.
          marked: compare.reference > 0,
          style: muted,
          text: switch (compare.state) {
            CompareState.newThisMonth => newLine,
            CompareState.noneThisMonth => noneLine,
            _ => referenceLine,
          },
        ),
        if (comparison.partial)
          if (projected != null) ...[
            const Divider(height: 20),
            Text(projectionLine(fmtMoney(projected)), style: muted),
          ] else if (compare.referenceFull > 0) ...[
            const Divider(height: 20),
            Text(fullReferenceLine, style: muted),
          ],
      ],
    );
  }
}

/// Per-category spend against its usual, biggest deviation first. Only the
/// top few show until the user asks for the rest. Row order is a
/// [CategorySort] (enum in settings_provider.dart, where it persists).
class CategoryComparisonCard extends StatefulWidget {
  final MonthComparison comparison;

  /// Opens the transaction list for a category, scoped to the shown month.
  final void Function(String categoryId)? onViewCategory;

  /// Externally owned sort (the dashboard passes the persisted setting);
  /// null falls back to widget-local state, which keeps provider-less
  /// harnesses working.
  final CategorySort? sort;
  final ValueChanged<CategorySort>? onSortChanged;

  const CategoryComparisonCard({
    super.key,
    required this.comparison,
    this.onViewCategory,
    this.sort,
    this.onSortChanged,
  });

  @override
  State<CategoryComparisonCard> createState() => _CategoryComparisonCardState();
}

class _CategoryComparisonCardState extends State<CategoryComparisonCard> {
  bool _expanded = false;
  CategorySort _sort = CategorySort.biggestChange;

  CategorySort get _effectiveSort => widget.sort ?? _sort;

  void _setSort(CategorySort s) {
    widget.onSortChanged?.call(s);
    if (widget.sort == null) setState(() => _sort = s);
  }

  List<CategoryCompare> _sorted(List<CategoryCompare> rows) {
    switch (_effectiveSort) {
      case CategorySort.biggestChange:
        return rows;
      case CategorySort.mostUnusual:
        return [...rows]..sort((a, b) {
          final ap = a.deltaPct, bp = b.deltaPct;
          // No usual to divide by means infinitely unusual: pinned first.
          if ((ap == null) != (bp == null)) return ap == null ? -1 : 1;
          if (ap == null || bp == null) return b.actual.compareTo(a.actual);
          return bp.abs().compareTo(ap.abs());
        });
      case CategorySort.highestSpend:
        return [...rows]..sort((a, b) => b.actual.compareTo(a.actual));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _sorted(widget.comparison.categories);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    const title = 'Categories vs usual';
    const tip =
        '"Usual" is the middle value of up to $kUsualWindowMonths complete '
        'months before this one, so one unusual month does not move it. A '
        'month with nothing in a category counts as zero. While the month is '
        "running, both sides count only up to today's date. Red means more "
        'than usual, green less.';
    String? example() {
      if (rows.isEmpty) return null;
      final top = rows.first;
      if (top.usual <= 0) return null;
      final d = top.delta;
      return '${top.category.label}: ${fmtMoney(top.actual)} this month vs '
          '${fmtMoney(top.usual)} usual = '
          '${d < 0 ? '−' : '+'}${fmtMoney(d.abs())}';
    }

    // Same gate as "This month vs usual": with too little history every
    // row would read "New this month", which says nothing.
    if (widget.comparison.usualMonths < kMinUsualMonths) {
      return _Section(
        title: title,
        tip: tip,
        link: _rulesLink,
        child: Text(
          usualShortfallNote(widget.comparison.usualMonths),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    if (rows.isEmpty) {
      return _Section(
        title: title,
        tip: tip,
        link: _rulesLink,
        child: Text('No category spending to compare yet.', style: muted),
      );
    }

    final head = rows.take(kTopMoversShown).toList();
    final rest = rows.skip(kTopMoversShown).toList();

    final scheme = Theme.of(context).colorScheme;
    return _Section(
      title: title,
      tip: tip,
      example: example,
      link: _rulesLink,
      subtitle: _effectiveSort.subtitle,
      // Compact rounded menu with a small trailing check — the stock
      // CheckedPopupMenuItem reserves a full leading slot for its tick,
      // which read as dated chrome and wasted a third of the row.
      trailing: PopupMenuButton<CategorySort>(
        tooltip: 'Sort',
        icon: Icon(Icons.sort, size: 20, color: scheme.onSurfaceVariant),
        padding: EdgeInsets.zero,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        onSelected: _setSort,
        itemBuilder: (context) => [
          for (final s in CategorySort.values)
            PopupMenuItem(
              value: s,
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.label,
                      style: TextStyle(
                        fontSize: 14,
                        color: s == _effectiveSort
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: s == _effectiveSort
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (s == _effectiveSort) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.check, size: 16, color: scheme.primary),
                  ],
                ],
              ),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in head)
            _CategoryCompareRow(compare: c, onView: widget.onViewCategory),
          if (rest.isNotEmpty) ...[
            AnimatedFold(
              collapsed: !_expanded,
              child: Column(
                children: [
                  for (final c in rest)
                    _CategoryCompareRow(
                      compare: c,
                      onView: widget.onViewCategory,
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? 'Show less'
                      : 'Show all ${rows.length} categories',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryCompareRow extends StatelessWidget {
  final CategoryCompare compare;

  /// The card's [CategoryComparisonCard.onViewCategory], passed through.
  final void Function(String categoryId)? onView;

  const _CategoryCompareRow({required this.compare, required this.onView});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final tone = _toneFor(context, compare.delta);
    final cat = compare.category;

    // A row with nothing spent this month would deep-link to an empty list,
    // so it stays informative but untappable.
    final tappable =
        onView != null && compare.state != CompareState.noneThisMonth;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: tappable ? () => onView!(cat.id) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: cat.color.withValues(alpha: 0.15),
              child: Icon(
                cat.icon,
                size: 18,
                color: categoryGlyphColor(context, cat.color),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          cat.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            fmtMoney(compare.actual),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ComparisonBar(
                    actual: compare.actual,
                    reference: compare.usual,
                    color: tone,
                    trackColor: scheme.surfaceContainerHigh,
                    notchColor: scheme.onSurfaceVariant,
                    height: 8,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: _ReferenceLine(
                          marked: compare.usual > 0,
                          style: muted,
                          text: switch (compare.state) {
                            CompareState.newThisMonth => 'New this month',
                            CompareState.noneThisMonth =>
                              'Nothing yet, usually ${fmtMoney(compare.usual)}',
                            _ => 'Usually ${fmtMoney(compare.usual)}',
                          },
                        ),
                      ),
                      if (compare.state == CompareState.ok &&
                          !compare.negligible)
                        Text(
                          '${compare.delta > 0 ? '+' : '−'}'
                          '${fmtMoney(compare.delta.abs())}',
                          style: text.bodySmall?.copyWith(
                            color: tone,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The line naming what the bar is measured against, led by a copy of the
/// notch so the mark on the bar explains itself.
class _ReferenceLine extends StatelessWidget {
  final String text;
  final bool marked;
  final TextStyle? style;

  const _ReferenceLine({
    required this.text,
    required this.marked,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    if (!marked) return Text(text, style: style);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // Sits on the first line's text, whatever the font scale.
          padding: EdgeInsets.only(
            top: MediaQuery.textScalerOf(context).scale(3),
            right: 6,
          ),
          child: Container(
            width: kNotchWidth,
            height: MediaQuery.textScalerOf(context).scale(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              borderRadius: BorderRadius.circular(kNotchWidth / 2),
            ),
          ),
        ),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}

/// Categories vs usual: a surprising row is often a misclassified one.
const _rulesLink = InfoLink(
  prompt: 'A category looks wrong?',
  label: 'Set up transaction rules',
  onTap: goCockpitRules,
);

/// The dashboard's section recipe: spacing, a titleMedium heading, then the
/// body in a Card with the shared all(16) inset.
class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;

  /// Small control on the heading's right edge (the category card's sort).
  final Widget? trailing;

  /// The heading's "i", titled with [title].
  final String? tip;
  final String? Function()? example;
  final InfoLink? link;
  final Widget child;

  const _Section({
    required this.title,
    this.subtitle,
    this.trailing,
    this.tip,
    this.example,
    this.link,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(title, style: Theme.of(context).textTheme.titleMedium);
    final Widget heading = tip == null
        ? text
        : Align(
            alignment: Alignment.centerLeft,
            child: InfoLabel(
              label: text,
              tip: InfoTip(
                title: title,
                message: tip!,
                example: example,
                link: link,
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        if (trailing == null)
          heading
        else
          Row(
            children: [
              Expanded(child: heading),
              trailing!,
            ],
          ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        Card(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ],
    );
  }
}
