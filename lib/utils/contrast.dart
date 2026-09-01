import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Black or white, whichever actually reads on [background] — for glyphs
/// drawn directly on a colour swatch. The break-even luminance where black
/// and white give equal WCAG contrast is L ≈ 0.179 (where (L+0.05)² =
/// 1.05·0.05), NOT the 0.5 midpoint: the old threshold handed Coral, Sky,
/// Iris and Rose a white glyph at 2.3–2.8:1 when black87 reads at 6–7.5:1
/// on the same swatch.
Color onSwatch(Color background) =>
    background.computeLuminance() > 0.179 ? Colors.black87 : Colors.white;

/// WCAG contrast ratio between two colours.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Darkens [color] (keeping its hue) until it reads against [background]
/// at [minRatio]. Returns [color] untouched when it already passes — so
/// dark themes and already-dark custom colours cost nothing.
Color _darkenForContrast(Color color, Color background, double minRatio) {
  var c = color;
  var hsl = HSLColor.fromColor(color);
  while (contrastRatio(c, background) < minRatio && hsl.lightness > 0.05) {
    hsl = hsl.withLightness(math.max(0.05, hsl.lightness - 0.04));
    c = hsl.toColor();
  }
  return c;
}

/// The accent, darkened when needed so it reads as small TEXT on the light
/// theme's near-white surfaces (section headers, month dividers). The
/// theme keeps the accent hue unchanged between brightnesses, so the
/// saturated presets that pass on charcoal measured 2.3–2.8:1 on white.
/// Dark mode returns the accent as-is.
Color accentTextColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  if (scheme.brightness == Brightness.dark) return scheme.primary;
  // Worst case is a white card; passing there also passes the off-white bg.
  return _darkenForContrast(scheme.primary, Colors.white, 4.5);
}

/// Category glyph colour for the icon-on-tint badges (a category icon drawn
/// on a 15%-alpha wash of its own colour). The dark-kit category hues pass
/// on charcoal but washed out to 1.6–2.4:1 over their own near-white tint
/// in light mode — darken the same hue until the glyph clears the 3:1
/// non-text threshold against that tint. Dark mode returns [base] as-is.
Color categoryGlyphColor(BuildContext context, Color base) {
  final scheme = Theme.of(context).colorScheme;
  if (scheme.brightness == Brightness.dark) return base;
  final tint = Color.alphaBlend(base.withValues(alpha: 0.15), scheme.surface);
  return _darkenForContrast(base, tint, 3.0);
}
