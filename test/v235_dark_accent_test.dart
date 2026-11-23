import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/transaction.dart'
    show kCategoryColorChoices;
import 'package:expense_tracker/utils/app_palettes.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/contrast.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/info_tip.dart';
import 'package:expense_tracker/widgets/undo_snackbar.dart';

/// v2.3.5: in the dark theme, text buttons and the toast's action use the
/// accent lightened just enough to read at 4.5 to 1 on the toast fill and
/// the dialog surface. Everything else keeps the raw accent.
void main() {
  const accent = FigmaPalette.defaultAccent;

  Color textButton(ThemeData t) =>
      t.textButtonTheme.style!.foregroundColor!.resolve(const {})!;

  String hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

  ThemeData darkTheme(AppPalette p, [Color a = accent]) =>
      buildAppTheme(brightness: Brightness.dark, accent: a, palette: p);

  test('every dark palette reads at 4.5 to 1 on its dialog surface and '
      'toast fill, with the default accent and its own', () {
    for (final p in AppPalette.values) {
      for (final a in {accent, p.colors.accent}) {
        final t = darkTheme(p, a);
        final button = textButton(t);
        expect(t.snackBarTheme.actionTextColor, button, reason: p.name);
        expect(t.dialogTheme.backgroundColor, p.colors.surface);
        expect(t.snackBarTheme.backgroundColor, p.colors.surface2);
        final onDialog = contrastRatio(button, p.colors.surface);
        final onToast = contrastRatio(button, p.colors.surface2);
        expect(onDialog, greaterThanOrEqualTo(4.5), reason: p.name);
        expect(onToast, greaterThanOrEqualTo(4.5), reason: p.name);
        if (a == accent) {
          // The table in the change's report.
          debugPrint(
            '${p.name} ${hex(button)} dialog ${onDialog.toStringAsFixed(2)} '
            'toast ${onToast.toStringAsFixed(2)} (raw '
            '${contrastRatio(accent, p.colors.surface).toStringAsFixed(2)} / '
            '${contrastRatio(accent, p.colors.surface2).toStringAsFixed(2)})',
          );
        }
      }
    }
  });

  test('the default palette gets the default accent lightened one step', () {
    final t = darkTheme(AppPalette.standard);
    expect(hex(textButton(t)), '#5C9BE5');
    // Only text buttons and the toast action: filled buttons and the scheme
    // keep the accent.
    expect(t.colorScheme.primary, accent);
    expect(
      t.filledButtonTheme.style!.backgroundColor!.resolve(const {}),
      accent,
    );
  });

  test('an accent that already passes is left as it is', () {
    const pale = Color(0xFF9CC3F5);
    for (final p in AppPalette.values) {
      expect(
        contrastRatio(pale, p.colors.surface2),
        greaterThanOrEqualTo(4.5),
        reason: p.name,
      );
      expect(textButton(darkTheme(p, pale)), pale, reason: p.name);
    }
  });

  test('the light theme is as before', () {
    for (final a in [
      accent,
      const Color(0xFF00E5FF),
      const Color(0xFF6FD08C),
    ]) {
      final t = buildAppTheme(brightness: Brightness.light, accent: a);
      final expected = darkenForContrast(a, FigmaPaletteLight.surface2, 4.5);
      expect(textButton(t), expected);
      expect(t.snackBarTheme.actionTextColor, expected);
    }
    expect(
      hex(
        textButton(buildAppTheme(brightness: Brightness.light, accent: accent)),
      ),
      '#1E67BC',
    );
  });

  test('lightenForContrast stops when the ratio cannot be had and returns '
      'the best it reached', () {
    const grey = Color(0xFF2D303E);
    final best = lightenForContrast(accent, grey, 21);
    expect(HSLColor.fromColor(best).lightness, closeTo(0.95, 0.01));
    expect(contrastRatio(best, grey), greaterThan(contrastRatio(accent, grey)));
    // On white, lighter only reads worse: the accent itself is the best.
    expect(lightenForContrast(accent, Colors.white, 4.5), accent);
  });

  testWidgets("a dark dialog's text button and the toast's Undo use the "
      'lightened accent', (tester) async {
    final dark = darkTheme(AppPalette.standard);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUndoSnackBar(
                context,
                'Test row deleted',
                () {},
                icon: Icons.delete_outline,
              ),
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    final undo = DefaultTextStyle.of(tester.element(find.text('Undo')));
    expect(undo.style.color, textButton(dark));
    expect(
      contrastRatio(undo.style.color!, AppPalette.standard.colors.surface2),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets("an info tip's Got it reads at 4.5 to 1 on the bubble", (
    tester,
  ) async {
    final dark = darkTheme(AppPalette.standard);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark,
        home: const Scaffold(
          body: Center(
            child: InfoTip(title: 'Test tip', message: 'A made-up message.'),
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('About Test tip'));
    await tester.pumpAndSettle();
    final gotIt = DefaultTextStyle.of(tester.element(find.text('Got it')));
    final fill = dark.colorScheme.surfaceContainerHigh;
    expect(gotIt.style.color, textButton(dark));
    expect(contrastRatio(gotIt.style.color!, fill), greaterThanOrEqualTo(4.5));
  });

  test('every category swatch as the accent reads at 4.5 to 1 on every dark '
      "palette's toast fill", () {
    for (final p in AppPalette.values) {
      for (final c in kCategoryColorChoices) {
        expect(
          contrastRatio(textButton(darkTheme(p, c)), p.colors.surface2),
          greaterThanOrEqualTo(4.5),
          reason: '${p.name} ${hex(c)}',
        );
      }
    }
  });
}
