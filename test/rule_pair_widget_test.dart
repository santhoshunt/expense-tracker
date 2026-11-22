import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/utils/format.dart';
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

  /// A Food and Salary pair's second line, with what it [sets] when it
  /// sets more. Each part's words are held together and the line breaks
  /// only after a dot (joinFacts), as the row draws it at this width.
  String pairLine([String? sets]) => joinFacts([
    '↑ Food & Dining (expense)',
    '↓ Salary (income)',
    if (sets != null) 'sets $sets',
  ]);

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
      expect(find.text(pairLine()), findsOneWidget);
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

  /// Opens the sheet's Also set fold.
  Future<void> openAlsoSet(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Also set'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Also set'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, Finder field, String text) async {
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  final payeeField = find.byKey(const ValueKey('rule-payee'));
  final tagField = find.widgetWithText(TextField, 'Tags');

  // A confirmed SMS row no rule has sorted yet.
  Tx smsRow(String id, TxType type, String body) => Tx(
    id: id,
    type: type,
    categoryId: type == TxType.income ? 'other_income' : 'other_expense',
    amount: 250,
    note: '',
    date: DateTime(2026, 9, 12, 13),
    source: TxSource.sms,
    smsBody: body,
    sender: 'AD-DEMOBK',
  );

  testWidgets('a new rule pair saves the same Paid to and tags on both '
      'rules, counts both directions, and the tile says what it sets', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      smsRow('out', TxType.expense, 'Rs 250 sent to MEERAVALLI by UPI'),
      smsRow('in', TxType.income, 'Rs 250 received from MEERAVALLI by UPI'),
    ]);
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    await tester.enterText(
      inDialog(find.byType(TextField)).first,
      'meeravalli',
    );
    await tester.pump();
    await classifyAs(tester, 'Food & Dining');
    await openAlsoSet(tester);
    await type(tester, payeeField, 'Meera');
    // One direction so far: only money out matches.
    expect(
      find.text('Fills Paid to where you typed none. 1 past payment changes.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Money in goes to another category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other direction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salary').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Fills Paid to where you typed none. 2 past payments change.'),
      findsOneWidget,
    );
    await type(tester, tagField, 'Family,');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final mine = p.rules.where((r) => !r.isBuiltIn).toList();
    expect(mine, hasLength(2));
    expect(mine.map((r) => r.categoryId).toSet(), {'food', 'salary'});
    for (final r in mine) {
      expect(r.payee, 'Meera', reason: r.categoryId);
      expect(r.tags, ['Family'], reason: r.categoryId);
    }
    for (final t in p.transactions) {
      expect(t.payee, 'Meera', reason: t.id);
      expect(t.tags, ['Family'], reason: t.id);
    }
    expect(find.text('2 transactions reclassified'), findsOneWidget);

    // The title is as it was; the second line gains what the pair sets.
    expect(find.text('contains "meeravalli"'), findsOneWidget);
    expect(find.text(pairLine('Paid to, 1 tag')), findsOneWidget);

    // Undo takes both rules and both rows back.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn), isEmpty);
    for (final t in p.transactions) {
      expect(t.payee, isEmpty, reason: t.id);
      expect(t.tags, isEmpty, reason: t.id);
      expect(t.categoryId, startsWith('other_'), reason: t.id);
    }
  });

  testWidgets('editing a rule pair writes a changed Paid to and tags to '
      'both rules; a rule that sets nothing keeps its plain second line', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('plainwords', 'transport');
    await p.addRule('amma', 'food', tags: ['Family']);
    await p.addRule('amma', 'salary', tags: ['Family']);
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    expect(find.text(pairLine('1 tag')), findsOneWidget);
    expect(
      find.text('→ ${categoryById('transport').label} (expense)'),
      findsOneWidget,
    );

    await tester.tap(find.text('contains "amma"'));
    await tester.pumpAndSettle();
    expect(find.text('Edit rule pair'), findsOneWidget);
    // A pair that sets more opens with the fold open.
    expect(payeeField, findsOneWidget);
    expect(find.text('# Family'), findsOneWidget);
    await type(tester, payeeField, 'Amma');
    await type(tester, tagField, 'Home');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final pair = p.rules.where((r) => r.pattern == 'amma').toList();
    expect(pair, hasLength(2));
    for (final r in pair) {
      expect(r.payee, 'Amma', reason: r.categoryId);
      expect(r.tags, ['Family', 'Home'], reason: r.categoryId);
    }
    expect(find.text(pairLine('Paid to, 2 tags')), findsOneWidget);
  });

  // v2.3.0 review: the row said "sets Paid to" for one income rule, whose
  // editor calls the field Received from, and for a rule whose category
  // had since become a transfer, which fills no Paid to.
  testWidgets('a rule row says Received from for one income rule, and '
      'leaves out the Paid to of a rule in a transfer category', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final fund = await p.addCategory(
      label: 'Chit fund',
      type: TxType.expense,
      icon: Icons.fastfood,
      color: Colors.teal,
    );
    await p.addRule('zephyrine', fund, payee: 'Zephyrine', tags: ['Home']);
    await p.addRule('mapleworth', fund, payee: 'Mapleworth');
    await p.addRule('quillfern', 'food', payee: 'Quillfern Teas');
    await p.addRule(
      'meeravalli',
      'salary',
      payee: 'Meeravalli Works',
      tags: ['Office'],
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    Finder lineOf(String pattern, List<String> facts) => find.descendant(
      of: find.ancestor(
        of: find.text('contains "$pattern"'),
        matching: find.byType(ListTile),
      ),
      matching: find.text(joinFacts(facts)),
    );
    expect(
      lineOf('meeravalli', ['→ Salary (income)', 'sets Received from, 1 tag']),
      findsOneWidget,
    );
    expect(
      lineOf('quillfern', ['→ Food & Dining (expense)', 'sets Paid to']),
      findsOneWidget,
    );
    const toFund = '→ Chit fund (expense)';
    expect(
      lineOf('zephyrine', [toFund, 'sets Paid to, 1 tag']),
      findsOneWidget,
    );
    expect(lineOf('mapleworth', [toFund, 'sets Paid to']), findsOneWidget);

    // The category becomes a transfer: its rules fill no Paid to now.
    await p.updateCategory(
      TxCategory(
        id: fund,
        label: 'Chit fund',
        icon: Icons.fastfood,
        color: Colors.teal,
        type: TxType.expense,
        isTransfer: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(lineOf('zephyrine', [toFund, 'sets 1 tag']), findsOneWidget);
    // One part alone is shown as it is, with nothing after it.
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('contains "mapleworth"'),
          matching: find.byType(ListTile),
        ),
        matching: find.text(toFund),
      ),
      findsOneWidget,
    );
    // The Food rule's row alone still says it.
    expect(find.textContaining(joinFacts(['sets Paid to'])), findsOneWidget);
    // Display only: the rules keep what they stored.
    String payeeOf(String pattern) =>
        p.rules.firstWhere((r) => r.pattern == pattern).payee;
    expect(payeeOf('zephyrine'), 'Zephyrine');
    expect(payeeOf('mapleworth'), 'Mapleworth');
  });

  testWidgets('a pair of two rules made apart shows and opens on what '
      'either rule sets, and saving writes it to both', (tester) async {
    final p = FinanceProvider();
    await p.load();
    // The older rule sets both; the newer one, which sets nothing, was
    // made on its own later.
    await p.addRule('amma', 'food', payee: 'Amma', tags: ['Family']);
    await p.addRule('amma', 'salary');
    // One field on each rule.
    await p.addRule('meeravalli', 'salary', tags: ['Home']);
    await p.addRule('meeravalli', 'food', payee: 'Meera');
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    final both = pairLine('Paid to, 1 tag');
    expect(find.text(both), findsNWidgets(2));

    Future<void> saveUntouched(String pattern) async {
      await tester.tap(find.text('contains "$pattern"'));
      await tester.pumpAndSettle();
      expect(find.text('Edit rule pair'), findsOneWidget);
      // A pair that sets more opens with the fold open.
      expect(payeeField, findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('contains "amma"'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(payeeField).controller!.text, 'Amma');
    expect(find.text('# Family'), findsOneWidget);
    await closeSheet(tester);
    // Nothing was typed, so the sheet closed without asking.
    expect(find.byType(EditorSheetBody), findsNothing);

    await saveUntouched('amma');
    for (final r in p.rules.where((r) => r.pattern == 'amma')) {
      expect(r.payee, 'Amma', reason: r.categoryId);
      expect(r.tags, ['Family'], reason: r.categoryId);
    }

    await tester.tap(find.text('contains "meeravalli"'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(payeeField).controller!.text, 'Meera');
    expect(find.text('# Home'), findsOneWidget);
    await closeSheet(tester);
    await saveUntouched('meeravalli');
    for (final r in p.rules.where((r) => r.pattern == 'meeravalli')) {
      expect(r.payee, 'Meera', reason: r.categoryId);
      expect(r.tags, ['Home'], reason: r.categoryId);
    }
    expect(find.text(both), findsNWidgets(2));
  });

  testWidgets('merging rules that change past rows only in their tags says '
      'how many were updated, and Undo takes it back', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('mapleworth', 'food');
    await p.addRule('quillfern', 'food', tags: ['Office']);
    // Loaded after the rules and already in their category: no rule has
    // touched it.
    await p.restoreTransactions([
      smsRow(
        'm1',
        TxType.expense,
        'Rs 250 paid to MAPLEWORTH DEPOT',
      ).copyWith(categoryId: 'food'),
    ]);
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('contains "quillfern"'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('contains "mapleworth"'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();

    expect(find.text('Merged 2 rules · 1 transaction updated'), findsOneWidget);
    expect(p.rules.where((r) => !r.isBuiltIn), hasLength(1));
    expect(p.transactions.single.tags, ['Office']);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn), hasLength(2));
    expect(p.transactions.single.tags, isEmpty);
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
