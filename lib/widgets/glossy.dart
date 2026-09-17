import 'package:flutter/material.dart';

/// Flat backdrop behind screen content. The Scaffold already paints this
/// colour; the widget stays for standalone call sites (Cockpit,
/// Settings) so every screen shares one background source.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: child,
  );
}

/// Accent primary-action pill — the app's FAB.
class GlassButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const GlassButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Serves as the app's FAB but is a bare InkWell underneath — announce
    // it as a button to assistive tech.
    return Semantics(
      button: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.30),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: scheme.onPrimary),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: scheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Underline tabs: bare labels over a hairline baseline, with a short accent
/// bar that glides under the selected one. The old boxed track with a filled
/// thumb read as dated chrome; this keeps the same API, so call sites and
/// the tests that tap labels by text are untouched.
class GlassSegmented<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const GlassSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = options
        .indexWhere((o) => o.$1 == selected)
        .clamp(0, options.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final segmentWidth = constraints.maxWidth / options.length;
        return SizedBox(
          // Follows the font scale: at a fixed 38dp the FittedBox merely
          // shrinks large-font labels until they are unreadable.
          height: MediaQuery.textScalerOf(context).scale(38),
          child: Stack(
            children: [
              // Hairline baseline the accent bar rides on, so the tabs keep
              // a footprint on sparse pages (the Settings rows).
              Positioned(
                left: 0,
                right: 0,
                bottom: 1,
                child: ColoredBox(
                  color: scheme.outlineVariant,
                  child: const SizedBox(height: 1),
                ),
              ),
              // The indicator glides between segments.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: index * segmentWidth,
                bottom: 0,
                width: segmentWidth,
                height: 3,
                child: Center(
                  child: Container(
                    width: 28,
                    height: 3,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final (value, label) in options)
                    Expanded(
                      // Semantics: a bare GestureDetector reads as
                      // static text to TalkBack — no button role, no
                      // selected state.
                      child: Semantics(
                        button: true,
                        selected: value == selected,
                        label: label,
                        excludeSemantics: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(value),
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 260),
                                style: TextStyle(
                                  // On the body scale (14) — 13.5 was the
                                  // app's one fractional odd-one-out.
                                  fontSize: 14,
                                  fontWeight: value == selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: value == selected
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                child: Text(label, maxLines: 1),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontal swipe anywhere on the wrapped page steps the segmented
/// selection: left goes forward through [values], right goes back, stopping
/// at the ends. Inner horizontal scrollables (the stat-card strip, chip
/// rows) still win their own drags in the gesture arena; this only receives
/// what nothing else claimed.
class SegmentedSwipe<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final Widget child;

  const SegmentedSwipe({
    super.key,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.child,
  });

  /// A lazy flick should not switch views — deliberate swipes move faster.
  static const double _minVelocity = 200;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onHorizontalDragEnd: (details) {
      final v = details.primaryVelocity ?? 0;
      if (v.abs() < _minVelocity) return;
      final next = values.indexOf(selected) + (v < 0 ? 1 : -1);
      if (next < 0 || next >= values.length) return;
      onChanged(values[next]);
    },
    child: child,
  );
}

/// Solid card panel — flat, opaque `scheme.surface`. The name survives from
/// the old liquid-glass look; there is no BackdropFilter anywhere anymore,
/// which also keeps list scrolling cheap.
class FrostedPanel extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;

  const FrostedPanel({
    super.key,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(16)),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: radius,
        // White cards need a hairline against the light backdrop.
        border: scheme.brightness == Brightness.light
            ? Border.all(color: scheme.outlineVariant)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      // Transparent Material between the colored box and any ListTile/InkWell
      // child: they paint splashes on the NEAREST Material, and painting on
      // one *behind* the colored decoration is both invisible and a debug
      // assertion ("ListTile background color or ink splashes may be
      // invisible") the widget tests trip.
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
