import 'package:flutter/material.dart';

import '../providers/settings_provider.dart' show CategorySort;
import '../screens/app_nav.dart' show goCockpitRules;
import '../services/spend_comparison.dart';
import '../services/year_comparison.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'comparison_bar.dart';
import 'dashboard_fold.dart';
import 'info_tip.dart';
import 'show_all_list.dart';

/// The dashboard's two spending comparisons and the category one: this month
/// against what a month usually costs, this year against last year, and the
/// usual question per category. (This month against the last one is
/// MonthPaceCard, in monthly_recap_card.dart.) Each renders a whole section
/// (heading plus card) so the dashboard call site stays one line.
///
/// All the arithmetic is in services/spend_comparison.dart; these widgets
/// only choose colours and words for the state they are handed.

/// Spending more than the reference is the warning colour, less is the
/// income green, and a difference under a rupee is neither.
Color _toneFor(BuildContext context, double delta) {
  if (negligibleDelta(delta)) return AppColors.of(context).blue;
  return delta > 0
      ? Theme.of(context).colorScheme.error
      : AppColors.of(context).green;
}

const _usualTitle = 'This month vs usual';
const _usualTip =
    '"Usual" is the middle value of up to 6 complete months before '
    'this one, so one unusual month does not move it the way an average '
    'would. While the month is running, both sides count only up to '
    "today's date. It needs at least 2 complete months; a month with under "
    "a quarter of the others' middle spend is left out as missing records.";

const _categoryTitle = 'Categories vs usual';
const _categoryTip =
    '"Usual" is the middle value of up to $kUsualWindowMonths complete '
    'months before this one, so one unusual month does not move it. A '
    'month with nothing in a category counts as zero. While the month is '
    "running, both sides count only up to today's date.";

/// The cards' tips, for a dashboard fold heading: inside a fold the cards
/// leave theirs out, so each section carries its tip on the heading,
/// folded or open.
InfoTip usualTip(MonthComparison comparison) => InfoTip(
  title: _usualTitle,
  message: _usualTip,
  example: () => _usualExample(comparison),
);

InfoTip categoryComparisonTip(MonthComparison comparison, CategorySort sort) =>
    InfoTip(
      title: _categoryTitle,
      message: _categoryTip,
      example: () => _categoryExample(
        comparison.usualMonths < kMinUsualMonths
            ? const []
            : sortCategoryCompares(comparison.categories, sort),
      ),
      link: _rulesLink,
    );

String? _usualExample(MonthComparison comparison) {
  final c = comparison.vsUsual;
  if (c.state == CompareState.notEnoughHistory || c.reference <= 0) {
    return null;
  }
  final d = c.actual - c.reference;
  return 'This month ${fmtMoney(c.actual)} vs usual '
      '${fmtMoney(c.reference)} = ${d < 0 ? '−' : '+'}${fmtMoney(d.abs())}';
}

String? _categoryExample(List<CategoryCompare> rows) {
  if (rows.isEmpty) return null;
  final top = rows.first;
  if (top.usual <= 0) return null;
  final d = top.delta;
  return '${top.category.label}: ${fmtMoney(top.actual)} this month vs '
      '${fmtMoney(top.usual)} usual = '
      '${d < 0 ? '−' : '+'}${fmtMoney(d.abs())}';
}

