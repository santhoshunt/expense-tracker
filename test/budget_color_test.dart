import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';

/// One ladder for every budget ring and bar, matching the home widget:
/// green below 80%, orange from 80%, red above 95%.
void main() {
  testWidgets('green, orange from 80%, red above 95%', (tester) async {
    final theme = buildAppTheme(
      brightness: Brightness.dark,
      accent: FigmaPalette.primary,
    );
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final colors = theme.extension<AppColors>()!;
    expect(budgetColor(ctx, 0.79), colors.green);
    expect(budgetColor(ctx, 0.80), colors.orange);
    expect(budgetColor(ctx, 0.94), colors.orange);
    expect(budgetColor(ctx, 0.95), colors.orange);
    expect(budgetColor(ctx, 0.96), theme.colorScheme.error);
    expect(budgetColor(ctx, 1.4), theme.colorScheme.error);
  });
}
