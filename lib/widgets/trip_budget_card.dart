import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'glossy.dart';

/// A small outline-only pill beside a budget's name: "# Goa trip" for a
/// tag budget, "Ended" for a finished trip. [accent] draws it in the accent
/// colour; otherwise it is muted. No fill, so the text never sits on
/// colour.
class BudgetPill extends StatelessWidget {
  final String label;
  final String? semanticsLabel;
  final bool accent;

  const BudgetPill({
    super.key,
    required this.label,
    this.semanticsLabel,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.control * 2),
        border: Border.all(
          color: accent ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        semanticsLabel: semanticsLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: accent ? accentTextColor(context) : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A dated budget's spend for each day of [range]: filled bars up to
/// [today], and for the days still to come dashed boxes at what is left of
/// [limit] per remaining day, with a dashed line across at that height.
class TripDayBars extends StatelessWidget {
  /// One figure per day of [range], first day first
  /// (FinanceProvider.budgetSpendByDay).
  final List<double> byDay;
  final DateTimeRange range;
  final double limit;
  final double spent;
  final DateTime today;

  const TripDayBars({
    super.key,
    required this.byDay,
    required this.range,
    required this.limit,
    required this.spent,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final days = daysCovered(range.start, range.end);
    final todayIndex = daysCovered(range.start, today) - 1;
    // Days after today: all of them before the start, none after the end.
    final futureDays = (days - math.max(todayIndex + 1, 0)).clamp(0, days);
    final left = limit - spent;
    final allowance = left > 0 && futureDays > 0 ? left / futureDays : null;
    DateTime dayAt(int i) =>
        DateTime(range.start.year, range.start.month, range.start.day + i);
    String dayText(DateTime d) =>
        fmtDayRange(DateTimeRange(start: d, end: d), today);

    final semantics = StringBuffer('Spending by day');
    for (var i = 0; i < days && i <= todayIndex; i++) {
      final v = i < byDay.length ? byDay[i] : 0.0;
      semantics.write('. ${dayText(dayAt(i))} ${fmtMoneyWhole(v)}');
    }

    final step = days > 14 ? (days / 7).ceil() : 1;
    final caption = allowance == null
        ? null
        : todayIndex < 0
        ? 'Dashed: up to ${fmtMoneyWhole(allowance)} a day across the '
              '$days days'
        : futureDays == 1
        ? 'Dashed: up to ${fmtMoneyWhole(allowance)} for the last day'
        : 'Dashed: up to ${fmtMoneyWhole(allowance)} a day for the last '
              '$futureDays days';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: semantics.toString(),
          excludeSemantics: true,
          child: SizedBox(
            height: 60,
            child: CustomPaint(
              painter: _TripBarsPainter(
                byDay: byDay,
                days: days,
                todayIndex: todayIndex,
                allowance: allowance,
                bar: scheme.primary,
                stub: scheme.surfaceContainerHighest,
                dashed: scheme.outline,
                futureStub: scheme.outlineVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final slot = width / days;
              const labelWidth = 28.0;
              final inRange = todayIndex >= 0 && todayIndex < days;
              bool shown(int i) {
                if (i == todayIndex) return true;
                if (i % step != 0) return false;
                // A step label crowding today's gives way to it.
                return !inRange ||
                    (i - todayIndex).abs() * slot >= labelWidth * 0.85;
              }

              final style = text.labelSmall;
              return SizedBox(
                height: (style?.fontSize ?? 11) * 1.6,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < days; i++)
                      if (shown(i))
                        Positioned(
                          left: (slot * (i + 0.5) - labelWidth / 2).clamp(
                            0.0,
                            math.max(0.0, width - labelWidth),
                          ),
                          width: labelWidth,
                          top: 0,
                          child: Text(
                            '${dayAt(i).day}',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: i == todayIndex
                                ? style?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurface,
                                  )
                                : style?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                          ),
                        ),
                  ],
                ),
              );
            },
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(
            caption,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _TripBarsPainter extends CustomPainter {
  final List<double> byDay;
  final int days;
  final int todayIndex;
  final double? allowance;
  final Color bar;
  final Color stub;
  final Color dashed;
  final Color futureStub;

  _TripBarsPainter({
    required this.byDay,
    required this.days,
    required this.todayIndex,
    required this.allowance,
    required this.bar,
    required this.stub,
    required this.dashed,
    required this.futureStub,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (days <= 0) return;
    var top = allowance ?? 0;
    for (final v in byDay) {
      if (v > top) top = v;
    }
    if (top <= 0) top = 1;
    final slot = size.width / days;
    final gap = days <= 31 ? slot * 0.3 : 1.0;
    final barWidth = math.max(1.0, slot - gap);
    double heightOf(double v) => (v / top * size.height).clamp(0, size.height);

    final fill = Paint()..color = bar;
    final stubPaint = Paint()..color = stub;
    final futureStubPaint = Paint()..color = futureStub;
    final dash = Paint()
      ..color = dashed
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 0; i < days; i++) {
      final left = slot * i + gap / 2;
      final v = i < byDay.length ? byDay[i] : 0.0;
      if (i <= todayIndex) {
        if (v > 0) {
          final h = math.max(2.0, heightOf(v));
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left, size.height - h, barWidth, h),
              Radius.circular(math.min(4, barWidth / 2)),
            ),
            fill,
          );
        } else {
          canvas.drawRect(
            Rect.fromLTWH(left, size.height - 2, barWidth, 2),
            stubPaint,
          );
        }
      } else if (allowance case final a?) {
        final h = math.max(2.0, heightOf(a));
        _dashedRect(
          canvas,
          Rect.fromLTWH(left + 0.5, size.height - h + 0.5, barWidth - 1, h - 1),
          dash,
        );
      } else {
        canvas.drawRect(
          Rect.fromLTWH(left, size.height - 2, barWidth, 2),
          futureStubPaint,
        );
      }
    }

    if (allowance case final a?) {
      final y = size.height - heightOf(a);
      _dashedLine(canvas, Offset(0, y), Offset(size.width, y), dash);
    }
  }

  /// A 3dp on, 3dp off line from [a] to [b].
  static void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final length = (b - a).distance;
    if (length <= 0) return;
    final dir = (b - a) / length;
    for (var d = 0.0; d < length; d += 6) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + 3, length), paint);
    }
  }

  static void _dashedRect(Canvas canvas, Rect r, Paint paint) {
    if (r.width <= 0 || r.height <= 0) return;
    _dashedLine(canvas, r.topLeft, r.topRight, paint);
    _dashedLine(canvas, r.topRight, r.bottomRight, paint);
    _dashedLine(canvas, r.bottomLeft, r.bottomRight, paint);
    _dashedLine(canvas, r.topLeft, r.bottomLeft, paint);
  }

  @override
  bool shouldRepaint(_TripBarsPainter old) =>
      old.days != days ||
      old.todayIndex != todayIndex ||
      old.allowance != allowance ||
      old.bar != bar ||
      old.stub != stub ||
      old.dashed != dashed ||
      old.futureStub != futureStub ||
      !_sameDays(old.byDay, byDay);

  static bool _sameDays(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A running trip's own card above Budgets: its name, dates and days left,
/// the spend against its one limit, [TripDayBars] and a split by category.
class TripBudgetCard extends StatelessWidget {
  final SpendBudget budget;
  final double spent;
  final List<double> byDay;

  /// Spend by category, largest first (FinanceProvider.budgetBreakdownFor).
  final List<MapEntry<TxCategory, double>> breakdown;
  final DateTime today;
  final VoidCallback? onTap;

  const TripBudgetCard({
    super.key,
    required this.budget,
    required this.spent,
    required this.byDay,
    required this.breakdown,
    required this.today,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final range = budget.range!;
    final limit = budget.limit;
    final daysLeft = daysCovered(today, range.end) - 1;
    final when = daysLeft <= 0
        ? 'last day'
        : daysLeft == 1
        ? '1 day left'
        : '$daysLeft days left';
    final over = spent > limit;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return Semantics(
      container: true,
      button: onTap != null,
      child: FrostedPanel(
        radius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The pill at its own width, up to half of what the tile and
                // gaps leave, so the name keeps whatever a short pill leaves.
                LayoutBuilder(
                  builder: (context, box) => Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                        ),
                        child: Icon(
                          budgetIcon(budget),
                          size: 21,
                          color: categoryGlyphColor(context, scheme.primary),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              budget.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${fmtDayRange(range, today)} · $when',
                              style: muted,
                            ),
                          ],
                        ),
                      ),
                      if (budget.tag case final tag?) ...[
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: (box.maxWidth - 60) / 2,
                          ),
                          child: BudgetPill(
                            label: '# $tag',
                            semanticsLabel: 'Tag $tag',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: fmtMoneyWhole(spent),
                              style: const TextStyle(
                                fontSize: AppFigure.card,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: ' of ${fmtMoneyWhole(limit)}',
                              style: muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      over
                          ? '${fmtMoneyWhole(spent - limit)} over'
                          : '${fmtMoneyWhole(limit - spent)} left',
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: budgetColor(
                          context,
                          limit <= 0 ? 0 : spent / limit,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TripDayBars(
                  byDay: byDay,
                  range: range,
                  limit: limit,
                  spent: spent,
                  today: today,
                ),
                const SizedBox(height: 12),
                _CategorySplit(breakdown: breakdown),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [TripBudgetCard]'s split: an 8dp bar of category colours and a legend,
/// at most four entries (the top three plus "More categories").
class _CategorySplit extends StatelessWidget {
  final List<MapEntry<TxCategory, double>> breakdown;

  const _CategorySplit({required this.breakdown});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final counted = [
      for (final e in breakdown)
        if (e.value > 0) e,
    ];
    if (counted.isEmpty) {
      return Text(
        'Nothing counted yet.',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    final entries = <({String label, Color color, double value})>[
      for (final e in counted.take(counted.length > 4 ? 3 : 4))
        (label: e.key.label, color: e.key.color, value: e.value),
      if (counted.length > 4)
        (
          label: 'More categories',
          color: scheme.outline,
          value: counted.skip(3).fold(0.0, (s, e) => s + e.value),
        ),
    ];
    final total = entries.fold(0.0, (s, e) => s + e.value);
    final oneColumn = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.6;

    Widget legendItem(({String label, Color color, double value}) e) => Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: e.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            e.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: scheme.onSurface),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          fmtMoneyWhole(e.value),
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: math.max(
                        1,
                        (entries[i].value / total * 1000).round(),
                      ),
                      child: ColoredBox(color: entries[i].color),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 12.0;
            final width = oneColumn
                ? constraints.maxWidth
                : (constraints.maxWidth - spacing) / 2;
            return Wrap(
              spacing: spacing,
              runSpacing: 4,
              children: [
                for (final e in entries)
                  SizedBox(width: width, child: legendItem(e)),
              ],
            );
          },
        ),
      ],
    );
  }
}
