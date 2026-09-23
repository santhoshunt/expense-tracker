import 'package:flutter/material.dart';

import 'app_palettes.dart';
import 'figma_palette.dart';

/// Theme-aware semantic colours (income green, warning orange, chart blue /
/// purple). Expense pink lives in `scheme.error`; the accent in
/// `scheme.primary`. Access via [AppColors.of].
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color green;
  final Color orange;
  final Color blue;
  final Color purple;

  /// Hairline around cards and panels, or null for none: light mode's white
  /// cards and the near-black palettes need one to separate from the
  /// background.
  final Color? cardOutline;

  /// Card and panel fill: the surface with a trace of the accent. Null
  /// (bare-MaterialApp tests) means plain `scheme.surface`.
  final Color? cardFill;

  const AppColors({
    required this.green,
    required this.orange,
    required this.blue,
    required this.purple,
    this.cardOutline,
    this.cardFill,
  });

  /// Falls back to the dark set when the theme carries no extension
  /// (bare-`MaterialApp` widget tests).
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? AppColors.dark;

  static const dark = AppColors(
    green: FigmaPalette.green,
    orange: FigmaPalette.orange,
    blue: FigmaPalette.blue,
    purple: FigmaPalette.purple,
  );

  static const light = AppColors(
    green: FigmaPaletteLight.green,
    orange: FigmaPaletteLight.orange,
    blue: FigmaPaletteLight.blue,
    purple: FigmaPaletteLight.purple,
    cardOutline: FigmaPaletteLight.border,
  );

  @override
  AppColors copyWith({
    Color? green,
    Color? orange,
    Color? blue,
    Color? purple,
    Color? cardOutline,
    Color? cardFill,
  }) => AppColors(
    green: green ?? this.green,
    orange: orange ?? this.orange,
    blue: blue ?? this.blue,
    purple: purple ?? this.purple,
    cardOutline: cardOutline ?? this.cardOutline,
    cardFill: cardFill ?? this.cardFill,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      green: Color.lerp(green, other.green, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      cardOutline: Color.lerp(cardOutline, other.cardOutline, t),
      cardFill: Color.lerp(cardFill, other.cardFill, t),
    );
  }
}

/// The app's corner-radius scale. Every rounded corner should sit on one of
/// these tiers — an audit found 13 distinct ad-hoc radii, several of them
/// same-role-different-value (category avatars at 11 vs 12, icon-picker
/// tiles at 10, floating panels at 22).
///
///  * [control] — chips, inputs, icon tiles, small avatars
///  * [button]  — FAB / GlassButton / nav indicator
///  * [card]    — Cards, list tiles, inner panels
///  * [section] — FrostedPanel page sections
///  * [hero]    — hero balance panels, dialogs
///  * [sheet]   — bottom-sheet top corners
///
/// Tiny indicator radii (2–5, e.g. progress bars) stay literal.
abstract final class AppRadius {
  static const double control = 12;
  static const double button = 14;
  static const double card = 16;
  static const double section = 20;
  static const double hero = 24;
  static const double sheet = 28;
}

/// Memo for [buildAppTheme]: the `Consumer<SettingsProvider>` around
/// `MaterialApp` re-runs on every settings change (a threshold toggle, a
/// budget-cap commit), and each run used to construct both variants' full
/// `ColorScheme` + ~15 sub-themes from scratch. Keyed by the only inputs:
/// accent, brightness, and (dark only) the palette. Tiny.
final Map<(int, Brightness, AppPalette?), ThemeData> _themeCache = {};

/// Figma-kit theme in a dark and a light variant, tinted by the
/// user-selected [accent] (coral by default). In dark mode the structural
/// colours come from [palette]; light mode always uses [FigmaPaletteLight].
/// Screens style themselves via `scheme.*` and [AppColors], so the palettes
/// live here.
ThemeData buildAppTheme({
  required Brightness brightness,
  required Color accent,
  AppPalette palette = AppPalette.standard,
}) {
  final dark = brightness == Brightness.dark;
  final cacheKey = (accent.toARGB32(), brightness, dark ? palette : null);
  final cached = _themeCache[cacheKey];
  if (cached != null) return cached;
  final theme = _buildAppTheme(
    brightness: brightness,
    accent: accent,
    palette: palette,
  );
  _themeCache[cacheKey] = theme;
  return theme;
}

