import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../utils/format.dart';
import '../utils/haptics.dart';
import 'chart_popup.dart';
import 'info_tip.dart';
import 'motion.dart';

/// Donut chart of spending by category, drawn with CustomPaint (no chart
/// dependency), with a wrap legend below.
///
/// Tapping a slice lifts it, dims the rest and opens its figures in a popup.
/// When the figures change (another month), the slices ease from the old
/// shares to the new ones; the first appearance does not animate.
class CategoryDonutChart extends StatefulWidget {
  final List<MapEntry<TxCategory, double>> data;

  /// Tapping a legend entry deep-links to that category's transactions —
  /// for sub-degree slices the legend is the only usable target. The slice
  /// popup offers the same link.
  final void Function(String categoryId)? onCategoryTap;

  /// Shown instead of the chart when nothing was spent.
  final String emptyText;

  const CategoryDonutChart({
    super.key,
    required this.data,
    this.onCategoryTap,
    this.emptyText = 'No spending this month',
  });

  @override
  State<CategoryDonutChart> createState() => _CategoryDonutChartState();
}

/// One slice as painted: its category id, colour, and where it sits on the
/// ring (radians clockwise from the top), possibly mid-morph.
typedef _Slice = ({String id, Color color, double start, double sweep});

const _stroke = 26.0;

