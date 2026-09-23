import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/undo_snackbar.dart';

/// Toasts lead with the operation's own icon, tinted by the kind of
/// outcome: removals rose, edits accent, confirmations green.
void main() {
  final theme = buildAppTheme(
    brightness: Brightness.dark,
    accent: FigmaPalette.primary,
  );

  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  Color tintOf(WidgetTester tester, IconData icon) =>
      tester.widget<Icon>(find.byIcon(icon)).color!;

  testWidgets('an undo toast shows its operation icon and undoes', (
    tester,
  ) async {
    final ctx = await host(tester);
    var undone = false;
    showUndoSnackBar(
      ctx,
      'Deleted Food',
      () => undone = true,
      icon: Icons.delete_outline,
      tone: AppToastTone.removal,
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.undo), findsNothing);
    expect(tintOf(tester, Icons.delete_outline), theme.colorScheme.error);

    await tester.tap(find.text('Undo'));
    expect(undone, isTrue);
  });

  testWidgets('edits tint with the accent by default', (tester) async {
    final ctx = await host(tester);
    showUndoSnackBar(
      ctx,
      'Category set on 2 transactions.',
      () {},
      icon: Icons.category_outlined,
    );
    await tester.pumpAndSettle();
    expect(tintOf(tester, Icons.category_outlined), theme.colorScheme.primary);
  });

  testWidgets('confirmations tint green', (tester) async {
    final ctx = await host(tester);
    showAppToast(
      ctx,
      'Saved to Downloads',
      tone: AppToastTone.success,
      icon: Icons.download_done,
    );
    await tester.pumpAndSettle();
    expect(
      tintOf(tester, Icons.download_done),
      theme.extension<AppColors>()!.green,
    );
  });

  testWidgets('a tone without an icon falls back to its own', (tester) async {
    final ctx = await host(tester);
    showAppToast(ctx, 'Nothing to export.');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });
}
