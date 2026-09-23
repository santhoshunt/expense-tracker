import 'package:flutter/material.dart';

import 'figma_palette.dart';

/// The structural colours of one dark theme: backgrounds, borders, text,
/// and the accent it suggests. Semantic colours (income green, expense
/// pink, chart blue/purple) and category colours are shared by every theme.
@immutable
class PaletteColors {
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// Applied when the theme is picked; the user can change it afterwards.
  final Color accent;

  const PaletteColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
  });
}

/// Selectable dark themes. Light mode ignores the choice and keeps
/// [FigmaPaletteLight]. [standard] is the app's original look.
enum AppPalette {
  standard(
    'Default',
    'Charcoal with coral',
    PaletteColors(
      bg: FigmaPalette.bg,
      surface: FigmaPalette.surface,
      surface2: FigmaPalette.surface2,
      border: FigmaPalette.border,
      textPrimary: FigmaPalette.textPrimary,
      textSecondary: FigmaPalette.textSecondary,
      textMuted: FigmaPalette.textMuted,
      accent: FigmaPalette.primary,
    ),
  ),
  // The Midnight launcher icon's near-black teal with its neon cyan glyph.
  midnight(
    'Midnight',
    'Matches the Midnight icon',
    PaletteColors(
      bg: Color(0xFF07090A),
      surface: Color(0xFF0E1413),
      surface2: Color(0xFF14201E),
      border: Color(0xFF1E302D),
      textPrimary: Color(0xFFE8FBFB),
      textSecondary: Color(0xFF8FB3B0),
      textMuted: Color(0xFF6F8F8C),
      accent: Color(0xFF00E5FF),
    ),
  ),
  amoled(
    'AMOLED black',
    'True black, saves battery',
    PaletteColors(
      bg: Color(0xFF000000),
      surface: Color(0xFF0A0A0C),
      surface2: Color(0xFF131317),
      border: Color(0xFF24242A),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFA6A6B0),
      textMuted: Color(0xFF85858F),
      accent: FigmaPalette.primary,
    ),
  ),
  nord(
    'Nord',
    'Cool arctic greys',
    PaletteColors(
      bg: Color(0xFF1D2129),
      surface: Color(0xFF252B35),
      surface2: Color(0xFF2D3440),
      border: Color(0xFF3C4452),
      textPrimary: Color(0xFFECEFF4),
      textSecondary: Color(0xFFAEB7C6),
      textMuted: Color(0xFF8A94A6),
      accent: Color(0xFF88C0D0),
    ),
  ),
  nebula(
    'Nebula',
    'Violet night sky',
    PaletteColors(
      bg: Color(0xFF140F24),
      surface: Color(0xFF1D1633),
      surface2: Color(0xFF251D40),
      border: Color(0xFF362B58),
      textPrimary: Color(0xFFF3EEFF),
      textSecondary: Color(0xFFB6A8D6),
      textMuted: Color(0xFF9384B8),
      accent: Color(0xFFB794F6),
    ),
  ),
  ocean(
    'Ocean',
    'Deep navy blues',
    PaletteColors(
      bg: Color(0xFF0A1624),
      surface: Color(0xFF0F2033),
      surface2: Color(0xFF152A42),
      border: Color(0xFF20385A),
      textPrimary: Color(0xFFEAF3FF),
      textSecondary: Color(0xFF9DB4CF),
      textMuted: Color(0xFF7C93B0),
      accent: Color(0xFF4FC3F7),
    ),
  ),
  forest(
    'Forest',
    'Dark pine greens',
    PaletteColors(
      bg: Color(0xFF0D1611),
      surface: Color(0xFF132119),
      surface2: Color(0xFF192B20),
      border: Color(0xFF26402F),
      textPrimary: Color(0xFFEAF7EE),
      textSecondary: Color(0xFFA2BFAB),
      textMuted: Color(0xFF7F9C88),
      accent: Color(0xFF6FD08C),
    ),
  );

  final String label;
  final String subtitle;
  final PaletteColors colors;
  const AppPalette(this.label, this.subtitle, this.colors);
}
