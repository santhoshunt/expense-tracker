import 'package:flutter/material.dart';

/// Flat backdrop behind screen content. The Scaffold already paints this
/// colour; the widget stays for standalone call sites (Classifiers,
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

/// Kit-style segmented tabs ("Dine In / To Go / Delivery"): an accent thumb
/// glides between segments; the selected label contrasts, the rest muted.
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segmentWidth = constraints.maxWidth / options.length;
            return SizedBox(
              // Follows the font scale: at a fixed 38dp the FittedBox merely
              // shrinks large-font labels until they are unreadable.
              height: MediaQuery.textScalerOf(context).scale(38),
              child: Stack(
                children: [
                  // The thumb glides between segments.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    left: index * segmentWidth,
                    top: 0,
                    bottom: 0,
                    width: segmentWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(11),
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
                                          ? scheme.onPrimary
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
        ),
      ),
    );
  }
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
