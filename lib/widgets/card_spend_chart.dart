import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/card_rewards.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../screens/app_nav.dart';
import '../screens/transactions_screen.dart' show TxFilterRequest;
import '../services/card_rewards.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/haptics.dart';
import '../utils/money_colors.dart';
import 'info_tip.dart';

/// A credit card tile's spending: "Spent this cycle" (or this month) with
/// its tip, a Month or Cycle toggle on a card with a statement day, the
/// current cycle's dates, a readout of the chosen period that opens its
/// payments, six bars of periods, a caption and Older or Newer buttons.
/// Every figure counts rows by the date they happened.
class CardSpendSection extends StatefulWidget {
  final Account account;

  /// Opens this card's transactions (the Spent tip's link).
  final void Function(String accountId) onView;

  const CardSpendSection({
    super.key,
    required this.account,
    required this.onView,
  });

  @override
  State<CardSpendSection> createState() => _CardSpendSectionState();
}

class _CardSpendSectionState extends State<CardSpendSection> {
  bool _byMonth = false;
  int _skip = 0;
  int? _selectedBack;

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final a = widget.account;
    final hasCycle = a.statementDay != null;
    final byMonth = _byMonth && hasCycle;
    final basis = byMonth ? a.copyWith(clearStatementDay: true) : a;
    final w = finance.cardSpendWindow(basis, skip: _skip);
    final monthWords = basis.statementDay == null;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final spendColor = moneyColor(context, type: TxType.expense);
    final headline = monthWords ? 'Spent this month' : 'Spent this cycle';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: InfoLabel(
                // The label muted, the figure red: it is money out.
                label: Text.rich(
                  TextSpan(
                    text: '$headline ',
                    children: [
                      TextSpan(
                        text: fmtMoney(w.current.spent),
                        style: TextStyle(
                          color: spendColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  style: muted,
                ),
                tip: InfoTip(
                  title: headline,
                  message: monthWords
                      ? 'Spending on this card in the current calendar month, '
                            'by the date each payment happened, whatever month '
                            'the dashboard shows. Transfers are left out.'
                      : 'Spending on this card from the day after its last '
                            'statement to its next statement day, by the date '
                            'each payment happened. Transfers are left out.',
                  link: InfoLink(
                    prompt: 'See what makes it up?',
                    label: "This card's transactions",
                    onTap: (_) => widget.onView(a.id),
                  ),
                ),
              ),
            ),
            if (hasCycle) ...[
              const SizedBox(width: 8),
              _PeriodToggle(
                byMonth: _byMonth,
                onChanged: (v) => setState(() {
                  _byMonth = v;
                  _skip = 0;
                  _selectedBack = null;
                }),
              ),
            ],
          ],
        ),
        if (!a.isClosed) ...[
          const SizedBox(height: 2),
          Text(
            '${fmtDayRange(DateTimeRange(start: w.current.cycle.start, end: w.current.cycle.end), DateTime.now())} · day ${w.day} of ${w.days}',
            style: muted,
          ),
        ],
        if (finance.transactionCountForAccount(a.id) > 0)
          ..._history(context, w, a, monthWords, byMonth, muted, spendColor),
      ],
    );
  }

  /// The readout, the bars, the caption and the Older or Newer buttons.
  List<Widget> _history(
    BuildContext context,
    CardSpendWindow w,
    Account a,
    bool monthWords,
    bool byMonth,
    TextStyle muted,
    Color spendColor,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final newest = w.bars.last.back;
    final sel = _selectedBack ?? (newest == 0 ? 1 : newest);
    var selectedIndex = w.bars.indexWhere((q) => q.back == sel);
    if (selectedIndex < 0) selectedIndex = w.bars.length - 1;
    final p = w.bars[selectedIndex];
    final runningIndex = w.bars.indexWhere((q) => q.back == 0);
    String rangeText(CardPeriod q) => monthWords
        ? fmtMonth(q.cycle.start)
        : fmtDayRange(
            DateTimeRange(start: q.cycle.start, end: q.cycle.end),
            DateTime.now(),
          );
    final unit = monthWords ? 'months' : 'cycles';

    void select(int i) {
      Haptics.tick();
      setState(() => _selectedBack = w.bars[i].back);
    }

    void page(int by) => setState(() {
      _skip += by;
      _selectedBack = null;
    });

    String? rewardText() {
      final r = p.rewards;
      // A Month view of a card with a statement day does not line up with
      // its reward cycle; a card with no statement day earns by month.
      if (byMonth || r == null) return null;
      final approx = p.back == 0 ? '≈ ' : '';
      return a.rewards?.unit == RewardUnit.points
          ? ' · $approx${fmtPoints(r.earned)}'
          : ' · cashback $approx${fmtMoneyWhole(r.earned)}';
    }

    final rewards = rewardText();
    final lead = _skip == 0 ? 'Last 6' : '6 earlier';
    const tap = 'Tap a bar for its total, then the readout for its payments.';
    final d = a.statementDay;
    final String caption;
    if (d == null) {
      caption = '$lead months. $tap';
    } else if (byMonth) {
      caption =
          '$lead calendar months. $tap Cycle shows the last 6 statement '
          'cycles.';
    } else {
      caption =
          '$lead cycles, each ending on the ${_ordinal(d)}'
          "${d >= 29 ? " or the month's last day" : ''}. $tap Month shows "
          'the last 6 calendar months.';
    }

    return [
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: () => AppNav.instance.openTransactions(
            context,
            TxFilterRequest(
              type: TxType.expense,
              accountId: a.id,
              range: DateTimeRange(start: p.cycle.start, end: p.cycle.end),
              rangeLabel: monthWords
                  ? fmtMonth(p.cycle.start)
                  : 'Cycle ${rangeText(p)}',
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          text: rangeText(p),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                          children: [
                            TextSpan(
                              text: p.payments == 1
                                  ? ' · 1 payment'
                                  : ' · ${p.payments} payments',
                              style: muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                Text.rich(
                  TextSpan(
                    text: 'Spent ',
                    children: [
                      TextSpan(
                        text: fmtMoneyWhole(p.spent),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: p.spent > 0 ? spendColor : scheme.onSurface,
                        ),
                      ),
                      if (rewards != null) TextSpan(text: rewards),
                    ],
                  ),
                  style: muted,
                ),
              ],
            ),
          ),
        ),
      ),
      SizedBox(
        height: 104,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final count = w.bars.length;
            final painter = _CardBarsPainter(
              values: [for (final q in w.bars) q.spent],
              labels: [
                for (final q in w.bars)
                  q.back == 0
                      ? 'Now'
                      : monthWords
                      ? DateFormat('MMM').format(q.cycle.start)
                      : fmtDateCompact(q.cycle.end),
              ],
              spoken: [
                for (final q in w.bars)
                  '${rangeText(q)}: spent ${fmtMoneyWhole(q.spent)}',
              ],
              selected: selectedIndex,
              running: runningIndex < 0 ? null : runningIndex,
              spendColor: scheme.error,
              runningColor: scheme.primary,
              outlineColor: scheme.onSurface,
              labelStyle: (text.bodySmall ?? const TextStyle()).copyWith(
                fontSize: 10,
                color: scheme.onSurfaceVariant,
              ),
              textScaler: MediaQuery.textScalerOf(context),
              emptyText: 'No spending in these $unit',
              onTapBar: select,
            );
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                if (width <= 0 || count == 0) return;
                select(painter.indexAt(details.localPosition.dx, width));
              },
              child: CustomPaint(size: Size(width, 104), painter: painter),
            );
          },
        ),
      ),
      const SizedBox(height: 4),
      Text(caption, style: muted),
      if (w.hasOlder || _skip > 0)
        Row(
          children: [
            if (w.hasOlder)
              TextButton(
                onPressed: () => page(6),
                child: Text(monthWords ? 'Older months' : 'Older cycles'),
              ),
            const Spacer(),
            if (_skip > 0)
              TextButton(
                onPressed: () => page(-6),
                child: Text(monthWords ? 'Newer months' : 'Newer cycles'),
              ),
          ],
        ),
    ];
  }
}

