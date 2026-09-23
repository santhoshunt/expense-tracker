import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/utils/app_palettes.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/contrast.dart';
import 'package:expense_tracker/utils/figma_palette.dart';

/// Selectable dark themes: persistence, the accent they bring along,
/// readable text on every palette, and light mode staying untouched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('palette persists, sets its accent, and rides the backup', () async {
    final s = SettingsProvider();
    await s.load();
    expect(s.palette, AppPalette.standard, reason: 'default');
    expect(s.accent, FigmaPalette.primary);

    await s.setPalette(AppPalette.midnight);
    expect(s.accent, AppPalette.midnight.colors.accent);

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.palette, AppPalette.midnight);
    expect(reloaded.accent, AppPalette.midnight.colors.accent);

    // The accent stays changeable after picking a theme.
    await reloaded.setAccent(FigmaPalette.green);
    expect(reloaded.palette, AppPalette.midnight);
    expect(reloaded.accent, FigmaPalette.green);

    expect(s.toBackupMap()['palette'], 'midnight');
    final fresh = SettingsProvider();
    await fresh.load();
    await fresh.applyBackupMap({'palette': 'nord'});
    expect(fresh.palette, AppPalette.nord);
  });

  test('a garbage stored or backup value falls back', () async {
    SharedPreferences.setMockInitialValues({'palette_v1': 'plaid'});
    final s = SettingsProvider();
    await s.load();
    expect(s.palette, AppPalette.standard);

    await s.setPalette(AppPalette.forest);
    await s.applyBackupMap({'palette': 7});
    expect(s.palette, AppPalette.forest);
  });

  test('every palette keeps its text and accent readable', () {
    for (final p in AppPalette.values) {
      final c = p.colors;
      expect(
        contrastRatio(c.textPrimary, c.surface),
        greaterThanOrEqualTo(4.5),
        reason: '${p.name} primary text',
      );
      expect(
        contrastRatio(c.textSecondary, c.surface),
        greaterThanOrEqualTo(4.5),
        reason: '${p.name} secondary text',
      );
      expect(
        contrastRatio(c.textMuted, c.surface),
        greaterThanOrEqualTo(3),
        reason: '${p.name} muted text',
      );
      expect(
        contrastRatio(c.accent, c.surface),
        greaterThanOrEqualTo(3),
        reason: '${p.name} accent',
      );
    }
  });

  test('the standard palette is the original look', () {
    final c = AppPalette.standard.colors;
    expect(c.bg, FigmaPalette.bg);
    expect(c.surface, FigmaPalette.surface);
    expect(c.accent, FigmaPalette.primary);
  });

  test('near-black themes outline their cards', () {
    for (final p in AppPalette.values) {
      final dark = buildAppTheme(
        brightness: Brightness.dark,
        accent: FigmaPalette.primary,
        palette: p,
      );
      final outline = dark.extension<AppColors>()!.cardOutline;
      final side = (dark.cardTheme.shape! as RoundedRectangleBorder).side;
      if (p.colors.outlineCards) {
        expect(outline, p.colors.border, reason: p.name);
        expect(side.color, p.colors.border, reason: p.name);
      } else {
        expect(outline, isNull, reason: p.name);
        expect(side, BorderSide.none, reason: p.name);
      }
    }
    expect(AppPalette.amoled.colors.outlineCards, isTrue);

    // Light mode keeps its hairline regardless of palette.
    final light = buildAppTheme(
      brightness: Brightness.light,
      accent: FigmaPalette.primary,
    );
    expect(light.extension<AppColors>()!.cardOutline, FigmaPaletteLight.border);
  });

  test('dark themes follow the palette, light themes ignore it', () {
    for (final p in AppPalette.values) {
      final dark = buildAppTheme(
        brightness: Brightness.dark,
        accent: FigmaPalette.primary,
        palette: p,
      );
      expect(dark.scaffoldBackgroundColor, p.colors.bg, reason: p.name);
      expect(dark.colorScheme.surface, p.colors.surface, reason: p.name);

      final light = buildAppTheme(
        brightness: Brightness.light,
        accent: FigmaPalette.primary,
        palette: p,
      );
      expect(light.scaffoldBackgroundColor, FigmaPaletteLight.bg);
      expect(light.colorScheme.surface, FigmaPaletteLight.surface);
    }
  });
}
