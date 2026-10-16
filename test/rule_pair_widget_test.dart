import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/widgets/animated_fold.dart';

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
      // income categories, behind its closed expander.
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

  Finder inDialog(Finder f) =>
      find.descendant(of: find.byType(AlertDialog), matching: f);

  testWidgets('New rule reads category, then the Add box, then a closed '
      'expander for the other direction, then the conditions', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();

    double top(Finder f) => tester.getTopLeft(f).dy;
    final condition = inDialog(find.byType(TextField)).first;
    final classifyAs = find.text('Classify as');
    final expander = find.text('Money in goes to another category');
    final conditions = find.text('If the SMS contains any of (0)');
    expect(top(classifyAs), lessThan(top(condition)));
    expect(top(condition), lessThan(top(expander)));
    expect(top(expander), lessThan(top(conditions)));
    // The old always-on paragraph and doubled helper are gone.
    expect(find.textContaining('Add another condition'), findsNothing);
    expect(find.textContaining('Rules only fire'), findsNothing);
    final food = categoryById('food').label;
    expect(
      find.text('Ignores case. Only money out matches $food.'),
      findsOneWidget,
    );

    AnimatedFold fold() => tester.widget<AnimatedFold>(
      find.ancestor(
        of: find.text('Other direction'),
        matching: find.byType(AnimatedFold),
      ),
    );
    expect(fold().collapsed, isTrue);
    await tester.tap(expander);
    await tester.pumpAndSettle();
    expect(fold().collapsed, isFalse);

    // '|' would split the condition; the error names the button instead.
    await tester.enterText(condition, 'amma|appa');
    await tester.pump();
    expect(find.text('Remove "|". Add each word on its own.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

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
