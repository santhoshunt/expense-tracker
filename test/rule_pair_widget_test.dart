import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';

Widget app(FinanceProvider p) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: p),
    ChangeNotifierProvider(create: (_) => SettingsProvider()),
  ],
  child: const MaterialApp(home: ClassifiersScreen()),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  testWidgets(
    'editor creates a rule pair; tile shows both; delete undoes both',
    (tester) async {
      final p = FinanceProvider();
      await p.load();
      final seeded = p.rules.length; // built-ins
      await tester.pumpWidget(app(p));
      await tester.pumpAndSettle();

      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
      // The Rules tab's search box sits behind the dialog: target the
      // dialog's own condition field.
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'amma',
      );
      await tester.pump();

      // Default target is Food & Dining (expense), so the second slot offers
      // income categories.
      await tester.tap(find.text('And when money moves the other way'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salary').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final mine = p.rules.where((r) => !r.isBuiltIn).toList();
      expect(mine, hasLength(2));
      expect(mine.map((r) => r.pattern).toSet(), {'amma'});
      expect(mine.map((r) => r.categoryId).toSet(), {'food', 'salary'});
      expect(p.rules.length, seeded + 2);

      // One tile for the pair, expense side first.
      expect(find.text('contains "amma"'), findsOneWidget);
      expect(
        find.text('↑ Food & Dining (expense) · ↓ Salary (income)'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.swap_vert), findsOneWidget);

      // Editing the pair pre-fills the second slot.
      await tester.tap(find.text('contains "amma"'));
      await tester.pumpAndSettle();
      expect(find.text('Edit rule pair'), findsOneWidget);
      expect(find.text('Salary'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Deleting the tile removes both rules; Undo restores both.
      await tester.tap(find.byTooltip('Delete rule pair'));
      await tester.pumpAndSettle();
      expect(p.rules.where((r) => !r.isBuiltIn), isEmpty);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.rules.where((r) => !r.isBuiltIn), hasLength(2));
      expect(find.text('contains "amma"'), findsOneWidget);
    },
  );

  testWidgets('clearing the second slot deletes the twin', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma', 'food');
    await p.addRule('amma', 'salary');
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    await tester.tap(find.text('contains "amma"'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('And when money moves the other way'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not for this direction').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final mine = p.rules.where((r) => !r.isBuiltIn).toList();
    expect(mine, hasLength(1));
    expect(
      find.text(
        '→ ${categoryById(mine.single.categoryId).label} '
        '(${mine.single.categoryId == 'salary' ? 'income' : 'expense'})',
      ),
      findsOneWidget,
    );
  });
}
