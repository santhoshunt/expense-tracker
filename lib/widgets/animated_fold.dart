import 'package:flutter/material.dart';

import 'motion.dart';

/// Animated collapse/expand for a section body: a pure height reveal.
///
/// Deliberately NOT an AnimatedCrossFade — fading content in while the
/// height grows made amounts appear half-transparent mid-expansion. Here
/// the child stays fully opaque and is clipped as the height animates, so
/// rows slide into view already fully rendered. The child stays mounted at
/// zero height when collapsed (tests assert on rendered height), hidden from
/// screen readers and focus.
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
        duration: motionDuration(context, duration),
        curve: Curves.easeOutCubic,
        // Folded rows stay mounted but must not be reachable: TalkBack's
        // swipe order and keyboard focus would otherwise land on them.
        child: ExcludeSemantics(
          excluding: collapsed,
          child: ExcludeFocus(excluding: collapsed, child: child),
        ),
      ),
    );
  }
}
