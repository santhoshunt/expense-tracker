import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import '../utils/haptics.dart';
import 'glow_tilt.dart';
import 'motion.dart';

/// Screen backdrop: the theme background with the accent glowing in from
/// the top-left corner and, fainter, the bottom-right. Wraps a whole
/// Scaffold (made transparent) so the glow also runs under the app bar;
/// it stays opaque, so a pushed route never shows the page beneath it.
///
/// Under a [GlowTilt] the glows drift with the phone's tilt, the faint one
/// half as far the other way, for depth.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: CustomPaint(
        painter: AmbientGlowPainter(
          accent: theme.colorScheme.primary,
          dark: theme.brightness == Brightness.dark,
          tilt: GlowTilt.of(context),
        ),
        // Its own layer: a tilt repaints only the glow, never the page.
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

/// Paints [AmbientBackground]'s two glows, moved by [tilt].
@visibleForTesting
class AmbientGlowPainter extends CustomPainter {
  final Color accent;
  final bool dark;
  final ValueListenable<Offset>? tilt;

  AmbientGlowPainter({required this.accent, required this.dark, this.tilt})
    : super(repaint: tilt);

  /// The glows for a tilt [t] (each axis -1 to 1), main one first.
  List<RadialGradient> glows(Offset t) {
    RadialGradient glow(Alignment at, double radius, double alpha) =>
        RadialGradient(
          center: at,
          radius: radius,
          colors: [
            accent.withValues(alpha: alpha),
            accent.withValues(alpha: 0),
          ],
        );
    // White backdrops show a tint far more readily than charcoal.
    return [
      glow(
        Alignment(-1.2 + t.dx * 0.25, -1.1 + t.dy * 0.15),
        1.1,
        dark ? 0.24 : 0.14,
      ),
      glow(
        Alignment(1.2 - t.dx * 0.125, 1.1 - t.dy * 0.075),
        0.9,
        dark ? 0.12 : 0.07,
      ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (final g in glows(tilt?.value ?? Offset.zero)) {
      canvas.drawRect(rect, Paint()..shader = g.createShader(rect));
    }
  }

  @override
  bool shouldRepaint(AmbientGlowPainter old) =>
      old.accent != accent || old.dark != dark || old.tilt != tilt;
}

/// [base] with the accent washed over it at [alpha].
Color _tint(ColorScheme scheme, Color base, double alpha) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: alpha), base);

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

