import 'package:flutter/material.dart';

/// Dark palette (the app's native look) — charcoal structure with a coral
/// accent, modeled on the Figma restaurant-POS dashboard kit. Everything is
/// `const` so const widget trees and `kCategories` can reference members
/// directly. Category colors always use these dark-kit hues in both modes.
abstract final class FigmaPalette {
  // Structure
  static const bg = Color(0xFF1B1927); // app background
  static const surface = Color(0xFF252836); // cards, nav bar, sheets
  static const surface2 = Color(0xFF2D303E); // input fill, raised layer
  static const border = Color(0xFF3B3F4F); // dividers, outlines

  // Accent (default — user-selectable in Settings)
  static const primary = Color(0xFFEA7C69); // coral
  static const primaryLight = Color(0xFFF2A69C);

  // Text
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB4C0C8);
  static const textMuted = Color(0xFF8E9AA6);

  // Semantic
  static const green = Color(0xFF50D1AA); // income / success
  static const orange = Color(0xFFFFB572); // warning
  static const blue = Color(0xFF65B0F6);
  static const purple = Color(0xFF9290FE);
  static const pink = Color(0xFFFF7CA3); // expense / error
}

/// Light-mode counterpart: white cards over a cool off-white background,
/// semantic colors darkened enough to read as text on white.
abstract final class FigmaPaletteLight {
  static const bg = Color(0xFFF4F5F9);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFECEEF4);
  static const border = Color(0xFFDDE1EA);

  static const textPrimary = Color(0xFF23212E);
  static const textSecondary = Color(0xFF5F6673);
  static const textMuted = Color(0xFF98A0AC);

  // Deep enough for 15px-bold TEXT on white (income/expense amounts,
  // breakdown rows): the previous values measured 2.6–3.9:1 against
  // #FFFFFF — below the 4.5:1 normal-text threshold.
  static const green = Color(0xFF0F8168); // was 1FA98A (2.9:1)
  static const orange = Color(0xFFA6631C); // was E08F3C (2.6:1)
  static const blue = Color(0xFF2A6BC0); // was 3B82D9
  static const purple = Color(0xFF5A58C9); // was 6F6DE0
  static const pink = Color(0xFFC0264F); // was E14C7E (3.9:1)
}

/// A selectable accent colour for the app theme.
class AccentColor {
  final String name;
  final Color color;
  const AccentColor(this.name, this.color);
}

/// Accent presets offered in Settings — the kit family first, coral default.
const List<AccentColor> kAccentPresets = [
  AccentColor('Coral', FigmaPalette.primary),
  AccentColor('Sunset', FigmaPalette.orange),
  AccentColor('Mint', FigmaPalette.green),
  AccentColor('Sky', FigmaPalette.blue),
  AccentColor('Iris', FigmaPalette.purple),
  AccentColor('Rose', FigmaPalette.pink),
];