class _CategoryDonutChartState extends State<CategoryDonutChart>
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

  /// Slices at the start of the running morph (empty: nothing to ease from).
  List<_Slice> _from = const [];
  String? _selected;

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
  void didUpdateWidget(CategoryDonutChart old) {
    super.didUpdateWidget(old);
    if (_sameValues(old.data, widget.data)) return;
    // Ease from whatever is on screen now, even mid-morph.
    _from = _slicesAt(_colorsFor(old.data), old.data);
    _morph.forward(from: 0);
    if (_selected != null && !widget.data.any((e) => e.key.id == _selected)) {
      _selected = null;
      _select.value = 0;
    }
  }

  static bool _sameValues(
    List<MapEntry<TxCategory, double>> a,
    List<MapEntry<TxCategory, double>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key.id != b[i].key.id || a[i].value != b[i].value) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _select.dispose();
    _morph.dispose();
    super.dispose();
  }

  /// Slice colours with duplicates nudged apart: the 8-colour palette across
  /// arbitrarily many categories means two slices can render identically,
  /// leaving the donut and its legend ambiguous. Duplicates shift stepwise
  /// toward white (dark theme) or black (light theme), same rule for arc and
  /// legend dot so they always match. Ranked by id, not position, so a
  /// category keeps its shade when the order changes between months.
  List<Color> _colorsFor(List<MapEntry<TxCategory, double>> data) {
    final toward = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final byColor = <int, List<String>>{};
    for (final e in data) {
      (byColor[e.key.color.toARGB32()] ??= []).add(e.key.id);
    }
    for (final ids in byColor.values) {
      ids.sort();
    }
    return [
      for (final e in data)
        switch (byColor[e.key.color.toARGB32()]!.indexOf(e.key.id)) {
          0 => e.key.color,
          final n => Color.lerp(e.key.color, toward, math.min(0.18 * n, 0.45))!,
        },
    ];
  }

  /// [data] laid round the ring, largest share first.
  static List<_Slice> _layout(
    List<Color> colors,
    List<MapEntry<TxCategory, double>> data,
  ) {
    final total = data.fold(0.0, (s, e) => s + e.value);
    final slices = <_Slice>[];
    if (total <= 0) return slices;
    var start = 0.0;
    for (final (i, e) in data.indexed) {
      final sweep = e.value / total * 2 * math.pi;
      slices.add((id: e.key.id, color: colors[i], start: start, sweep: sweep));
      start += sweep;
    }
    return slices;
  }

  /// What is on screen: [data]'s layout eased from [_from]. Each category
  /// moves and resizes from where it was, so a change of order slides
  /// slices round instead of jumping; a new one grows in place and a gone
  /// one shrinks where it stood.
  List<_Slice> _slicesAt(
    List<Color> colors,
    List<MapEntry<TxCategory, double>> data,
  ) {
    final target = _layout(colors, data);
    final t = Curves.easeOutCubic.transform(_morph.value);
    if (_from.isEmpty || t >= 1) return target;
    final from = {for (final s in _from) s.id: s};
    final ids = {for (final s in target) s.id};
    return [
      for (final s in target)
        switch (from[s.id]) {
          final f? => (
            id: s.id,
            color: s.color,
            start: lerpDouble(f.start, s.start, t)!,
            sweep: lerpDouble(f.sweep, s.sweep, t)!,
          ),
          null => (
            id: s.id,
            color: s.color,
            start: s.start,
            sweep: s.sweep * t,
          ),
        },
      for (final f in _from)
        if (!ids.contains(f.id))
          (id: f.id, color: f.color, start: f.start, sweep: f.sweep * (1 - t)),
    ];
  }

  Future<void> _onTap(
    TapUpDetails d,
    Size size,
    List<_Slice> slices,
    BuildContext paintContext,
  ) async {
    if (slices.isEmpty) return;
    final center = size.center(Offset.zero);
    final mid = math.min(size.width, size.height) / 2 - 8 - _stroke / 2;
    final v = d.localPosition - center;
    // Only the ring itself (with a little slack), not its hole or corners.
    if ((v.distance - mid).abs() > _stroke / 2 + 10) return;
    var angle = math.atan2(v.dy, v.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    for (final s in slices) {
      if (angle >= s.start && angle < s.start + s.sweep) {
        await _open(s, s.start + s.sweep / 2, mid, center, paintContext);
        return;
      }
    }
  }

  Future<void> _open(
    _Slice slice,
    double midAngle,
    double mid,
    Offset center,
    BuildContext paintContext,
  ) async {
    final entry = widget.data.where((e) => e.key.id == slice.id).firstOrNull;
    if (entry == null) return;
    final total = widget.data.fold(0.0, (s, e) => s + e.value);
    final share = total <= 0 ? 0 : entry.value / total * 100;
    Haptics.tick();
    // A different slice starts from flat, not from the last one's lift.
    if (_selected != slice.id) _select.value = 0;
    setState(() => _selected = slice.id);
    _select.forward();
    final dir = Offset(
      math.cos(midAngle - math.pi / 2),
      math.sin(midAngle - math.pi / 2),
    );
    final onTap = widget.onCategoryTap;
    await showAnchoredBubble(
      context,
      anchor: chartAnchor(paintContext, center + dir * (mid + _stroke / 2)),
      maxWidth: kChartPopupWidth,
      content: (_) => ChartPopup(
        title: entry.key.label,
        swatch: slice.color,
        headline: fmtMoney(entry.value),
        footnote: '${share.toStringAsFixed(0)}% of spending',
        link: onTap == null
            ? null
            : InfoLink(
                label: 'See transactions',
                onTap: (_) => onTap(entry.key.id),
              ),
        host: context,
      ),
    );
    if (!mounted || _selected != slice.id) return;
    await _select.reverse();
    if (mounted && _selected == slice.id && _select.value == 0) {
      setState(() => _selected = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final total = data.fold(0.0, (s, e) => s + e.value);
    if (total <= 0) {
      return SizedBox(
        height: 160,
        child: Center(child: Text(widget.emptyText)),
      );
    }
    final colors = _colorsFor(data);
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 180,
          child: LayoutBuilder(
            builder: (paintContext, constraints) {
              final size = constraints.biggest;
              return AnimatedBuilder(
                animation: Listenable.merge([_select, _morph]),
                builder: (context, _) {
                  final slices = _slicesAt(colors, data);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _onTap(d, size, slices, paintContext),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _DonutPainter(
                        slices: slices,
                        selected: _selected,
                        lift: Curves.easeOutCubic.transform(_select.value),
                        centerLabel: fmtMoneyCompact(total),
                        centerStyle: theme.textTheme.titleMedium!.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        subStyle: theme.textTheme.bodySmall!,
                        // Painted text bypasses widget-level scaling; honour
                        // it.
                        textScaler: MediaQuery.textScalerOf(context),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final (i, e) in data.indexed)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onCategoryTap == null
                    ? null
                    : () => widget.onCategoryTap!(e.key.id),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colors[i],
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    // Flexible: Wrap bounds the row's width, and a single
                    // legend entry wider than the card is otherwise a
                    // guaranteed RenderFlex overflow (long custom labels at
                    // large font scale).
                    Flexible(
                      child: Text(
                        '${e.key.label} '
                        '${(e.value / total * 100).toStringAsFixed(0)}%',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_Slice> slices;
  final String? selected;

  /// 0 to 1: how far the [selected] slice has lifted and the rest dimmed.
  final double lift;
  final String centerLabel;
  final TextStyle centerStyle;
  final TextStyle subStyle;
  final TextScaler textScaler;

  _DonutPainter({
    required this.slices,
    required this.selected,
    required this.lift,
    required this.centerLabel,
    required this.centerStyle,
    required this.subStyle,
    this.textScaler = TextScaler.noScaling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final rect = Rect.fromCircle(center: center, radius: radius - _stroke / 2);
    for (final s in slices) {
      // A slice mid-way through shrinking away can reach nothing.
      if (s.sweep <= 0.001) continue;
      final start = s.start - math.pi / 2;
      final sweep = s.sweep;
      final isSelected = s.id == selected;
      final out = isSelected
          ? Offset(math.cos(start + sweep / 2), math.sin(start + sweep / 2)) *
                (8 * lift)
          : Offset.zero;
      final alpha = selected == null || isSelected
          ? 1.0
          : lerpDouble(1, 0.3, lift)!;
      canvas.drawArc(
        rect.shift(out),
        start,
        // Small gap between segments for readability.
        math.max(sweep - 0.03, 0.01),
        false,
        Paint()
          ..color = s.color.withValues(alpha: s.color.a * alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke
          ..strokeCap = StrokeCap.butt,
      );
    }

    final title = TextPainter(
      text: TextSpan(text: centerLabel, style: centerStyle),
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final sub = TextPainter(
      text: TextSpan(text: 'spent', style: subStyle),
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    title.paint(canvas, center - Offset(title.width / 2, title.height / 2 + 7));
    sub.paint(canvas, center - Offset(sub.width / 2, -title.height / 2 + 7));
  }

  // Records compare by value, so the slice lists compare what the painter
  // actually draws (the provider mints new entry objects on every notify,
  // which used to force a repaint even when the numbers were unchanged).
  @override
  bool shouldRepaint(covariant _DonutPainter old) {
    if (old.selected != selected ||
        old.lift != lift ||
        old.centerLabel != centerLabel ||
        old.textScaler != textScaler ||
        old.slices.length != slices.length) {
      return true;
    }
    for (var i = 0; i < slices.length; i++) {
      if (old.slices[i] != slices[i]) return true;
    }
    return false;
  }
}
