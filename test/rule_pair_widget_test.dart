import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/widgets/editor_sheet.dart';

Widget app(FinanceProvider p) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: p),
    ChangeNotifierProvider(create: (_) => SettingsProvider()),
  ],
  child: const MaterialApp(
    home: ClassifiersScreen(initialTab: kCockpitTabRules),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// Picks [label] in Classify as.
  Future<void> classifyAs(WidgetTester tester, String label) async {
    await tester.tap(find.text('Classify as'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// Closes the rule sheet from its handle, discarding anything typed.
  Future<void> closeSheet(WidgetTester tester) async {
    await tester.drag(
      find.byKey(const ValueKey('editor-sheet-handle')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    if (find.text('Discard').evaluate().isNotEmpty) {
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
    }
  }

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
      // The Rules tab's search box sits behind the sheet: target the
      // sheet's own condition field.
      await tester.enterText(
        find
            .descendant(
              of: find.byType(EditorSheetBody),
              matching: find.byType(TextField),
            )
            .first,
        'amma',
      );
      await tester.pump();

      // Food & Dining (expense) first, so the second slot offers income
      // categories, behind its closed expander.
      await classifyAs(tester, 'Food & Dining');
      await tester.tap(find.text('Money in goes to another category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other direction'));
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
      // The pair row shows its primary rule's category icon (one of the
      // pair's two), not a two-way arrow.
      expect(find.byIcon(Icons.swap_vert), findsNothing);
      final pairTile = find.ancestor(
        of: find.text('contains "amma"'),
        matching: find.byType(ListTile),
      );
      final pairIcons = {
        for (final id in ['food', 'salary']) categoryById(id).icon,
      };
      expect(
        tester
            .widgetList<Icon>(
              find.descendant(of: pairTile, matching: find.byType(Icon)),
            )
            .where((i) => pairIcons.contains(i.icon)),
        hasLength(1),
      );

      // Editing the pair pre-fills the second slot.
      await tester.tap(find.text('contains "amma"'));
      await tester.pumpAndSettle();
      expect(find.text('Edit rule pair'), findsOneWidget);
      // In a field and, on the open expander's line, as its value.
      expect(
        find.descendant(
          of: find.byType(EditorSheetBody),
          matching: find.text('Salary'),
        ),
        findsWidgets,
      );
      await closeSheet(tester);

      // Delete in the pair's editor removes both rules; Undo restores both.
      await tester.tap(find.text('contains "amma"'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rule actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete rule pair'));
      await tester.pumpAndSettle();
      expect(find.text('Deleted rule pair "amma"'), findsOneWidget);
      expect(p.rules.where((r) => !r.isBuiltIn), isEmpty);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.rules.where((r) => !r.isBuiltIn), hasLength(2));
      expect(find.text('contains "amma"'), findsOneWidget);
    },
  );

  Finder inDialog(Finder f) =>
      find.descendant(of: find.byType(EditorSheetBody), matching: f);

  testWidgets('New rule reads the conditions, then the Add box, then the '
      'category, then a closed expander for the other direction', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();

    // Nothing to classify as yet: the footer says so, and the other
    // direction waits for a category to oppose.
    expect(find.text('Pick what to classify as'), findsOneWidget);
    expect(find.text('Money in goes to another category'), findsNothing);
    await classifyAs(tester, 'Food & Dining');

    double top(Finder f) => tester.getTopLeft(f).dy;
    final condition = inDialog(find.byType(TextField)).first;
    final classifyAsField = find.text('Classify as');
    final expander = find.text('Money in goes to another category');
    final conditions = find.text('If the SMS contains any of (0)');
    expect(top(conditions), lessThan(top(condition)));
    expect(top(condition), lessThan(top(classifyAsField)));
    expect(top(classifyAsField), lessThan(top(expander)));
    // The old always-on paragraph and doubled helper are gone.
    expect(find.textContaining('Add another condition'), findsNothing);
    expect(find.textContaining('Rules only fire'), findsNothing);
    final food = categoryById('food').label;
    expect(
      find.text('Ignores case. Only money out matches $food.'),
      findsOneWidget,
    );

    // A closed fold builds nothing.
    expect(find.text('Other direction'), findsNothing);
    expect(find.text('Not set'), findsOneWidget);
    await tester.tap(expander);
    await tester.pumpAndSettle();
    expect(find.text('Other direction'), findsOneWidget);

    // '|' would split the condition; the error names the button instead.
    await tester.enterText(condition, 'amma|appa');
    await tester.pump();
    expect(find.text('Remove "|". Add each word on its own.'), findsWidgets);
    await closeSheet(tester);

    // An income rule flips the expander to money out. Opened from its row:
    // the category picker lists income below the fold of a lazy list.
    await p.addRule('salary words', 'salary');
    await tester.pumpAndSettle();
    await tester.tap(find.text('contains "salary words"'));
    await tester.pumpAndSettle();
    expect(find.text('Edit rule'), findsOneWidget);
    expect(find.text('Money out goes to another category'), findsOneWidget);
  });

  testWidgets('Add turns the box into a chip and keeps it focused', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    final box = inDialog(find.byType(TextField)).first;
    await tester.enterText(box, 'amma');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    // One field still: the word moved into a chip and the box is empty,
    // focused for the next one.
    expect(inDialog(find.byType(TextField)), findsOneWidget);
    expect(inDialog(find.byType(InputChip)), findsOneWidget);
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    expect(tester.widget<TextField>(box).focusNode!.hasFocus, isTrue);
    expect(find.text('If the SMS contains any of (1)'), findsOneWidget);

    await tester.enterText(box, 'appa');
    await classifyAs(tester, 'Food & Dining');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn).single.pattern, 'amma | appa');
  });

  testWidgets('clearing the second slot deletes the twin', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma', 'food');
    await p.addRule('amma', 'salary');
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    await tester.tap(find.text('contains "amma"'));
    await tester.pumpAndSettle();
    // A pair opens with its expander open: no tap needed to reach it.
    await tester.tap(find.text('Other direction'));
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