ThemeData _buildAppTheme({
  required Brightness brightness,
  required Color accent,
  required AppPalette palette,
}) {
  final dark = brightness == Brightness.dark;
  final p = palette.colors;

  final bg = dark ? p.bg : FigmaPaletteLight.bg;
  final surface = dark ? p.surface : FigmaPaletteLight.surface;
  final surface2 = dark ? p.surface2 : FigmaPaletteLight.surface2;
  final border = dark ? p.border : FigmaPaletteLight.border;
  final textPrimary = dark ? p.textPrimary : FigmaPaletteLight.textPrimary;
  final textSecondary = dark
      ? p.textSecondary
      : FigmaPaletteLight.textSecondary;
  final textMuted = dark ? p.textMuted : FigmaPaletteLight.textMuted;
  final blue = dark ? FigmaPalette.blue : FigmaPaletteLight.blue;
  final purple = dark ? FigmaPalette.purple : FigmaPaletteLight.purple;
  final pink = dark ? FigmaPalette.pink : FigmaPaletteLight.pink;
  // Dark ink for glyphs on bright fills (light accents, blue, purple).
  final ink = dark ? p.bg : FigmaPalette.bg;

  // Light accents (mint, sunset) need dark text/icons on top of them.
  final onAccent = accent.computeLuminance() > 0.45 ? ink : Colors.white;
  final accentLight = Color.lerp(accent, Colors.white, 0.35)!;
  final accentGlow = accent.withValues(alpha: 0.30);
  Color blend(Color c, double alpha) =>
      Color.alphaBlend(c.withValues(alpha: alpha), surface);

  final scheme = ColorScheme(
    brightness: brightness,

    primary: accent,
    onPrimary: onAccent,
    primaryContainer: blend(accent, 0.22),
    onPrimaryContainer: dark ? accentLight : accent,
    inversePrimary: accentLight,

    secondary: blue,
    onSecondary: dark ? ink : Colors.white,
    secondaryContainer: blend(blue, 0.22),
    onSecondaryContainer: textPrimary,

    tertiary: purple,
    onTertiary: dark ? ink : Colors.white,
    tertiaryContainer: blend(purple, 0.20),
    onTertiaryContainer: textPrimary,

    error: pink,
    onError: Colors.white,
    errorContainer: blend(pink, 0.22),
    // NOT the raw pink: text that is literally the colour its background is
    // a 22% wash of measured ~4.0:1 in both themes — under the 4.5:1 the
    // 14px data-loss banners need. Lightened on dark / deepened on light,
    // the pair reads at ~5–6:1.
    onErrorContainer: dark
        ? Color.lerp(pink, Colors.white, 0.25)!
        : Color.lerp(pink, Colors.black, 0.25)!,

    surface: surface,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    surfaceContainerLowest: bg,
    surfaceContainerLow: surface,
    surfaceContainer: surface,
    surfaceContainerHigh: surface2,
    surfaceContainerHighest: border,
    surfaceDim: bg,
    surfaceBright: surface2,

    outline: textMuted,
    outlineVariant: border,

    inverseSurface: dark ? const Color(0xFFF1F1F5) : FigmaPalette.surface,
    onInverseSurface: dark ? ink : Colors.white,
    surfaceTint: Colors.transparent, // no M3 elevation tinting
    shadow: Colors.black,
    scrim: Colors.black,
  );

  // Cards carry a trace of the accent, echoing AmbientBackground's glow.
  final cardFill = blend(accent, dark ? 0.05 : 0.035);
  final appColors = (!dark ? AppColors.light : AppColors.dark).copyWith(
    cardOutline: dark && p.outlineCards ? border : null,
    cardFill: cardFill,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [appColors],
    scaffoldBackgroundColor: bg,
    // Smooth fade-forward route transitions on every platform.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const FadeForwardsPageTransitionsBuilder(),
      },
    ),
    // Transparent so AmbientBackground's accent glow runs under the bar;
    // over a plain Scaffold it shows the same background as before.
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: appColors.cardFill,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: appColors.cardOutline == null
            ? BorderSide.none
            : BorderSide(color: appColors.cardOutline!),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface2,
      // Flutter renders helper/error text single-line with an ellipsis unless
      // told otherwise — full-sentence captions in narrow dialogs were being
      // cut ("A newer bank alert takes over aut…"). Let them wrap app-wide.
      helperMaxLines: 3,
      errorMaxLines: 2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      // Kit-style rounded-square tint behind the selected icon.
      indicatorColor: accent.withValues(alpha: 0.15),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? accent : textSecondary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? accent : textSecondary,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: onAccent,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? onAccent : textSecondary,
        ),
      ),
    ),
    chipTheme: const ChipThemeData(shape: StadiumBorder(side: BorderSide.none)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        elevation: 6,
        shadowColor: accentGlow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textSecondary,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.hero),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface2,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface2),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: border),
    // Snackbars float as bordered pills above the nav bar. The explicit
    // background keeps dark mode dark — the default inverseSurface flips the
    // app's look. They clear with a sideways swipe (the Android-notification
    // gesture people expect); the default only accepted a swipe down.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surface2,
      contentTextStyle: TextStyle(fontSize: 14, color: textPrimary),
      actionTextColor: accent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        side: BorderSide(color: border),
      ),
      elevation: 6,
      dismissDirection: DismissDirection.horizontal,
    ),
  );
  // Helper/description text renders muted by default: bare `bodySmall` used
  // to inherit full-contrast onSurface, so identical helper copy showed at
  // two different contrasts depending on whether the call site remembered
  // to set onSurfaceVariant. Explicit colours at call sites still win.
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      bodySmall: base.textTheme.bodySmall?.copyWith(color: textSecondary),
    ),
  );
}
