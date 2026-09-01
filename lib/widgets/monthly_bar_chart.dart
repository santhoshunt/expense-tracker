import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';

/// Income vs expense bars for the last six months, drawn with CustomPaint
/// to avoid a charting dependency.
class MonthlyBarChart extends StatelessWidget {
  const MonthlyBarChart({super.key});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final now = DateTime.now();
    final months = List.generate(
      6,
      (i) => DateTime(now.year, now.month - (5 - i)),
    );
    final data = months
        .map(
          (m) => _MonthData(
            label: DateFormat('MMM').format(m),
            income: finance.incomeInMonth(m),
            expense: finance.expenseInMonth(m),
          ),
        )
        .toList();

    return SizedBox(
      height: 180,
      child: CustomPaint(
        size: Size.infinite,
        painter: _BarChartPainter(
          data: data,
          incomeColor: AppColors.of(context).green,
          expenseColor: Theme.of(context).colorScheme.error,
          labelStyle: Theme.of(context).textTheme.bodySmall!,
          // Painted text bypasses widget-level scaling; honour it explicitly.
          textScaler: MediaQuery.textScalerOf(context),
        ),
      ),
    );
  }
}

class _MonthData {
  final String label;
  final double income;
  final double expense;
  const _MonthData({
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
      other.label == label &&
      other.income == income &&
      other.expense == expense;

  @override
  int get hashCode => Object.hash(label, income, expense);
}

class _BarChartPainter extends CustomPainter {
  final List<_MonthData> data;
  final Color incomeColor;
  final Color expenseColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  _BarChartPainter({
    required this.data,
    required this.incomeColor,
    required this.expenseColor,
    required this.labelStyle,
    this.textScaler = TextScaler.noScaling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The label strip must scale with the user's font size — a constant
    // 22dp let month labels run into the legend below past ~1.6× scale.
    final labelHeight = textScaler.scale(labelStyle.fontSize ?? 12) * 1.4 + 6;
    final chartHeight = size.height - labelHeight;
    final maxVal = data
        .expand((d) => [d.income, d.expense])
        .fold(0.0, (m, v) => v > m ? v : m);

    if (maxVal == 0) {
      _paintText(
        canvas,
        'No data yet — add a transaction to see trends',
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

    final groupWidth = size.width / data.length;
    final barWidth = (groupWidth * 0.28).clamp(6.0, 26.0);
    final gap = 4.0;

    for (var i = 0; i < data.length; i++) {
      final d = data[i];
      final cx = groupWidth * i + groupWidth / 2;

      void bar(double value, double xOffset, Color color) {
        final h = (value / maxVal) * (chartHeight - 8);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(cx + xOffset, chartHeight - h, barWidth, h),
          const Radius.circular(4),
        );
        canvas.drawRRect(rect, Paint()..color = color);
      }

      bar(d.income, -barWidth - gap / 2, incomeColor);
      bar(d.expense, gap / 2, expenseColor);

      _paintText(canvas, d.label, Offset(cx, chartHeight + 4), center: true);

      final peak = d.income > d.expense ? d.income : d.expense;
      if (peak > 0) {
        final h = (peak / maxVal) * (chartHeight - 8);
        _paintText(
          canvas,
          fmtMoneyCompact(peak),
          Offset(cx, chartHeight - h - 14),
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

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      !listEquals(old.data, data) ||
      old.textScaler != textScaler ||
      old.incomeColor != incomeColor ||
      old.expenseColor != expenseColor ||
      old.labelStyle != labelStyle;
}
