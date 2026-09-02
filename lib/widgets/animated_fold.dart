import 'package:flutter/material.dart';

/// Animated collapse/expand for a section body: a pure height reveal.
///
/// Deliberately NOT an AnimatedCrossFade — fading content in while the
/// height grows made amounts appear half-transparent mid-expansion. Here
/// the child stays fully opaque and is clipped as the height animates, so
/// rows slide into view already fully rendered. The child stays mounted at
/// zero height when collapsed (tests assert on rendered height).
class AnimatedFold extends StatelessWidget {
  final bool collapsed;
  final Widget child;

  const AnimatedFold({super.key, required this.collapsed, required this.child});

  static const duration = Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.topCenter,
        heightFactor: collapsed ? 0 : 1,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: child,
      ),
    );
  }
}
