import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../utils/format.dart';

/// Donut chart of spending by category, drawn with CustomPaint (no chart
/// dependency), with a wrap legend below.
class CategoryDonutChart extends StatelessWidget {
  final List<MapEntry<TxCategory, double>> data;

  /// Tapping a legend entry deep-links to that category's transactions —
  /// for sub-degree slices the legend is the only usable target.
  final void Function(String categoryId)? onCategoryTap;

  const CategoryDonutChart({super.key, required this.data, this.onCategoryTap});

  /// Slice colours with duplicates nudged apart: the 8-colour palette across
  /// arbitrarily many categories means two slices can render identically,
  /// leaving the donut and its legend ambiguous. Later duplicates shift
  /// stepwise toward white (dark theme) or black (light theme), same rule
  /// for arc and legend dot so they always match.
  List<Color> _sliceColors(Brightness brightness) {
    final seen = <int, int>{};
    final toward = brightness == Brightness.dark ? Colors.white : Colors.black;
    return [
      for (final e in data)
        switch (seen.update(
          e.key.color.toARGB32(),
          (n) => n + 1,
          ifAbsent: () => 0,
        )) {
          0 => e.key.color,
          final n => Color.lerp(e.key.color, toward, math.min(0.18 * n, 0.45))!,
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    final total = data.fold(0.0, (s, e) => s + e.value);
    if (total <= 0) {
      return const SizedBox(
        height: 160,
        child: Center(child: Text('No spending this month')),
      );
    }
    final colors = _sliceColors(Theme.of(context).brightness);
    return Column(
      children: [
        SizedBox(
          height: 180,
          child: CustomPaint(
            size: Size.infinite,
            painter: _DonutPainter(
              data: data,
              colors: colors,
              total: total,
              centerLabel: fmtMoneyCompact(total),
              centerStyle: Theme.of(
                context,
              ).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.bold),
              subStyle: Theme.of(context).textTheme.bodySmall!,
              // Painted text bypasses widget-level scaling; honour it.
              textScaler: MediaQuery.textScalerOf(context),
            ),
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
                onTap: onCategoryTap == null
                    ? null
                    : () => onCategoryTap!(e.key.id),
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
                        style: Theme.of(context).textTheme.bodySmall,
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
  final List<MapEntry<TxCategory, double>> data;

  /// Parallel to [data] — already disambiguated for duplicates.
  final List<Color> colors;
  final double total;
  final String centerLabel;
  final TextStyle centerStyle;
  final TextStyle subStyle;
  final TextScaler textScaler;

  _DonutPainter({
    required this.data,
    required this.colors,
    required this.total,
    required this.centerLabel,
    required this.centerStyle,
    required this.subStyle,
    this.textScaler = TextScaler.noScaling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    const stroke = 26.0;
    final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);

    var start = -math.pi / 2;
    for (final (i, e) in data.indexed) {
      final sweep = (e.value / total) * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        // Small gap between segments for readability.
        math.max(sweep - 0.03, 0.01),
        false,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt,
      );
      start += sweep;
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

  // MapEntry does NOT override ==, so listEquals over the entries degrades
  // to identity — and the provider mints new entry objects on every notify,
  // which forced a full repaint even when the numbers were unchanged.
  // Compare what the painter actually draws: per-slice value + colour.
  @override
  bool shouldRepaint(covariant _DonutPainter old) {
    if (old.total != total ||
        old.centerLabel != centerLabel ||
        old.textScaler != textScaler ||
        old.data.length != data.length) {
      return true;
    }
    for (var i = 0; i < data.length; i++) {
      if (old.data[i].value != data[i].value || old.colors[i] != colors[i]) {
        return true;
      }
    }
    return false;
  }
}
