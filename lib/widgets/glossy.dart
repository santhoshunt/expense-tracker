import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// Screen backdrop: the theme background with the accent glowing in from
/// the top-left corner and, fainter, the bottom-right. Wraps a whole
/// Scaffold (made transparent) so the glow also runs under the app bar;
/// it stays opaque, so a pushed route never shows the page beneath it.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    // White backdrops show a tint far more readily than charcoal.
    final dark = theme.brightness == Brightness.dark;
    RadialGradient glow(Alignment from, double radius, double alpha) =>
        RadialGradient(
          center: from,
          radius: radius,
          colors: [
            accent.withValues(alpha: alpha),
            accent.withValues(alpha: 0),
          ],
        );
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: glow(const Alignment(-1.2, -1.1), 1.1, dark ? 0.24 : 0.14),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: glow(const Alignment(1.2, 1.1), 0.9, dark ? 0.12 : 0.07),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Edge light: an accent rim with the glow kept inside the shape. Used as a
/// FOREGROUND decoration: a decoration paints its shadows beneath its own
/// fill, which would hide an inner glow.
BoxDecoration _edgeLight(ColorScheme scheme, double radius) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: scheme.primary.withValues(alpha: 0.55)),
  boxShadow: [
    BoxShadow(
      color: scheme.primary.withValues(alpha: 0.20),
      blurRadius: 10,
      blurStyle: BlurStyle.inner,
    ),
  ],
);

/// Primary-action pill — the app's FAB. Styled like [GlassSegmented]'s
/// thumb (quiet fill, accent edge light) rather than a solid accent fill,
/// so it reads as the primary action without outshouting the page.
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
      child: Container(
        decoration: BoxDecoration(
          color: scheme.outlineVariant,
          borderRadius: BorderRadius.circular(14),
          // Neutral lift so it floats over list content; no accent glow.
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        foregroundDecoration: _edgeLight(scheme, 14),
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
                  Icon(icon, size: 22, color: scheme.onSurface),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: scheme.onSurface,
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

/// Segmented control with a glass thumb that slides under the selected tab.
/// With a [pager] the thumb tracks `pager.page` continuously, so it follows
/// the finger during a PageView drag (the Cockpit's TabBar feel); without
/// one it animates between segments on selection. [icons] adds a leading
/// icon per tab. Tests keep tapping labels by text.
class GlassSegmented<T> extends StatelessWidget {
  final List<(T, String)> options;

  /// One leading icon per option, in [options] order.
  final List<IconData>? icons;

  final T selected;
  final ValueChanged<T> onChanged;

  /// Continuous position source: the thumb rides `page * segmentWidth`
  /// mid-drag instead of jumping per selection.
  final PageController? pager;

  const GlassSegmented({
    super.key,
    required this.options,
    this.icons,
    required this.selected,
    required this.onChanged,
    this.pager,
  }) : assert(icons == null || icons.length == options.length);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = options
        .indexWhere((o) => o.$1 == selected)
        .clamp(0, options.length - 1);
    return Container(
      // Follows the font scale: at a fixed 44dp the FittedBox merely
      // shrinks large-font labels until they are unreadable.
      height: MediaQuery.textScalerOf(context).scale(44),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / options.length;
          return Stack(
            children: [
              _buildThumb(scheme, segmentWidth, index),
              Row(
                children: [
                  for (var i = 0; i < options.length; i++)
                    Expanded(child: _buildTab(scheme, i)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildThumb(ColorScheme scheme, double segmentWidth, int index) {
    final thumb = Container(
      decoration: BoxDecoration(
        color: scheme.outlineVariant,
        borderRadius: BorderRadius.circular(9),
      ),
      foregroundDecoration: _edgeLight(scheme, 9),
    );
    final p = pager;
    if (p == null) {
      return AnimatedPositioned(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        left: index * segmentWidth,
        top: 0,
        bottom: 0,
        width: segmentWidth,
        child: thumb,
      );
    }
    // Positioned may be separated from the Stack by non-RenderObject
    // widgets, so the AnimatedBuilder in between is legal.
    return AnimatedBuilder(
      animation: p,
      builder: (context, _) {
        final page = (p.hasClients && p.position.haveDimensions)
            ? (p.page ?? index.toDouble())
            : index.toDouble();
        return Positioned(
          left: page.clamp(0.0, (options.length - 1).toDouble()) * segmentWidth,
          top: 0,
          bottom: 0,
          width: segmentWidth,
          child: thumb,
        );
      },
    );
  }

  Widget _buildTab(ColorScheme scheme, int i) {
    final (value, label) = options[i];
    final isSelected = value == selected;
    final color = isSelected ? scheme.onSurface : scheme.onSurfaceVariant;
    // Semantics: a bare GestureDetector reads as static text to TalkBack —
    // no button role, no selected state.
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(value),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icons != null) ...[
                    Icon(icons![i], size: 16, color: color),
                    const SizedBox(width: 5),
                  ],
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 260),
                    style: TextStyle(
                      // On the body scale (14) — 13.5 was the app's one
                      // fractional odd-one-out.
                      fontSize: 14,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: color,
                    ),
                    child: Text(label, maxLines: 1),
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

/// Solid card panel — flat and opaque, in the theme's accent-touched card
/// fill (`AppColors.cardFill`, plain `scheme.surface` without the theme
/// extension). The name survives from
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
    final colors = AppColors.of(context);
    final outline = colors.cardOutline;
    return Container(
      decoration: BoxDecoration(
        color: colors.cardFill ?? scheme.surface,
        borderRadius: radius,
        border: outline == null ? null : Border.all(color: outline),
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
