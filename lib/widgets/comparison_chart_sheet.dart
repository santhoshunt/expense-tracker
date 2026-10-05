import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../services/comparison_series.dart';
import '../utils/format.dart';

/// The Trends comparison chart, opened from "This month vs last month" or
/// "This month vs usual": this month's spend so far (solid), the
/// Month-end forecast from today to the month's end (dashed), and the
/// month it is set against (dotted), with a "Today" tick between actual
/// and predicted. A switch flips between last month and a usual month.
Future<void> showComparisonChartSheet(
  BuildContext context, {
  required ComparisonSeries series,
  required bool startOnUsual,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) {
      // Falls back to whichever reference exists.
      var usual = startOnUsual
          ? series.usual != null
          : series.lastMonth == null && series.usual != null;
      return StatefulBuilder(
        builder: (ctx, setState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: _ComparisonChartBody(
              series: series,
              usual: usual,
              onUsual: (v) => setState(() => usual = v),
            ),
          ),
        ),
      );
    },
  );
}

class _ComparisonChartBody extends StatelessWidget {
  final ComparisonSeries series;
  final bool usual;
  final ValueChanged<bool> onUsual;

  const _ComparisonChartBody({
    required this.series,
    required this.usual,
    required this.onUsual,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final s = series;
    final prevName = DateFormat('MMMM').format(s.previousMonth);
    final monthName = DateFormat('MMMM').format(s.month);
    final reference = usual ? s.usual : s.lastMonth;
    final refName = usual ? 'Usual' : prevName;
    final soFar = s.actual.isEmpty ? 0.0 : s.actual.last;
    // One point (the month's last day) draws no line: no Forecast key.
    final running = (s.predicted?.length ?? 0) > 1;

    double? refAt(int day) {
      final r = reference;
      if (r == null || r.isEmpty) return null;
      return r[(day - 1).clamp(0, r.length - 1)];
    }

    final refToday = refAt(s.today);
    // The month is still running on its last day: so far, not all of it.
    final lines = <String>[
      if (s.predicted != null)
        [
          'So far ${fmtMoney(soFar)}',
          if (refToday != null)
            usual
                ? 'usually ${fmtMoney(refToday)} by day ${s.today}'
                : '$prevName by day ${s.today} ${fmtMoney(refToday)}',
        ].join(' · ')
      else
        'All of $monthName ${fmtMoney(soFar)}',
      [
        if (s.forecastTotal != null) 'Forecast ${fmtMoney(s.forecastTotal!)}',
        if (reference != null && reference.isNotEmpty)
          usual
              ? 'a usual month ${fmtMoney(reference.last)}'
              : 'all of $prevName ${fmtMoney(reference.last)}',
      ].join(' · '),
    ].where((l) => l.isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('This month vs', style: text.titleLarge),
        const SizedBox(height: 10),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: false,
              label: const Text('Last month'),
              enabled: s.lastMonth != null,
            ),
            ButtonSegment(
              value: true,
              label: const Text('Usual'),
              enabled: s.usual != null,
            ),
          ],
          selected: {usual},
          onSelectionChanged: (v) => onUsual(v.first),
        ),
        if (reference == null) ...[
          const SizedBox(height: 8),
          Text(
            usual
                ? 'A usual month needs two complete months on record.'
                : '$prevName is not fully on record.',
            style: muted,
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          height: 200,
          child: CustomPaint(
            painter: _ComparisonChartPainter(
              series: s,
              reference: reference,
              actualColor: scheme.primary,
              referenceColor: scheme.onSurfaceVariant,
              gridColor: scheme.outlineVariant,
              labelStyle: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 10,
              ),
              referenceName: refName,
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _LegendKey(
              label: 'This month',
              color: scheme.primary,
              style: _Stroke.solid,
            ),
            if (running)
              _LegendKey(
                label: 'Forecast',
                color: scheme.primary,
                style: _Stroke.dashed,
              ),
            if (reference != null)
              _LegendKey(
                label: refName,
                color: scheme.onSurfaceVariant,
                style: _Stroke.dotted,
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(l, style: muted),
          ),
      ],
    );
  }
}

enum _Stroke { solid, dashed, dotted }

class _LegendKey extends StatelessWidget {
  final String label;
  final Color color;
  final _Stroke style;
  const _LegendKey({
    required this.label,
    required this.color,
    required this.style,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(
        size: const Size(18, 10),
        painter: _KeyPainter(color: color, style: style),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    ],
  );
}

class _KeyPainter extends CustomPainter {
  final Color color;
  final _Stroke style;
  _KeyPainter({required this.color, required this.style});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    _strokePolyline(
      canvas,
      [Offset(0, y), Offset(size.width, y)],
      _paintFor(color, style),
      style,
    );
  }

  @override
  bool shouldRepaint(covariant _KeyPainter old) =>
      old.color != color || old.style != style;
}

Paint _paintFor(Color color, _Stroke style) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeCap = StrokeCap.round
  ..strokeWidth = style == _Stroke.dotted ? 2 : 2.5;

/// Draws [points] as one line: solid, or in dashes or dots that run on
/// across the joins.
void _strokePolyline(
  Canvas canvas,
  List<Offset> points,
  Paint paint,
  _Stroke style,
) {
  if (points.length < 2) return;
  if (style == _Stroke.solid) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
    return;
  }
  final on = style == _Stroke.dashed ? 7.0 : 0.5;
  final off = style == _Stroke.dashed ? 5.0 : 4.5;
  var drawing = true;
  var left = on;
  for (var i = 1; i < points.length; i++) {
    var a = points[i - 1];
    final b = points[i];
    var seg = (b - a).distance;
    while (seg > 0) {
      final step = math.min(left, seg);
      final t = step / (b - a).distance;
      final next = Offset.lerp(a, b, t)!;
      if (drawing) canvas.drawLine(a, next, paint);
      a = next;
      seg -= step;
      left -= step;
      if (left <= 0) {
        drawing = !drawing;
        left = drawing ? on : off;
      }
    }
  }
}

