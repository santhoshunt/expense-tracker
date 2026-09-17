import 'package:flutter/material.dart';

/// A spend bar with a notch marking what it is being measured against, so
/// "over" or "under" reads before any number does. One primitive at two
/// sizes: tall inside the comparison cards, slim in the per-category rows.
///
/// It paints no text. Every label is a real widget beside the bar, which
/// keeps coloured text off a coloured fill and leaves text scaling to the
/// framework instead of to [TextPainter].
class ComparisonBar extends StatelessWidget {
  /// What was actually spent.
  final double actual;

  /// The previous month's figure, or the usual one. Drawn as the notch.
  final double reference;

  /// Resolved by the caller from the over/under state.
  final Color color;

  final Color trackColor;
  final Color notchColor;
  final double height;
  final Duration duration;

  const ComparisonBar({
    super.key,
    required this.actual,
    required this.reference,
    required this.color,
    required this.trackColor,
    required this.notchColor,
    this.height = 18,
    this.duration = const Duration(milliseconds: 700),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // begin == end: `begin` only matters at mount, so a row scrolled out of
      // the cache extent and back renders at its value instead of replaying
      // the grow-in. Real value changes still animate. Same trick as
      // RingProgress (motion.dart:90).
      tween: Tween(begin: actual, end: actual),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => SizedBox(
        // The notch overhangs the track, so the box is taller than the bar.
        height: height + _overhang * 2,
        width: double.infinity,
        child: CustomPaint(
          painter: _ComparisonBarPainter(
            actual: v,
            reference: reference,
            color: color,
            trackColor: trackColor,
            notchColor: notchColor,
            barHeight: height,
          ),
        ),
      ),
    );
  }
}

const double _overhang = 3;

/// Public so the reference-line legend can draw an exact copy of the notch.
const double kNotchWidth = 2.5;

class _ComparisonBarPainter extends CustomPainter {
  final double actual;
  final double reference;
  final Color color;
  final Color trackColor;
  final Color notchColor;
  final double barHeight;

  _ComparisonBarPainter({
    required this.actual,
    required this.reference,
    required this.color,
    required this.trackColor,
    required this.notchColor,
    required this.barHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(barHeight / 2);
    final top = _overhang;
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, barHeight),
      radius,
    );
    canvas.drawRRect(track, Paint()..color = trackColor);

    // Headroom above the taller of the two so the notch never sits on the
    // right edge, where it would read as a boundary rather than a mark.
    final peak = (actual > reference ? actual : reference) * 1.15;
    if (peak <= 0) return;

    if (actual > 0) {
      // A fill narrower than its own corner radius collapses into a sliver;
      // floor it at a dot so "spent a little" stays visible.
      final width = (actual / peak * size.width).clamp(barHeight, size.width);
      final rect = Rect.fromLTWH(0, top, width, barHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()
          ..shader = LinearGradient(
            colors: [color.withValues(alpha: 0.55), color],
          ).createShader(rect),
      );
    }

    if (reference > 0) {
      final x = (reference / peak * size.width).clamp(
        kNotchWidth / 2,
        size.width - kNotchWidth / 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x - kNotchWidth / 2,
            0,
            kNotchWidth,
            barHeight + _overhang * 2,
          ),
          const Radius.circular(kNotchWidth / 2),
        ),
        Paint()..color = notchColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ComparisonBarPainter old) =>
      old.actual != actual ||
      old.reference != reference ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.notchColor != notchColor ||
      old.barHeight != barHeight;
}
