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
///
/// [AnimatedFold.lazy] builds its child only while it shows: from the frame
/// it starts to open until it has finished closing. A fold at rest closed
/// builds nothing, so a data change costs its rows nothing; the clip and
/// the height animation are the same as the mounted fold's.
class AnimatedFold extends StatefulWidget {
  final bool collapsed;
  final Widget? child;
  final WidgetBuilder? builder;

  const AnimatedFold({
    super.key,
    required this.collapsed,
    required Widget this.child,
  }) : builder = null;

  const AnimatedFold.lazy({
    super.key,
    required this.collapsed,
    required WidgetBuilder this.builder,
  }) : child = null;

  static const duration = Duration(milliseconds: 250);

  @override
  State<AnimatedFold> createState() => _AnimatedFoldState();
}

class _AnimatedFoldState extends State<AnimatedFold> {
  /// Whether a lazy fold's child is built: set as it starts to open, cleared
  /// once a close has run its course.
  late bool _built = !widget.collapsed;

  @override
  void didUpdateWidget(AnimatedFold old) {
    super.didUpdateWidget(old);
    if (!widget.collapsed) _built = true;
  }

  /// The height animation ended. A fold that ended closed lets its child go.
  void _settled() {
    if (mounted && widget.collapsed && _built) setState(() => _built = false);
  }

  @override
  Widget build(BuildContext context) {
    final duration = motionDuration(context, AnimatedFold.duration);
    final builder = widget.builder;
    // With motion off a close has nothing to show, and its end would be
    // reported in the middle of this build.
    if (widget.collapsed && duration == Duration.zero) _built = false;
    final child = builder == null
        ? widget.child!
        : _built
        ? builder(context)
        : const SizedBox.shrink();
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.topCenter,
        heightFactor: widget.collapsed ? 0 : 1,
        duration: duration,
        curve: Curves.easeOutCubic,
        onEnd: builder == null ? null : _settled,
        // Folded rows stay mounted but must not be reachable: TalkBack's
        // swipe order and keyboard focus would otherwise land on them.
        child: ExcludeSemantics(
          excluding: widget.collapsed,
          child: ExcludeFocus(excluding: widget.collapsed, child: child),
        ),
      ),
    );
  }
}
