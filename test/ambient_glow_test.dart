import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_palettes.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// The background glow and the card tint both come from the accent, so a
/// new accent recolours them; neither is a fixed coral.
void main() {
  List<RadialGradient> glowsOf(WidgetTester tester) => [
    for (final box in tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(AmbientBackground),
        matching: find.byType(DecoratedBox),
      ),
    ))
      if ((box.decoration as BoxDecoration).gradient
          case final RadialGradient g)
        g,
  ];

  for (final accent in [FigmaPalette.primary, FigmaPalette.blue]) {
    testWidgets('glow follows the accent (${accent.toARGB32()})', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark, accent: accent),
          home: const AmbientBackground(child: SizedBox.expand()),
        ),
      );
      final glows = glowsOf(tester);
      expect(glows, hasLength(2), reason: 'top-left and bottom-right');
      for (final g in glows) {
        expect(g.colors.first.withValues(alpha: 1), accent);
        expect(g.colors.last.a, 0, reason: 'fades out');
      }
    });
  }

  test('cards carry a trace of the accent over the palette surface', () {
    for (final p in [AppPalette.standard, AppPalette.nord]) {
      final theme = buildAppTheme(
        brightness: Brightness.dark,
        accent: FigmaPalette.green,
        palette: p,
      );
      final fill = theme.extension<AppColors>()!.cardFill!;
      expect(theme.cardTheme.color, fill);
      expect(fill, isNot(p.colors.surface), reason: 'tinted');
      expect(
        fill,
        Color.alphaBlend(
          FigmaPalette.green.withValues(alpha: 0.05),
          p.colors.surface,
        ),
      );
    }
  });
}