/// "1st", "2nd", "3rd", "11th", "15th", "22nd".
String _ordinal(int n) {
  final teen = n % 100;
  if (teen >= 11 && teen <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// The largest 1, 2 or 5 times a power of ten not above [max]; 0 below 1,
/// where no gridline is drawn.
double _gridValue(double max) {
  if (max < 1) return 0;
  var power = 1.0;
  while (power * 10 <= max) {
    power *= 10;
  }
  for (final m in const [5, 2]) {
    if (power * m <= max) return power * m;
  }
  return power;
}

/// Month then Cycle, the chosen one outlined in the accent colour with no
/// fill.
class _PeriodToggle extends StatelessWidget {
  final bool byMonth;
  final ValueChanged<bool> onChanged;

  const _PeriodToggle({required this.byMonth, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.control);

    Widget segment(String label, bool month) {
      final selected = byMonth == month;
      return Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          borderRadius: radius,
          onTap: selected
              ? null
              : () {
                  Haptics.tick();
                  onChanged(month);
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: selected
                ? BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: scheme.primary, width: 1.5),
                  )
                : null,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [segment('Month', true), segment('Cycle', false)],
        ),
      ),
    );
  }
}

/// Six period bars, oldest first: past bars in the spend colour, the
/// running period dashed in the accent colour, the selected bar outlined.
class _CardBarsPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final List<String> spoken;
  final int selected;
  final int? running;
  final Color spendColor;
  final Color runningColor;
  final Color outlineColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;
  final String emptyText;
  final ValueChanged<int> onTapBar;

  _CardBarsPainter({
    required this.values,
    required this.labels,
    required this.spoken,
    required this.selected,
    required this.running,
    required this.spendColor,
    required this.runningColor,
    required this.outlineColor,
    required this.labelStyle,
    required this.textScaler,
    required this.emptyText,
    required this.onTapBar,
  });

  double _labelHeight() => textScaler.scale(10) * 1.4 + 6;

  double get _top => values.fold(0.0, (m, v) => math.max(m, v));

  /// The gridline's value label, or null when no gridline is drawn.
  TextPainter? _gridLabel() {
    final grid = _gridValue(_top);
    return grid > 0 ? _text(fmtMoneyCompact(grid), labelStyle) : null;
  }

  /// Each bar's slot: the gridline label keeps a gutter at the right, so
  /// it never sits on a bar.
  double _slot(double width) {
    final label = _gridLabel();
    final gutter = label == null ? 0.0 : label.width + 4;
    return math.max(0.0, width - gutter) / values.length;
  }

  /// The bar under [dx] on a chart [width] wide.
  int indexAt(double dx, double width) {
    final slot = _slot(width);
    if (slot <= 0) return values.length - 1;
    return (dx / slot).floor().clamp(0, values.length - 1);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final count = values.length;
    if (count == 0 || size.width <= 0) return;
    final labelHeight = _labelHeight();
    final chartHeight = size.height - labelHeight;
    final slot = _slot(size.width);
    final barWidth = math.min(slot * 0.6, 36.0);
    final top = _top;
    final room = math.max(0.0, chartHeight - 14);

    final baseline = Paint()
      ..color = outlineColor.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, chartHeight),
      Offset(size.width, chartHeight),
      baseline,
    );

    if (top > 0) {
      final grid = _gridValue(top);
      if (grid > 0) {
        final y = chartHeight - grid / top * room;
        final dash = Paint()
          ..color = outlineColor.withValues(alpha: 0.2)
          ..strokeWidth = 1;
        for (var x = 0.0; x < size.width; x += 7) {
          canvas.drawLine(
            Offset(x, y),
            Offset(math.min(x + 3, size.width), y),
            dash,
          );
        }
        final tp = _gridLabel()!;
        tp.paint(canvas, Offset(size.width - tp.width, y - tp.height - 1));
      }
    }

    for (var i = 0; i < count; i++) {
      final v = values[i];
      final left = slot * i + (slot - barWidth) / 2;
      if (top > 0 && v > 0) {
        final h = math.max(2.0, v / top * room);
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, chartHeight - h, barWidth, h),
          const Radius.circular(5),
        );
        final isRunning = i == running;
        final isSelected = i == selected;
        if (isRunning) {
          canvas.drawRRect(
            rrect,
            Paint()..color = runningColor.withValues(alpha: 0.35),
          );
          final stroke = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = isSelected ? outlineColor : runningColor;
          if (isSelected) {
            canvas.drawRRect(rrect, stroke);
          } else {
            _dashedPath(canvas, Path()..addRRect(rrect), stroke);
          }
        } else {
          canvas.drawRRect(
            rrect,
            Paint()
              ..color = isSelected
                  ? spendColor
                  : spendColor.withValues(alpha: 0.45),
          );
          if (isSelected) {
            canvas.drawRRect(
              rrect,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5
                ..color = outlineColor,
            );
          }
        }
      }

      final tp = _text(
        labels[i],
        i == selected ? labelStyle.copyWith(color: outlineColor) : labelStyle,
      );
      if (tp.width <= slot) {
        tp.paint(
          canvas,
          Offset(slot * i + (slot - tp.width) / 2, chartHeight + 4),
        );
      }
    }

    if (top <= 0) {
      final tp = _text(emptyText, labelStyle.copyWith(fontSize: 12));
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, (chartHeight - tp.height) / 2),
      );
    }
  }

  TextPainter _text(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();

  /// [path] stroked 4dp on, 3dp off.
  static void _dashedPath(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 7) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final count = values.length;
    if (count == 0) return const [];
    final slot = _slot(size.width);
    return [
      for (var i = 0; i < count; i++)
        CustomPainterSemantics(
          rect: Rect.fromLTWH(slot * i, 0, slot, size.height),
          properties: SemanticsProperties(
            label: spoken[i],
            button: true,
            selected: i == selected,
            onTap: () => onTapBar(i),
            textDirection: TextDirection.ltr,
          ),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(covariant _CardBarsPainter old) =>
      shouldRepaint(old);

  @override
  bool shouldRepaint(covariant _CardBarsPainter old) =>
      !listEquals(old.values, values) ||
      !listEquals(old.labels, labels) ||
      !listEquals(old.spoken, spoken) ||
      old.selected != selected ||
      old.running != running ||
      old.spendColor != spendColor ||
      old.runningColor != runningColor ||
      old.outlineColor != outlineColor ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler ||
      old.emptyText != emptyText;
}
