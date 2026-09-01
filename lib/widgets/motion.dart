import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/format.dart';

/// Money text that morphs when its value changes in place (an edit, a sync):
/// the old number slides up and fades out while the new one rises in from
/// below. Softer than a hard swap.
///
/// Use only for values that change on data updates — NOT for values that
/// change on navigation (e.g. month switching), where the motion reads as
/// churn.
class MorphingAmount extends StatelessWidget {
  final double value;
  final TextStyle? style;
  final String prefix;
  final Alignment alignment;

  const MorphingAmount({
    super.key,
    required this.value,
    this.style,
    this.prefix = '',
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    final text = '$prefix${fmtMoney(value)}';
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) =>
          Stack(alignment: alignment, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        // Both numbers travel upward like an odometer: the incoming child
        // rises from below to centre; the outgoing child (whose animation
        // runs in reverse) continues up and out.
        final incoming = child.key == ValueKey(text);
        final offset = Tween<Offset>(
          begin: Offset(0, incoming ? 0.6 : -0.6),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: Text(
        text,
        key: ValueKey(text),
        style: style,
        maxLines: 1,
        // Ellipsize when squeezed — the default hard-clips mid-digit.
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Ring gauge whose arc sweeps from empty to [value] while the centre
/// percentage counts up in sync (both driven by one animation). [value] is a
/// fraction that may exceed 1 (e.g. 2.3 for 230% over budget); the arc caps
/// at a full circle while the label keeps counting.
class RingProgress extends StatelessWidget {
  final double value;
  final double size;
  final double strokeWidth;
  final Color color;
  final Color trackColor;
  final TextStyle? labelStyle;
  final Duration duration;

  const RingProgress({
    super.key,
    required this.value,
    required this.color,
    required this.trackColor,
    this.size = 72,
    this.strokeWidth = 9,
    this.labelStyle,
    this.duration = const Duration(milliseconds: 900),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // begin == end: `begin` only matters at mount, so a row scrolled out
      // and back in (fresh State) renders at its value instantly instead of
      // replaying a 0→value sweep; real value changes still animate.
      tween: Tween(begin: value, end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: v.clamp(0.0, 1.0),
            color: color,
            trackColor: trackColor,
            strokeWidth: strokeWidth,
          ),
          // FittedBox: the ring's box is fixed while the label follows the
          // user's font scale — at large scale (or "1000%") the text used to
          // wrap and cross the ring stroke.
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(strokeWidth + 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('${(v * 100).round()}%', style: labelStyle),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  _RingPainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        fraction * 2 * math.pi,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}

/// Progress bar that eases to its new fraction.
class AnimatedProgress extends StatelessWidget {
  final double value;
  final double minHeight;
  final Color color;
  final Color backgroundColor;
  final BorderRadius borderRadius;

  const AnimatedProgress({
    super.key,
    required this.value,
    required this.color,
    required this.backgroundColor,
    this.minHeight = 6,
    this.borderRadius = const BorderRadius.all(Radius.circular(4)),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: TweenAnimationBuilder<double>(
        // begin == end: see RingProgress — no 0→value replay on remount.
        tween: Tween(begin: value.clamp(0.0, 1.0), end: value.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (_, v, _) => LinearProgressIndicator(
          value: v,
          minHeight: minHeight,
          color: color,
          backgroundColor: backgroundColor,
        ),
      ),
    );
  }
}
