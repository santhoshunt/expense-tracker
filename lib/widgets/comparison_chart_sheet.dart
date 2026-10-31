import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../services/comparison_series.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import '../utils/haptics.dart';
import 'motion.dart';

/// The Trends comparison chart, opened from "This month vs last month" or
/// "This month vs usual": this month's spend so far (solid), the
/// Month-end forecast from today to the month's end (dashed), and the
/// month it is set against (dotted), with a "Today" tick between actual
/// and predicted. A switch flips between last month and a usual month.
/// A drag on the chart or a turn of the day dial under it picks a day and
/// shows its figures beside a guide line.
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

    // The footer of one view: the month name makes Last month's lines
    // longer than Usual's.
    List<String> linesFor(bool usual) {
      final ref = usual ? s.usual : s.lastMonth;
      double? refAt(int day) {
        if (ref == null || ref.isEmpty) return null;
        return ref[(day - 1).clamp(0, ref.length - 1)];
      }

      final refToday = refAt(s.today);
      // The month is still running on its last day: so far, not all of it.
      return <String>[
        if (s.predicted != null)
          [
            'So far ${fmtMoneyWhole(soFar)}',
            if (refToday != null)
              usual
                  ? 'usually ${fmtMoneyWhole(refToday)} by day ${s.today}'
                  : '$prevName by day ${s.today} ${fmtMoneyWhole(refToday)}',
          ].join(' · ')
        else
          'All of $monthName ${fmtMoneyWhole(soFar)}',
        [
          if (s.forecastTotal != null)
            'Forecast ${fmtMoneyWhole(s.forecastTotal!)}',
          if (ref != null && ref.isNotEmpty)
            usual
                ? 'a usual month ${fmtMoneyWhole(ref.last)}'
                : 'all of $prevName ${fmtMoneyWhole(ref.last)}',
        ].join(' · '),
      ].where((l) => l.isNotEmpty).toList();
    }

    // Both views laid out in one place, the other one invisible: the
    // switch keeps the sheet's height, and the taller view sets it.
    Widget both(Widget? Function(bool usual) part) => Stack(
      fit: StackFit.passthrough,
      children: [
        for (final v in const [false, true])
          if (part(v) case final child?)
            Visibility(
              visible: v == usual,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: child,
            ),
      ],
    );

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
        both(
          (v) => (v ? s.usual : s.lastMonth) != null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    v
                        ? 'A usual month needs two complete months on record.'
                        : '$prevName is not fully on record.',
                    style: muted,
                  ),
                ),
        ),
        const SizedBox(height: 16),
        // Outside both(): one chart, so the picked day stays through a
        // switch between Last month and Usual.
        _ScrubChart(
          series: s,
          reference: reference,
          referenceName: refName,
          usual: usual,
          prevName: prevName,
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
            // The widest of the two names holds the key's place.
            if (s.lastMonth != null || s.usual != null)
              Stack(
                children: [
                  for (final v in const [false, true])
                    if ((v ? s.usual : s.lastMonth) != null)
                      Visibility(
                        visible: v == usual,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: _LegendKey(
                          label: v ? 'Usual' : prevName,
                          color: scheme.onSurfaceVariant,
                          style: _Stroke.dotted,
                        ),
                      ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        both(
          (v) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final l in linesFor(v))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(l, style: muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The chart with a picked day: a horizontal drag or a tap on the chart, or
/// a turn of the dial under it, picks one; a tap on the Today tick puts it
/// back. The guide line, the readout bubble and the dial follow the same
/// day.
class _ScrubChart extends StatefulWidget {
  final ComparisonSeries series;
  final List<double>? reference;
  final String referenceName;
  final bool usual;
  final String prevName;

  const _ScrubChart({
    required this.series,
    required this.reference,
    required this.referenceName,
    required this.usual,
    required this.prevName,
  });

  @override
  State<_ScrubChart> createState() => _ScrubChartState();
}

class _ScrubChartState extends State<_ScrubChart> {
  /// The picked day, 1 to the month's last; null shows the plain chart.
  int? _day;

  late final FixedExtentScrollController _dial = FixedExtentScrollController(
    initialItem: widget.series.today - 1,
  );

  /// True while the code turns the dial, so its own change callback does
  /// not pick the days it passes.
  bool _moving = false;

  @override
  void dispose() {
    _dial.dispose();
    super.dispose();
  }

  void _select(int day, {required bool fromDial}) {
    if (day == _day) return;
    setState(() => _day = day);
    Haptics.tick();
    if (fromDial || !_dial.hasClients) return;
    _moving = true;
    _dial.jumpToItem(day - 1);
    _moving = false;
  }

  void _clear() {
    if (_day == null) return;
    setState(() => _day = null);
    Haptics.tick();
    if (!_dial.hasClients) return;
    _moving = true;
    final target = widget.series.today - 1;
    final duration = motionDuration(context, const Duration(milliseconds: 220));
    if (duration == Duration.zero) {
      _dial.jumpToItem(target);
      _moving = false;
    } else {
      _dial
          .animateToItem(target, duration: duration, curve: Curves.easeOutCubic)
          .whenComplete(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.series;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // An empty chart has no line to anchor a readout to, so the
        // bubble waits; the dial still follows the picked day.
        final day = _ComparisonChartPainter.maxOf(s, widget.reference) <= 0
            ? null
            : _day;
        int dayAt(Offset p) =>
            _ComparisonChartPainter.dayAt(p.dx, s.days, width);
        final gx = day == null
            ? 0.0
            : _ComparisonChartPainter.xFor(day, s.days, width);
        final onLeft = gx < width / 2;
        // The bubble flips sides to stay beside the line, but never past
        // the sheet's 20dp side padding, so a narrow screen keeps it whole.
        const bw = _ReadoutBubble.width;
        final bubbleLeft = (onLeft ? gx + 12 : gx - 12 - bw)
            .clamp(-16.0, math.max(-16.0, width + 16 - bw))
            .toDouble();
        // One Stack around the chart and the dial: a tall bubble paints
        // over the dial, not under it.
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 200,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) =>
                        _select(dayAt(d.localPosition), fromDial: false),
                    onHorizontalDragUpdate: (d) =>
                        _select(dayAt(d.localPosition), fromDial: false),
                    onTapUp: (d) {
                      final tx = _ComparisonChartPainter.xFor(
                        s.today,
                        s.days,
                        width,
                      );
                      if (s.predicted != null &&
                          _day != null &&
                          (d.localPosition.dx - tx).abs() <= 12) {
                        _clear();
                      } else {
                        _select(dayAt(d.localPosition), fromDial: false);
                      }
                    },
                    child: CustomPaint(
                      painter: _ComparisonChartPainter(
                        series: s,
                        reference: widget.reference,
                        actualColor: scheme.primary,
                        referenceColor: scheme.onSurfaceVariant,
                        gridColor: scheme.outlineVariant,
                        labelStyle: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                        referenceName: widget.referenceName,
                        selectedDay: day,
                        highlightColor: scheme.onSurface,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                _DayDial(
                  month: s.month,
                  lastDay: s.days,
                  centre: _day ?? s.today,
                  dueDays: {
                    for (final e in s.dueByDay.entries)
                      if (e.value.isNotEmpty) e.key,
                  },
                  controller: _dial,
                  onChanged: (d) {
                    if (_moving) return;
                    _select(d, fromDial: true);
                  },
                  onStep: (d) => _select(d, fromDial: false),
                ),
              ],
            ),
            if (day != null)
              Positioned(
                top: 4,
                left: bubbleLeft,
                child: _ReadoutBubble(
                  series: s,
                  day: day,
                  reference: widget.reference,
                  usual: widget.usual,
                  prevName: widget.prevName,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The picked day's figures beside the guide line: spend by then and on
/// the day, the spend items due that day, and the reference by then.
class _ReadoutBubble extends StatelessWidget {
  final ComparisonSeries series;
  final int day;
  final List<double>? reference;
  final bool usual;
  final String prevName;

  static const width = 176.0;

  const _ReadoutBubble({
    required this.series,
    required this.day,
    required this.reference,
    required this.usual,
    required this.prevName,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final orange = AppColors.of(context).orange;
    final s = series;
    final d = day;
    final predicted = s.predicted;
    final today = DateTime(s.month.year, s.month.month, s.today);

    Widget row(
      String label,
      String value, {
      TextStyle? labelStyle,
      TextStyle? valueStyle,
      Widget? lead,
    }) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (lead != null) ...[lead, const SizedBox(width: 6)],
          Expanded(child: Text(label, style: labelStyle ?? muted)),
          const SizedBox(width: 8),
          Text(value, style: valueStyle ?? text.bodyMedium),
        ],
      ),
    );

    final by = _spendBy(s, d);
    final double? thatDay;
    if (by == null) {
      thatDay = null;
    } else if (predicted == null || d < s.today) {
      thatDay = s.actual[d - 1] - (d > 1 ? s.actual[d - 2] : 0);
    } else if (d == s.today) {
      thatDay = predicted[0] - (s.today > 1 ? s.actual[s.today - 2] : 0);
    } else {
      final i = d - s.today;
      thatDay = predicted[i] - predicted[i - 1];
    }
    final due = s.dueByDay[d] ?? const <DayDue>[];
    final refAt = _referenceBy(reference, d, s.days);
    final last = d >= s.days;

    return IgnorePointer(
      child: Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              fmtDayHeading(DateTime(s.month.year, s.month.month, d)),
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (by != null) ...[
              row(
                predicted == null || d < s.today
                    ? 'Spent by then'
                    : 'Expected by then',
                fmtMoneyWhole(by),
                valueStyle: text.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              row('That day', fmtMoneyWhole(thatDay!)),
            ],
            for (final item in due.take(3))
              row(
                DateTime(
                      item.due.year,
                      item.due.month,
                      item.due.day,
                    ).isBefore(today)
                    ? '${item.label} · overdue'
                    : item.label,
                fmtMoneyWhole(item.amount),
                valueStyle: muted,
                lead: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: orange,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            if (due.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('and ${due.length - 3} more', style: muted),
              ),
            if (refAt != null)
              row(
                last
                    ? (usual ? 'A usual month' : 'All of $prevName')
                    : (usual ? 'Usually by day $d' : '$prevName by day $d'),
                fmtMoneyWhole(refAt),
              ),
            if (by == null && refAt == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('No figures after today', style: muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// A sideways dial of the month's days under a fixed pointer: weekday
/// letters over day numbers, an orange dot on days with a spend item, the
/// picked day boxed. It stops at the month's last day.
class _DayDial extends StatelessWidget {
  final DateTime month;
  final int lastDay;
  final int centre;
  final Set<int> dueDays;
  final FixedExtentScrollController controller;

  /// A turn of the dial landed on a day.
  final ValueChanged<int> onChanged;

  /// A screen reader stepped to a day; the wheel follows.
  final ValueChanged<int> onStep;

  const _DayDial({
    required this.month,
    required this.lastDay,
    required this.centre,
    required this.dueDays,
    required this.controller,
    required this.onChanged,
    required this.onStep,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final orange = AppColors.of(context).orange;
    final weekday = DateFormat('EEEEE');
    final dial = SizedBox(
      height: 60,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
            bottom: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cell = constraints.maxWidth / 11;
            return Stack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.3),
                      Colors.white,
                      Colors.white,
                      Colors.white.withValues(alpha: 0.3),
                    ],
                    stops: const [0, 0.27, 0.73, 1],
                  ).createShader(bounds),
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: ListWheelScrollView(
                      controller: controller,
                      itemExtent: cell,
                      physics: const FixedExtentScrollPhysics(),
                      diameterRatio: 1000,
                      perspective: 0.0001,
                      overAndUnderCenterOpacity: 1,
                      onSelectedItemChanged: (i) => onChanged(i + 1),
                      children: [
                        for (var d = 1; d <= lastDay; d++)
                          RotatedBox(
                            quarterTurns: 1,
                            child: ExcludeSemantics(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      weekday.format(
                                        DateTime(month.year, month.month, d),
                                      ),
                                      style: text.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    Text(
                                      '$d',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: d == centre
                                            ? scheme.onSurface
                                            : scheme.onSurfaceVariant,
                                        fontWeight: d == centre
                                            ? FontWeight.w700
                                            : null,
                                      ),
                                    ),
                                    if (dueDays.contains(d)) ...[
                                      const SizedBox(height: 3),
                                      Container(
                                        width: 5,
                                        height: 5,
                                        decoration: BoxDecoration(
                                          color: orange,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Center(
                  child: IgnorePointer(
                    child: Container(
                      width: cell + 4,
                      height: 48,
                      decoration: BoxDecoration(
                        border: Border.all(color: scheme.primary, width: 1.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -7,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Icon(
                        Icons.arrow_drop_down,
                        color: scheme.primary,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    String heading(int d) =>
        fmtDayHeading(DateTime(month.year, month.month, d));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Day',
          value: heading(centre),
          // A step action needs the value it leads to.
          increasedValue: centre < lastDay ? heading(centre + 1) : null,
          decreasedValue: centre > 1 ? heading(centre - 1) : null,
          onIncrease: centre < lastDay ? () => onStep(centre + 1) : null,
          onDecrease: centre > 1 ? () => onStep(centre - 1) : null,
          child: dial,
        ),
        const SizedBox(height: 4),
        Text(
          'Drag on the chart or turn the dial: both move the same day.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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

/// This month's spend by [day]: so far through yesterday, the forecast from
/// today on. Null after today without a forecast.
double? _spendBy(ComparisonSeries s, int day) {
  final predicted = s.predicted;
  if (predicted != null && day >= s.today) return predicted[day - s.today];
  if (day > s.today) return null;
  return s.actual[day - 1];
}

/// The reference month by [day], as its dotted line draws it: its whole
/// total on this month's last day.
double? _referenceBy(List<double>? ref, int day, int days) {
  if (ref == null || ref.isEmpty) return null;
  if (day >= days) return ref.last;
  return ref[(day - 1).clamp(0, ref.length - 1)];
}

class _ComparisonChartPainter extends CustomPainter {
  final ComparisonSeries series;
  final List<double>? reference;
  final Color actualColor;
  final Color referenceColor;
  final Color gridColor;
  final TextStyle labelStyle;
  final String referenceName;

  /// The day a drag or the dial picked, or null.
  final int? selectedDay;

  /// The ring on the selected day's marker and its bold day number.
  final Color highlightColor;

  _ComparisonChartPainter({
    required this.series,
    required this.reference,
    required this.actualColor,
    required this.referenceColor,
    required this.gridColor,
    required this.labelStyle,
    required this.referenceName,
    required this.selectedDay,
    required this.highlightColor,
  });

  static const _left = 40.0;
  static const _bottom = 18.0;
  static const _top = 14.0;

  /// The x of [day] on a chart [width] wide.
  static double xFor(int day, int days, double width) =>
      _left + (days <= 1 ? 0 : (day - 1) / (days - 1) * (width - _left));

  /// The day nearest [dx] on a chart [width] wide.
  static int dayAt(double dx, int days, double width) => days <= 1
      ? 1
      : (1 + (dx - _left) / (width - _left) * (days - 1)).round().clamp(
          1,
          days,
        );

  /// The tallest value on the chart; 0 or less draws Nothing spent yet.
  static double maxOf(ComparisonSeries series, List<double>? reference) {
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
    final max = maxOf(series, reference);
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
    double x(int day) => xFor(day, s.days, size.width);
    double y(double v) => _top + chartH - v / top * chartH;
    final sel = selectedDay;

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
      // The selected day's bold number takes the place of a close one.
      if (sel != null && (x(d) - x(sel)).abs() < 16) continue;
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

    if (sel != null) {
      final gx = x(sel);
      canvas.drawLine(
        Offset(gx, _top - 4),
        Offset(gx, _top + chartH),
        Paint()
          ..color = referenceColor
          ..strokeWidth = 1,
      );
      final refAt = _referenceBy(ref, sel, s.days);
      if (refAt != null) {
        canvas.drawCircle(
          Offset(gx, y(refAt)),
          3.5,
          Paint()..color = referenceColor,
        );
      }
      final at = _spendBy(s, sel);
      if (at != null) {
        final c = Offset(gx, y(at));
        canvas.drawCircle(c, 6, Paint()..color = actualColor);
        canvas.drawCircle(
          c,
          6,
          Paint()
            ..color = highlightColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      _text(
        canvas,
        '$sel',
        Offset(gx, size.height - _bottom + 4),
        center: true,
        style: labelStyle.copyWith(
          color: highlightColor,
          fontWeight: FontWeight.bold,
        ),
      );
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    bool center = false,
    double? rightEdge,
    TextStyle? style,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style ?? labelStyle),
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
            'Spent ${fmtMoneyWhole(soFar)} by day ${s.today}',
            if (s.forecastTotal != null)
              'forecast ${fmtMoneyWhole(s.forecastTotal!)} by month end',
            if (ref != null && ref.isNotEmpty)
              '$referenceName ${fmtMoneyWhole(ref.last)} in all',
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
      old.referenceName != referenceName ||
      old.selectedDay != selectedDay ||
      old.highlightColor != highlightColor;
}