/// The Cockpit pages' floating button. A quiet fill with an accent edge
/// light rather than a solid accent fill,
/// so it reads as the primary action without outshouting the page.
///
/// [extended] false folds the label away, leaving the icon (the label is
/// still what TalkBack reads); lists collapse it while scrolling down.
class GlassButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool extended;

  const GlassButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.extended = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final motion = motionDuration(context, const Duration(milliseconds: 200));
    // Serves as the app's FAB but is a bare InkWell underneath — announce
    // it as a button to assistive tech.
    // excludeSemantics drops the InkWell's own tap action, so the node
    // carries it (as InfoTip does); without it TalkBack's double-tap does
    // nothing.
    return Semantics(
      button: true,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          // Same fill as the segmented thumb it is styled after.
          color: _tint(scheme, scheme.outlineVariant, 0.12),
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
            child: AnimatedPadding(
              duration: motion,
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                horizontal: extended ? 20 : 16,
                vertical: 16,
              ),
              child: AnimatedSize(
                duration: motion,
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 22, color: scheme.onSurface),
                    if (extended) ...[
                      const SizedBox(width: 8),
                      // Cross-fades when the label changes; AnimatedSize
                      // eases the width between them.
                      // Flexible: on a narrow screen with large text the
                      // label shortens rather than overflowing.
                      Flexible(
                        child: AnimatedSwitcher(
                          duration: motion,
                          child: Text(
                            label,
                            key: ValueKey(label),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Page tabs as plain labels with a short accent line under the selected
/// one: quieter than the boxed segmented control it replaced, for the page
/// switch at the top of a screen. With a [pager] the line follows `pager.page`
/// during a drag. Tests keep tapping labels by text.
class UnderlineTabs<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final PageController? pager;

  const UnderlineTabs({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.pager,
  });

  /// The line's share of a tab's width.
  static const _lineShare = 0.36;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = options
        .indexWhere((o) => o.$1 == selected)
        .clamp(0, options.length - 1);
    // A 48dp target at normal text, taller as the text grows.
    final height = MediaQuery.textScalerOf(context).scale(48);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / options.length;
          final lineWidth = tabWidth * _lineShare;
          Widget line(double page) => Positioned(
            left:
                page.clamp(0.0, (options.length - 1).toDouble()) * tabWidth +
                (tabWidth - lineWidth) / 2,
            bottom: 2,
            width: lineWidth,
            height: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
          final p = pager;
          return Stack(
            children: [
              Row(
                children: [
                  for (var i = 0; i < options.length; i++)
                    Expanded(child: _tab(context, scheme, i)),
                ],
              ),
              if (p == null)
                TweenAnimationBuilder<double>(
                  tween: Tween(end: index.toDouble()),
                  duration: motionDuration(
                    context,
                    const Duration(milliseconds: 260),
                  ),
                  curve: Curves.easeOutCubic,
                  builder: (context, page, _) => line(page),
                )
              else
                AnimatedBuilder(
                  animation: p,
                  builder: (context, _) => line(
                    (p.hasClients && p.position.haveDimensions)
                        ? (p.page ?? index.toDouble())
                        : index.toDouble(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _tab(BuildContext context, ColorScheme scheme, int i) {
    final (value, label) = options[i];
    final isSelected = value == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!isSelected) Haptics.tick();
          onChanged(value);
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedDefaultTextStyle(
                duration: motionDuration(
                  context,
                  const Duration(milliseconds: 260),
                ),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
                child: Text(label, maxLines: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of outline pills for a filter with a few values (account type). The selected pill gets an accent outline; the text stays
/// in the plain text colours, never coloured on a fill.
///
/// When the row scrolls sideways, the selected pill is kept in view: on
/// the first frame and whenever [selected] changes (a page swipe, a
/// deep-link), so a pill picked off screen never stays hidden.
class ChipTabs<T> extends StatefulWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Space inside the scroll view at each end: the strip scrolls to the
  /// screen edge while the first pill lines up with the page.
  final EdgeInsetsGeometry padding;

  const ChipTabs({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<ChipTabs<T>> createState() => _ChipTabsState<T>();
}

class _ChipTabsState<T> extends State<ChipTabs<T>> {
  /// One key per pill, by position, to find the selected one's box.
  List<GlobalKey> _keys = const [];

  List<GlobalKey> _keysFor(int count) {
    if (_keys.length != count) {
      _keys = List.generate(count, (_) => GlobalKey());
    }
    return _keys;
  }

  @override
  void initState() {
    super.initState();
    _revealSelected(animate: false);
  }

  @override
  void didUpdateWidget(covariant ChipTabs<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _revealSelected(animate: true);
  }

  /// Centres the selected pill in the row, post-frame so it has a box.
  /// Only the row's own scrollable moves: Scrollable.ensureVisible would
  /// also scroll a page list the row sits in. The first frame jumps, so a
  /// screen never opens with its chips sliding.
  void _revealSelected({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final i = widget.options.indexWhere((o) => o.$1 == widget.selected);
      if (i < 0 || i >= _keys.length) return;
      final pill = _keys[i].currentContext;
      if (pill == null) return;
      final box = pill.findRenderObject();
      final position = Scrollable.maybeOf(pill)?.position;
      if (box == null || position == null) return;
      position.ensureVisible(
        box,
        alignment: 0.5,
        duration: animate
            ? motionDuration(context, const Duration(milliseconds: 200))
            : Duration.zero,
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options = widget.options;
    final selected = widget.selected;
    final keys = _keysFor(options.length);
    // One row, scrolled sideways when it does not fit (large text on a
    // narrow phone): wrapped to a second row it pushed the list down and
    // off the screen. Five pills fit at 390dp.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      child: Row(
        spacing: 6,
        children: [
          for (final (i, (value, label)) in options.indexed)
            Semantics(
              key: keys[i],
              button: true,
              selected: value == selected,
              label: label,
              onTap: () => widget.onChanged(value),
              excludeSemantics: true,
              // A 36dp pill in a 44dp target: the 4dp above and below it take
              // the tap too. No taller: above the transaction list, with both
              // review cards open, every row of height is the list's.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _tap(value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(
                        AppRadius.control * 2,
                      ),
                      onTap: () => _tap(value),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            AppRadius.control * 2,
                          ),
                          border: Border.all(
                            color: value == selected
                                ? scheme.primary
                                : scheme.outlineVariant,
                            width: value == selected ? 1.5 : 1,
                          ),
                        ),
                        child: Text(
                          label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: value == selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: value == selected
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _tap(T value) {
    if (value != widget.selected) Haptics.tick();
    widget.onChanged(value);
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
