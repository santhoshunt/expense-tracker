import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/haptics.dart';
import 'chart_popup.dart';
import 'info_tip.dart';
import 'motion.dart';

/// Income vs expense bars per month, drawn with CustomPaint to avoid a
/// charting dependency. Defaults to the six months ending at [end]; the
/// dashboard's Year view passes the twelve months of a year instead.
///
/// Tapping a month lifts its bars, dims the others and opens its income,
/// expense and net in a popup. When the figures change (another month
/// chosen), the bars ease to their new heights; the first appearance does
/// not animate. TalkBack reads each month's figures.
class MonthlyBarChart extends StatefulWidget {
  final List<DateTime>? months;

  /// Last month of the default six-month window: the dashboard's selected
  /// month, so browsing back moves the chart too. Null means the current
  /// month.
  final DateTime? end;

  /// False removes the income series entirely (Settings → Hide income):
  /// no income bars, and the scale and peak labels derive from expenses.
  /// The popup and TalkBack show the income mask instead of a figure.
  final bool showIncome;

  const MonthlyBarChart({
    super.key,
    this.months,
    this.end,
    this.showIncome = true,
  });

  /// The months drawn, oldest first.
  List<DateTime> get shownMonths {
    if (months != null) return months!;
    final last = end ?? DateTime.now();
    return List.generate(6, (i) => DateTime(last.year, last.month - (5 - i)));
  }

  @override
  State<MonthlyBarChart> createState() => _MonthlyBarChartState();
}