/// [rows] in [sort]'s order; [CategorySort.biggestChange] is the order the
/// comparison already has.
List<CategoryCompare> sortCategoryCompares(
  List<CategoryCompare> rows,
  CategorySort sort,
) {
  switch (sort) {
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
    'A usual figure needs at least $kMinUsualMonths complete months with '
    'enough spending to mean anything. There '
    '${months == 1 ? 'is 1 such month' : 'are $months such months'} so '
    'far, so this fills in as you keep importing.';

class UsualSpendCard extends StatelessWidget {
  final MonthComparison comparison;

  /// The Month-end forecast's total while the month runs: what On track
  /// for shows. Null falls back to the comparison's own projection.
  final double? forecastTotal;

  /// The forecast has no everyday estimate, so its total is a floor and
  /// reads "At least".
  final bool forecastIsFloor;

  /// Opens the comparison chart.
  final VoidCallback? onTap;

  const UsualSpendCard({
    super.key,
    required this.comparison,
    this.forecastTotal,
    this.forecastIsFloor = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = comparison.vsUsual;
    final months = comparison.usualMonths;
    const tip = _usualTip;
    String? example() => _usualExample(comparison);

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
      onTap: onTap,
      subtitle:
          'The middle of your last $months complete '
          '${months == 1 ? 'month' : 'months'}, so one unusual bill does not '
          'move it.',
      child: _CompareBody(
        comparison: comparison,
        compare: c,
        forecastTotal: forecastTotal,
        forecastIsFloor: forecastIsFloor,
        referenceLine: comparison.partial
            ? 'Usually ${fmtMoneyWhole(c.reference)} by this day'
            : 'Usually ${fmtMoneyWhole(c.reference)} in a month',
        projectionLine: (projected, floor) => floor
            ? 'At least $projected by month end, against a usual '
                  '${fmtMoneyWhole(c.referenceFull)} a month'
            : 'On track for $projected, against a usual '
                  '${fmtMoneyWhole(c.referenceFull)} a month',
        fullReferenceLine:
            'Usually ${fmtMoneyWhole(c.referenceFull)} in a full month',
        emptyLine: 'Nothing recorded this month, and nothing usually.',
        newLine: 'All of it new. You do not usually spend by this day.',
        noneLine:
            'Nothing yet this month. You usually reach '
            '${fmtMoneyWhole(c.reference)} by now.',
      ),
    );
  }
}

/// The usual card's body: amount, signed difference, the bar, and the
/// projected full month while one is still running.
class _CompareBody extends StatelessWidget {
  final MonthComparison comparison;
  final SpendCompare compare;
  final String referenceLine;

  /// The projected line; [floor] says the figure is a floor ("At least").
  final String Function(String projected, bool floor) projectionLine;

  /// Stands in for [projectionLine] on the first few days of a month, when
  /// there is no projection yet but the full reference month is still worth
  /// naming ("show both" holds from day 1).
  final String fullReferenceLine;
  final String emptyLine;
  final String newLine;
  final String noneLine;

  /// Stands in for the comparison's own projection while the month runs.
  final double? forecastTotal;

  /// [forecastTotal] is a floor: the forecast has no everyday estimate.
  final bool forecastIsFloor;

  const _CompareBody({
    required this.comparison,
    required this.compare,
    this.forecastTotal,
    this.forecastIsFloor = false,
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
    final projected = forecastTotal ?? compare.actualFull;

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
                      fmtMoneyWhole(compare.actual),
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
              // The trend icon and the phrase share the tone.
              // Flexible: at large text on a narrow phone the phrase wraps
              // instead of pushing past the card.
              Flexible(
                child: Row(
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
                        // The arrow's tone on the words too; plain when
                        // about the same.
                        style: text.bodyMedium?.copyWith(
                          color: compare.negligible ? scheme.onSurface : tone,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
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
            Text(
              projectionLine(
                fmtMoneyWhole(projected),
                forecastIsFloor && forecastTotal != null,
              ),
              style: muted,
            ),
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

  /// Called with a row's category id on tap: the dashboard opens its
  /// history, whose button lists the shown month's transactions.
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
  CategorySort _sort = CategorySort.biggestChange;

  CategorySort get _effectiveSort => widget.sort ?? _sort;

  void _setSort(CategorySort s) {
    widget.onSortChanged?.call(s);
    if (widget.sort == null) setState(() => _sort = s);
  }

  @override
  Widget build(BuildContext context) {
    final rows = sortCategoryCompares(
      widget.comparison.categories,
      _effectiveSort,
    );
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    const title = _categoryTitle;
    const tip = _categoryTip;
    String? example() => _categoryExample(rows);

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
      child: ShowAllList(
        key: ValueKey(widget.comparison.month),
        noun: 'categories',
        shown: kTopMoversShown,
        rows: [
          for (final c in rows)
            _CategoryCompareRow(compare: c, onView: widget.onViewCategory),
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

    // A row opens the category's history, which says something even with
    // nothing spent this month; the sheet leaves out its empty list.
    final tappable = onView != null;

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
                            fmtMoneyWhole(compare.actual),
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
                              'Nothing yet, usually '
                                  '${fmtMoneyWhole(compare.usual)}',
                            _ => 'Usually ${fmtMoneyWhole(compare.usual)}',
                          },
                        ),
                      ),
                      if (compare.state == CompareState.ok &&
                          !compare.negligible)
                        // The sign says which way, the colour how it went:
                        // red for more than usual, green for less.
                        Text(
                          '${compare.delta > 0 ? '+' : '−'}'
                          '${fmtMoneyWhole(compare.delta.abs())}',
                          style: text.bodySmall?.copyWith(
                            color: _toneFor(context, compare.delta),
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

/// Must match the `DashboardSection.yearVsLast` label word for word: inside
/// a fold, [_Section] leaves its heading to the fold's.
const _yearTitle = 'This year vs last year';
const _yearTip =
    'Compares this year with the same months of last year. While the year '
    "is running, both sides count up to today's date in the same month.";

/// The "This year vs last year" tip, for a dashboard fold heading (see
/// [usualTip]).
InfoTip yearComparisonTip(YearComparison c) => InfoTip(
  title: _yearTitle,
  message: _yearTip,
  example: () => _yearExample(c),
);

String? _yearExample(YearComparison c) {
  final t = c.total;
  if (t.state == CompareState.notEnoughHistory || t.reference <= 0) {
    return null;
  }
  final d = t.delta;
  return '${c.label} ${fmtMoney(t.actual)} vs ${c.previousLabel} '
      '${fmtMoney(t.reference)} = ${d < 0 ? '−' : '+'}${fmtMoney(d.abs())}';
}

/// The trend glyph every comparison uses: flat for a negligible change.
IconData _trendIcon(double delta) => negligibleDelta(delta)
    ? Icons.drag_handle
    : delta > 0
    ? Icons.trending_up
    : Icons.trending_down;

/// This year's spending against the same span of last year, then the
/// categories that moved most. Its own body rather than [_CompareBody],
/// whose lines and bar labels are written for a month ("Through 15 Jun",
/// "Full month").
///
/// The headline and the trend icons share the tone.
class YearComparisonCard extends StatelessWidget {
  final YearComparison comparison;

  /// Called with a row's category id on tap: the dashboard opens its
  /// history. Every row is tappable, as in [CategoryComparisonCard]; the
  /// sheet leaves out its transactions button when the year has none.
  final void Function(String categoryId)? onViewCategory;

  const YearComparisonCard({
    super.key,
    required this.comparison,
    this.onViewCategory,
  });

  @override
  Widget build(BuildContext context) {
    final c = comparison.total;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    String? example() => _yearExample(comparison);

    // Records that start part-way through last year (or later) leave no
    // fair "same span" figure; say so rather than compare a few months.
    if (c.state == CompareState.notEnoughHistory) {
      return _Section(
        title: _yearTitle,
        tip: _yearTip,
        child: Text(
          '${comparison.previousLabel} is not fully on record, so there is '
          'no fair comparison yet.',
          style: muted,
        ),
      );
    }

    if (c.empty) {
      return _Section(
        title: _yearTitle,
        tip: _yearTip,
        child: Text('Nothing recorded this year or last year.', style: muted),
      );
    }

    final headline = c.negligible
        ? 'About the same as last year'
        : deltaPhrase(c, than: ' than last year');
    final figures =
        'This year ${fmtMoneyWhole(c.actual)}, last year '
        '${fmtMoneyWhole(c.reference)}'
        '${comparison.partial ? ' by the same day' : ''}';

    return _Section(
      title: _yearTitle,
      tip: _yearTip,
      example: example,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _trendIcon(c.delta),
                size: 20,
                color: _toneFor(context, c.delta),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: c.negligible ? null : _toneFor(context, c.delta),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(figures, style: muted),
          if (comparison.categories.isNotEmpty) ...[
            const Divider(height: 24),
            ShowAllList(
              key: ValueKey(
                'yvl-${comparison.startYear}-${comparison.startMonth}',
              ),
              noun: 'categories',
              shown: kTopMoversShown,
              rows: [
                for (final row in comparison.categories)
                  _YearCategoryRow(compare: row, onView: onViewCategory),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One category this year: label and amount, then last year's figure and
/// the signed change. `usual` holds last year's figure (see
/// [YearComparison.categories]).
class _YearCategoryRow extends StatelessWidget {
  final CategoryCompare compare;

  /// The card's [YearComparisonCard.onViewCategory], passed through.
  final void Function(String categoryId)? onView;

  const _YearCategoryRow({required this.compare, required this.onView});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final cat = compare.category;
    // As in the month card: the row opens history, worth a look either way.
    final tappable = onView != null;
    final showDelta = compare.state == CompareState.ok && !compare.negligible;

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
                            fmtMoneyWhole(compare.actual),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(switch (compare.state) {
                          CompareState.newThisMonth => 'Nothing last year',
                          CompareState.noneThisMonth =>
                            'Nothing this year, '
                                '${fmtMoneyWhole(compare.usual)} last year',
                          _ => 'Last year ${fmtMoneyWhole(compare.usual)}',
                        }, style: muted),
                      ),
                      if (showDelta) ...[
                        const SizedBox(width: 8),
                        Icon(
                          _trendIcon(compare.delta),
                          size: 14,
                          color: _toneFor(context, compare.delta),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${compare.delta > 0 ? '+' : '−'}'
                          '${fmtMoneyWhole(compare.delta.abs())}',
                          style: text.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
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
/// body in a Card with the shared [AppSpace.card] inset.
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

  /// Makes the card a button, with a See chart row under its body.
  final VoidCallback? onTap;

  const _Section({
    required this.title,
    this.subtitle,
    this.trailing,
    this.tip,
    this.example,
    this.link,
    this.onTap,
    required this.child,
  });

  Widget _card(BuildContext context) {
    final tap = onTap;
    if (tap == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.card),
          child: child,
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.card,
            AppSpace.card,
            AppSpace.card,
            8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              child,
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      'See chart',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accentTextColor(context),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: accentTextColor(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    // Inside a dashboard fold its heading already shows [title] and the tip
    // (the dashboard passes the same one): keep the subtitle and the
    // controls, on one row, and no top gap.
    if (DashboardFoldScope.of(context)) {
      final line = subtitle == null ? null : Text(subtitle!, style: small);
      // Inset like the card's body, so the line starts where its text does.
      final Widget? head = trailing != null
          ? Row(
              children: [
                Expanded(child: line ?? const SizedBox.shrink()),
                trailing!,
              ],
            )
          : line;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (head != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.card),
              child: head,
            ),
            const SizedBox(height: 8),
          ],
          _card(context),
        ],
      );
    }
    final infoTip = tip == null
        ? null
        : InfoTip(title: title, message: tip!, example: example, link: link);
    final text = Text(title, style: Theme.of(context).textTheme.titleMedium);
    final Widget heading = infoTip == null
        ? text
        : Align(
            alignment: Alignment.centerLeft,
            child: InfoLabel(label: text, tip: infoTip),
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
          Text(subtitle!, style: small),
        ],
        const SizedBox(height: 8),
        _card(context),
      ],
    );
  }
}
