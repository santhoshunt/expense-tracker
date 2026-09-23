import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// The primary-action button wears the tab thumb's look: a quiet fill with
/// an accent edge light, not a solid accent slab.
void main() {
  testWidgets('quiet fill, accent rim, neutral label, still tappable', (
    tester,
  ) async {
    final theme = buildAppTheme(
      brightness: Brightness.dark,
      accent: FigmaPalette.primary,
    );
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          floatingActionButton: GlassButton(
            icon: Icons.add,
            label: 'Add',
            onPressed: () => taps++,
          ),
        ),
      ),
    );

    final box = tester.widget<Container>(
      find.ancestor(of: find.text('Add'), matching: find.byType(Container)),
    );
    final fill = box.decoration! as BoxDecoration;
    final rim = box.foregroundDecoration! as BoxDecoration;
    final scheme = theme.colorScheme;
    expect(fill.color, scheme.outlineVariant);
    expect(
      (rim.border! as Border).top.color,
      scheme.primary.withValues(alpha: 0.55),
    );
    expect(
      tester.widget<Text>(find.text('Add')).style!.color,
      scheme.onSurface,
    );

    await tester.tap(find.text('Add'));
    expect(taps, 1);
  });
}