class _MonthlyBarChartState extends State<MonthlyBarChart>
    with TickerProviderStateMixin {
  late final AnimationController _select = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: 1,
  );

  /// The previous build's figures and the ones the running morph started
  /// from (null: nothing to ease from).
  List<_MonthData>? _last;
  List<_MonthData>? _from;
  int? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _select.duration = motionDuration(
      context,
      const Duration(milliseconds: 180),
    );
    _morph.duration = motionDuration(
      context,
      const Duration(milliseconds: 450),
    );
  }

  @override
  void dispose() {
    _select.dispose();
    _morph.dispose();
    super.dispose();
  }

  /// [data] eased from [_from], slot by slot.
  List<_MonthData> _shown(List<_MonthData> data) {
    final from = _from;
    if (from == null || _morph.value >= 1) return data;
    final t = Curves.easeOutCubic.transform(_morph.value);
    return [
      for (final (i, d) in data.indexed)
        _MonthData(
          month: d.month,
          label: d.label,
          income: lerpDouble(
            i < from.length ? from[i].income : 0,
            d.income,
            t,
          )!,
          expense: lerpDouble(
            i < from.length ? from[i].expense : 0,
            d.expense,
            t,
          )!,
        ),
    ];
  }

  Future<void> _onTap(
    TapUpDetails d,
    Size size,
    List<_MonthData> data,
    List<_MonthData> shown,
    TextStyle labelStyle,
    TextScaler scaler,
    BuildContext paintContext,
  ) async {
    if (data.isEmpty) return;
    final geo = _Geometry(size, shown, labelStyle, scaler);
    if (geo.maxVal == 0) return;
    final i = (d.localPosition.dx / geo.groupWidth).floor().clamp(
      0,
      data.length - 1,
    );
    final m = data[i];
    Haptics.tick();
    // A different month starts from flat, not from the last one's lift.
    if (_selected != i) _select.value = 0;
    setState(() => _selected = i);
    _select.forward();
    final net = m.income - m.expense;
    final hidden = !widget.showIncome;
    await showAnchoredBubble(
      context,
      anchor: chartAnchor(paintContext, geo.top(i)),
      maxWidth: kChartPopupWidth,
      content: (_) => ChartPopup(
        title: DateFormat('MMMM yyyy').format(m.month),
        rows: [
          ('Income', hidden ? kMaskedAmount : fmtMoney(m.income)),
          ('Expense', fmtMoney(m.expense)),
          (
            'Net',
            hidden
                ? kMaskedAmount
                : net >= 0
                ? '+${fmtMoney(net)}'
                : '−${fmtMoney(-net)}',
          ),
        ],
        host: context,
      ),
    );
    if (!mounted || _selected != i) return;
    await _select.reverse();
    if (mounted && _selected == i && _select.value == 0) {
      setState(() => _selected = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    // Full figures: the popup and TalkBack need real income even though the
    // bars drop it when hidden.
    final data = [
      for (final m in widget.shownMonths)
        _MonthData(
          month: m,
          label: DateFormat('MMM').format(m),
          income: finance.incomeInMonth(m),
          expense: finance.expenseInMonth(m),
        ),
    ];
    final drawn = [
      for (final d in data)
        widget.showIncome
            ? d
            : _MonthData(
                month: d.month,
                label: d.label,
                income: 0,
                expense: d.expense,
              ),
    ];
    final last = _last;
    if (last != null && !listEquals(last, drawn)) {
      // Ease from whatever is on screen now, even mid-morph.
      _from = _shown(last);
      _morph.forward(from: 0);
      if (_selected != null && _selected! >= drawn.length) _selected = null;
    }
    _last = drawn;

    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall!;
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: 180,
      child: LayoutBuilder(
        builder: (paintContext, constraints) => AnimatedBuilder(
          animation: Listenable.merge([_select, _morph]),
          builder: (context, _) {
            final shown = _shown(drawn);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onTap(
                d,
                constraints.biggest,
                data,
                shown,
                labelStyle,
                scaler,
                paintContext,
              ),
              child: CustomPaint(
                size: Size.infinite,
                painter: _BarChartPainter(
                  data: shown,
                  spoken: data,
                  showIncome: widget.showIncome,
                  selected: _selected,
                  lift: Curves.easeOutCubic.transform(_select.value),
                  incomeColor: AppColors.of(context).green,
                  expenseColor: theme.colorScheme.error,
                  labelStyle: labelStyle,
                  // Painted text bypasses widget-level scaling; honour it
                  // explicitly.
                  textScaler: scaler,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MonthData {
  final DateTime month;
  final String label;
  final double income;
  final double expense;
  const _MonthData({
    required this.month,
    required this.label,
    required this.income,
    required this.expense,
  });

  // Value equality so shouldRepaint can actually short-circuit: the data list
  // is rebuilt every build, so identity comparison was always unequal and the
  // chart repainted unconditionally.
  @override
  bool operator ==(Object other) =>
      other is _MonthData &&
      other.month == month &&
      other.label == label &&
      other.income == income &&
      other.expense == expense;

  @override
  int get hashCode => Object.hash(month, label, income, expense);
}

/// Where the painter puts things, shared with hit-testing so a tap lands on
/// the month under the finger.
class _Geometry {
  final Size size;
  final List<_MonthData> data;
  late final double labelHeight;
  late final double chartHeight;
  late final double maxVal;
  late final double groupWidth;

  _Geometry(this.size, this.data, TextStyle labelStyle, TextScaler scaler) {
    // The label strip must scale with the user's font size — a constant
    // 22dp let month labels run into the legend below past ~1.6× scale.
    labelHeight = scaler.scale(labelStyle.fontSize ?? 12) * 1.4 + 6;
    chartHeight = size.height - labelHeight;
    maxVal = data
        .expand((d) => [d.income, d.expense])
        .fold(0.0, (m, v) => v > m ? v : m);
    groupWidth = size.width / data.length;
  }

  double centerX(int i) => groupWidth * i + groupWidth / 2;

  double heightOf(double value) =>
      maxVal == 0 ? 0 : (value / maxVal) * (chartHeight - 8);

  /// The top of month [i]'s taller bar.
  Offset top(int i) {
    final d = data[i];
    return Offset(
      centerX(i),
      chartHeight - heightOf(d.income > d.expense ? d.income : d.expense),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  final List<_MonthData> data;

  /// The real figures, for TalkBack (income included even when hidden).
  final List<_MonthData> spoken;
  final bool showIncome;
  final int? selected;

  /// 0 to 1: how far the [selected] month has lifted and the rest dimmed.
  final double lift;
  final Color incomeColor;
  final Color expenseColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  _BarChartPainter({
    required this.data,
    required this.spoken,
    required this.showIncome,
    required this.selected,
    required this.lift,
    required this.incomeColor,
    required this.expenseColor,
    required this.labelStyle,
    this.textScaler = TextScaler.noScaling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final geo = _Geometry(size, data, labelStyle, textScaler);
    final chartHeight = geo.chartHeight;
    final maxVal = geo.maxVal;

    if (maxVal == 0) {
      _paintText(
        canvas,
        'No transactions in these months',
        Offset(size.width / 2, size.height / 2),
        center: true,
        // Both axes: `center` alone is horizontal, which left the text's
        // TOP at mid-height — visibly low, and a wrapped message could run
        // past the chart box over the legend.
        vCenter: true,
        // Wrap inside the chart instead of running past it on narrow phones.
        maxWidth: size.width,
      );
      return;
    }

    final groupWidth = geo.groupWidth;
    final barWidth = (groupWidth * 0.28).clamp(6.0, 26.0);
    final gap = 4.0;

    for (var i = 0; i < data.length; i++) {
      final d = data[i];
      final cx = geo.centerX(i);
      final isSelected = i == selected;
      final up = isSelected ? 4 * lift : 0.0;
      final alpha = selected == null || isSelected
          ? 1.0
          : lerpDouble(1, 0.3, lift)!;

      void bar(double value, double xOffset, Color color) {
        if (value <= 0) return; // no zero-height rounded-rect sliver
        final h = geo.heightOf(value);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(cx + xOffset, chartHeight - h - up, barWidth, h),
          const Radius.circular(4),
        );
        canvas.drawRRect(
          rect,
          Paint()..color = color.withValues(alpha: color.a * alpha),
        );
      }

      bar(d.income, -barWidth - gap / 2, incomeColor);
      bar(d.expense, gap / 2, expenseColor);

      _paintText(canvas, d.label, Offset(cx, chartHeight + 4), center: true);

      final peak = d.income > d.expense ? d.income : d.expense;
      if (peak > 0) {
        final h = geo.heightOf(peak);
        _paintText(
          canvas,
          fmtMoneyCompact(peak),
          Offset(cx, chartHeight - h - 14 - up),
          center: true,
          small: true,
        );
      }
    }

    // Baseline
    canvas.drawLine(
      Offset(0, chartHeight),
      Offset(size.width, chartHeight),
      Paint()
        ..color = labelStyle.color!.withValues(alpha: 0.2)
        ..strokeWidth = 1,
    );
  }

  /// [center] centres horizontally on [at]; [vCenter] centres vertically
  /// too (TextPainter.paint treats the offset as the TOP-left otherwise —
  /// the bar labels rely on that, the empty-state message must not).
  void _paintText(
    Canvas canvas,
    String text,
    Offset at, {
    bool center = false,
    bool vCenter = false,
    bool small = false,
    double? maxWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: small ? labelStyle.copyWith(fontSize: 10) : labelStyle,
      ),
      textAlign: center ? TextAlign.center : TextAlign.left,
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth ?? double.infinity);
    tp.paint(
      canvas,
      at - Offset(center ? tp.width / 2 : 0, vCenter ? tp.height / 2 : 0),
    );
  }

  /// One node per month, so TalkBack can read what the bars show.
  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    if (spoken.isEmpty) return const [];
    final groupWidth = size.width / spoken.length;
    return [
      for (final (i, d) in spoken.indexed)
        CustomPainterSemantics(
          rect: Rect.fromLTWH(groupWidth * i, 0, groupWidth, size.height),
          properties: SemanticsProperties(
            label:
                '${DateFormat('MMMM yyyy').format(d.month)}: income '
                '${showIncome ? fmtMoney(d.income) : 'hidden'}, expense '
                '${fmtMoney(d.expense)}',
            textDirection: TextDirection.ltr,
          ),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(covariant _BarChartPainter old) =>
      !listEquals(old.spoken, spoken) || old.showIncome != showIncome;

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      !listEquals(old.data, data) ||
      old.selected != selected ||
      old.lift != lift ||
      old.textScaler != textScaler ||
      old.incomeColor != incomeColor ||
      old.expenseColor != expenseColor ||
      old.labelStyle != labelStyle;
}