class _ComparisonChartPainter extends CustomPainter {
  final ComparisonSeries series;
  final List<double>? reference;
  final Color actualColor;
  final Color referenceColor;
  final Color gridColor;
  final TextStyle labelStyle;
  final String referenceName;

  _ComparisonChartPainter({
    required this.series,
    required this.reference,
    required this.actualColor,
    required this.referenceColor,
    required this.gridColor,
    required this.labelStyle,
    required this.referenceName,
  });

  static const _left = 40.0;
  static const _bottom = 18.0;
  static const _top = 14.0;

  double get _max {
    var m = 0.0;
    for (final l in [series.actual, series.predicted, reference]) {
      if (l == null) continue;
      for (final v in l) {
        m = math.max(m, v);
      }
    }
    return m;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = series;
    final max = _max;
    final chartH = size.height - _bottom - _top;
    final chartW = size.width - _left;
    if (max <= 0 || chartW <= 0) {
      _text(
        canvas,
        'Nothing spent yet',
        Offset(size.width / 2, size.height / 2),
        center: true,
      );
      return;
    }
    final top = max * 1.08;
    double x(int day) =>
        _left + (s.days <= 1 ? 0 : (day - 1) / (s.days - 1) * chartW);
    double y(double v) => _top + chartH - v / top * chartH;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      final v = top * f;
      canvas.drawLine(Offset(_left, y(v)), Offset(size.width, y(v)), grid);
      _text(canvas, fmtMoneyCompact(v), Offset(0, y(v) - 6));
    }
    for (final d in {1, 10, 20, s.days}) {
      if (d > s.days) continue;
      _text(
        canvas,
        '$d',
        Offset(x(d), size.height - _bottom + 4),
        center: true,
      );
    }

    final ref = reference;
    if (ref != null && ref.isNotEmpty) {
      // Its own days, up to this month's last; a longer month's final day
      // lands on this month's last so its whole total shows.
      final n = math.min(ref.length, s.days);
      final pts = [for (var d = 1; d <= n; d++) Offset(x(d), y(ref[d - 1]))];
      if (ref.length > s.days) {
        pts[pts.length - 1] = Offset(x(s.days), y(ref.last));
      }
      _strokePolyline(
        canvas,
        pts,
        _paintFor(referenceColor, _Stroke.dotted),
        _Stroke.dotted,
      );
    }

    final predicted = s.predicted;
    if (predicted != null) {
      _strokePolyline(
        canvas,
        [for (final (i, v) in predicted.indexed) Offset(x(s.today + i), y(v))],
        _paintFor(actualColor, _Stroke.dashed),
        _Stroke.dashed,
      );
    }

    final actual = s.actual;
    _strokePolyline(
      canvas,
      [for (final (i, v) in actual.indexed) Offset(x(i + 1), y(v))],
      _paintFor(actualColor, _Stroke.solid),
      _Stroke.solid,
    );
    if (actual.isNotEmpty) {
      canvas.drawCircle(
        Offset(x(actual.length), y(actual.last)),
        3.5,
        Paint()..color = actualColor,
      );
    }

    if (predicted != null) {
      // The "|" between what happened and what is predicted.
      final tx = x(s.today);
      canvas.drawRect(
        Rect.fromLTWH(tx - 1, _top - 4, 2, chartH + 4),
        Paint()..color = referenceColor,
      );
      // Inside the chart on the month's last day, left of the tick.
      _text(canvas, 'Today', Offset(tx + 4, 0), rightEdge: size.width);
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    bool center = false,
    double? rightEdge,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
      // Axis labels keep their size: scaled up they would overlap.
      textScaler: TextScaler.noScaling,
    )..layout();
    var o = at - Offset(center ? tp.width / 2 : 0, 0);
    if (rightEdge != null && o.dx + tp.width > rightEdge) {
      o = Offset(at.dx - 8 - tp.width, o.dy);
    }
    tp.paint(canvas, o);
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final s = series;
    final soFar = s.actual.isEmpty ? 0.0 : s.actual.last;
    final ref = reference;
    return [
      CustomPainterSemantics(
        rect: Offset.zero & size,
        properties: SemanticsProperties(
          label: [
            'Spent ${fmtMoney(soFar)} by day ${s.today}',
            if (s.forecastTotal != null)
              'forecast ${fmtMoney(s.forecastTotal!)} by month end',
            if (ref != null && ref.isNotEmpty)
              '$referenceName ${fmtMoney(ref.last)} in all',
          ].join(', '),
          textDirection: TextDirection.ltr,
        ),
      ),
    ];
  };

  @override
  bool shouldRebuildSemantics(covariant _ComparisonChartPainter old) =>
      shouldRepaint(old);

  @override
  bool shouldRepaint(covariant _ComparisonChartPainter old) =>
      old.series != series ||
      !listEquals(old.reference, reference) ||
      old.actualColor != actualColor ||
      old.referenceColor != referenceColor ||
      old.gridColor != gridColor ||
      old.labelStyle != labelStyle ||
      old.referenceName != referenceName;
}
