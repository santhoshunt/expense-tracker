import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_palettes.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// The background glow and the card tint both come from the accent, so a
/// new accent recolours them; neither is a fixed coral.
void main() {
  AmbientGlowPainter painterOf(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find
                    .descendant(
                      of: find.byType(AmbientBackground),
                      matching: find.byType(CustomPaint),
                    )
                    .first,
              )
              .painter!
          as AmbientGlowPainter;
  List<RadialGradient> glowsOf(WidgetTester tester) =>
      painterOf(tester).glows(Offset.zero);

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
      expect(glows, hasLength(2), reason: 'top-right and bottom-right');
      for (final g in glows) {
        expect(g.colors.first.withValues(alpha: 1), accent);
        expect(g.colors.last.a, 0, reason: 'fades out');
      }
    });
  }

  testWidgets('the main glow rests top right and drifts with the tilt', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.dark,
          accent: FigmaPalette.blue,
        ),
        home: const AmbientBackground(child: SizedBox.expand()),
      ),
    );
    final painter = painterOf(tester);
    final rest = painter.glows(Offset.zero);
    expect((rest.first.center as Alignment).x, greaterThan(1));
    expect((rest.first.center as Alignment).y, lessThan(-1));
    expect((rest.last.center as Alignment).y, greaterThan(1));
    final tilted = painter.glows(const Offset(-1, 0));
    expect(
      (tilted.first.center as Alignment).x,
      closeTo(0.95, 1e-9),
      reason: 'noticeable: a quarter of the half-width',
    );
    expect(
      (tilted.last.center as Alignment).x,
      greaterThan((rest.last.center as Alignment).x),
      reason: 'the faint glow moves the other way',
    );
  });

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
