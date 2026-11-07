import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/widgets/editor_sheet.dart';

/// The rule sheet (pick B): the conditions as chips, the Add box under
/// them, then Classify as, with Create or Save pinned at the bottom so a
/// rule with many conditions saves without scrolling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const fifteen = [
    'swiggy',
    'zomato',
    'tasty corner',
    'dominos',
    'chai stall',
    'blinkit',
    'zepto',
    'bigbasket',
    'eatfit',
    'faasos',
    'behrouz',
    'kfc',
    'mcdonalds',
    'burger king',
    'subway',
  ];

  Future<void> open(
    WidgetTester tester,
    FinanceProvider p,
    Future<void> Function(BuildContext) show, {
    Size size = const Size(360, 640),
    double textScale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder inRuleDialog(Finder f) =>
      find.descendant(of: find.byType(EditorSheetBody).first, matching: f);
  final addBox = find.widgetWithText(TextField, 'Add a word…');
  Finder chips() => inRuleDialog(find.byType(InputChip));
  Finder button(String label) => find.widgetWithText(FilledButton, label);
  bool enabled(WidgetTester tester, Finder f) =>
      tester.widget<ButtonStyleButton>(f).onPressed != null;
  String boxText(WidgetTester tester) =>
      tester.widget<TextField>(addBox).controller!.text;
  bool boxFocused(WidgetTester tester) =>
      tester.widget<TextField>(addBox).focusNode!.hasFocus;

  Future<ClassifierRule> fifteenRule(FinanceProvider p) async {
    await p.addRule(fifteen.join(' | '), 'food');
    return p.rules.firstWhere((r) => !r.isBuiltIn);
  }

  /// Picks [label] in Classify as.
  Future<void> classifyAs(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text('Classify as'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Classify as'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// Closes the sheet from its handle, discarding what was typed.
  Future<void> discard(WidgetTester tester) async {
    await tester.drag(
      find.byKey(const ValueKey('editor-sheet-handle')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
  }

  testWidgets('a rule of 15 conditions reads chips, the Add box, then '
      'Classify as, with Save pinned and on', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final rule = await fifteenRule(p);
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    expect(find.text('Edit rule'), findsOneWidget);
    expect(chips(), findsNWidgets(15));
    expect(find.text('If the SMS contains any of (15)'), findsOneWidget);
    // Edit opens with an empty Add box and no keyboard.
    expect(boxText(tester), isEmpty);
    expect(boxFocused(tester), isFalse);

    final viewport = inRuleDialog(find.byType(Scrollable)).first;
    final state = tester.state<ScrollableState>(viewport);
    expect(state.position.pixels, 0);
    // The chips lead, the Add box under them, Classify as after both.
    expect(
      tester.getTopLeft(chips().first).dy,
      lessThan(tester.getTopLeft(addBox).dy),
    );
    expect(
      tester.getTopLeft(addBox).dy,
      lessThan(tester.getTopLeft(find.text('Classify as')).dy),
    );
    // Save is pinned under the scroll view, in view without scrolling.
    expect(button('Save').hitTestable(), findsOneWidget);
    expect(enabled(tester, button('Save')), isTrue);

    // Compact chips share lines. The test font draws every glyph a full em
    // wide, about twice a phone font's width, so these 15 take 11 lines
    // here and about 5 on a phone; the check is that short ones pair up and
    // that each chip stays one compact line.
    final lines = {
      for (var i = 0; i < 15; i++) tester.getTopLeft(chips().at(i)).dy,
    };
    expect(lines.length, lessThan(15));
    expect(
      tester.getTopLeft(chips().at(0)).dy,
      tester.getTopLeft(chips().at(1)).dy,
    );
    for (var i = 0; i < 15; i++) {
      expect(tester.getSize(chips().at(i)).height, lessThanOrEqualTo(32));
    }

    // Saving unchanged writes the same pattern back.
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();
    expect(
      p.rules.where((r) => !r.isBuiltIn).single.pattern,
      fifteen.join(' | '),
    );
  });

  testWidgets('Add appends a chip, clears the box and keeps focus; blank, '
      'duplicate and "|" are handled', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await open(tester, p, (c) => showRuleDialog(c));

    expect(find.text('New rule'), findsOneWidget);
    expect(chips(), findsNothing);
    expect(boxFocused(tester), isTrue);
    // A new rule from Cockpit names no category until one is picked.
    expect(enabled(tester, button('Create')), isFalse);
    await classifyAs(tester, 'Food & Dining');
    // Blank: nothing to add, nothing to save.
    expect(enabled(tester, button('Add')), isFalse);
    expect(enabled(tester, button('Create')), isFalse);
    await tester.enterText(addBox, '   ');
    await tester.pump();
    expect(enabled(tester, button('Add')), isFalse);
    expect(enabled(tester, button('Create')), isFalse);

    await tester.enterText(addBox, '  amma  ');
    await tester.pump();
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    expect(chips(), findsOneWidget);
    expect(inRuleDialog(find.text('amma')), findsOneWidget);
    expect(boxText(tester), isEmpty);
    expect(boxFocused(tester), isTrue);
    expect(find.text('If the SMS contains any of (1)'), findsOneWidget);

    // The keyboard's done key adds too, and focus stays for the next word.
    await tester.enterText(addBox, 'appa');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(chips(), findsNWidgets(2));
    expect(boxText(tester), isEmpty);
    expect(boxFocused(tester), isTrue);

    // A duplicate, ignoring case and spacing, clears the box only.
    await tester.enterText(addBox, ' AMMA ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(chips(), findsNWidgets(2));
    expect(boxText(tester), isEmpty);

    // '|' is the stored separator: an error, and neither Add nor Save.
    await tester.enterText(addBox, 'akka|anna');
    await tester.pump();
    // Under the field and as the footer's reason.
    expect(
      find.text('Remove "|". Add each word on its own.'),
      findsNWidgets(2),
    );
    expect(enabled(tester, button('Add')), isFalse);
    expect(enabled(tester, button('Create')), isFalse);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(chips(), findsNWidgets(2));

    await tester.enterText(addBox, '');
    await tester.pump();
    expect(enabled(tester, button('Create')), isTrue);
    await tester.tap(button('Create'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn).single.pattern, 'amma | appa');
  });

  testWidgets('the cross removes a condition', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final rule = await fifteenRule(p);
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    final cross = inRuleDialog(find.byTooltip('Remove condition'));
    expect(cross, findsNWidgets(15));
    await tester.tap(cross.first);
    await tester.pumpAndSettle();
    expect(chips(), findsNWidgets(14));
    expect(inRuleDialog(find.text('swiggy')), findsNothing);
    expect(find.text('If the SMS contains any of (14)'), findsOneWidget);

    await tester.tap(button('Save'));
    await tester.pumpAndSettle();
    expect(
      p.rules.where((r) => !r.isBuiltIn).single.pattern,
      fifteen.skip(1).join(' | '),
    );
  });

  testWidgets('removing every chip disables Save until a word is typed', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma', 'food');
    final rule = p.rules.firstWhere((r) => !r.isBuiltIn);
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    await tester.tap(inRuleDialog(find.byTooltip('Remove condition')));
    await tester.pumpAndSettle();
    expect(chips(), findsNothing);
    expect(enabled(tester, button('Save')), isFalse);
    await tester.enterText(addBox, 'appa');
    await tester.pump();
    expect(enabled(tester, button('Save')), isTrue);
  });

  testWidgets('tapping a chip moves it into the Add box', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma | appa', 'food');
    final rule = p.rules.firstWhere((r) => !r.isBuiltIn);
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    await tester.tap(inRuleDialog(find.text('amma')));
    await tester.pumpAndSettle();
    // No dialog over the sheet: the chip's text waits in the box, focused.
    expect(find.byType(AlertDialog), findsNothing);
    expect(chips(), findsOneWidget);
    expect(boxText(tester), 'amma');
    expect(boxFocused(tester), isTrue);
    expect(find.text('If the SMS contains any of (1)'), findsOneWidget);

    await tester.enterText(addBox, 'amma ji');
    await tester.pump();
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    expect(inRuleDialog(find.text('amma ji')), findsOneWidget);
    expect(chips(), findsNWidgets(2));

    // Back at the end, in the order the list now holds.
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn).single.pattern, 'appa | amma ji');
  });

  testWidgets('tapping a chip keeps the text already in the Add box', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma | appa', 'food');
    final rule = p.rules.firstWhere((r) => !r.isBuiltIn);
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    await tester.enterText(addBox, '  akka  ');
    await tester.pump();
    await tester.tap(inRuleDialog(find.text('amma')));
    await tester.pumpAndSettle();
    // The typed word became a chip; the tapped one waits in the box.
    expect(boxText(tester), 'amma');
    expect(inRuleDialog(find.text('akka')), findsOneWidget);
    expect(chips(), findsNWidgets(2));

    // With a "|" in the box a tap changes nothing.
    await tester.enterText(addBox, 'a|b');
    await tester.pump();
    await tester.tap(inRuleDialog(find.text('appa')));
    await tester.pumpAndSettle();
    expect(boxText(tester), 'a|b');
    expect(chips(), findsNWidgets(2));
  });

  testWidgets('a Make rule suggestion lands as one chip, and Create takes '
      'it as it is', (tester) async {
    final p = FinanceProvider();
    await p.load();
    const sms =
        'Rs 320.00 debited from A/c XX1234 on 12-Oct-26\n'
        'to VPA tasty.corner@okbank TASTY CORNER\n'
        'Ref 612345678901. Not you? Call 18001234567';
    await open(
      tester,
      p,
      (c) => showRuleDialog(
        c,
        patternSuggestion: sms,
        categorySuggestion: 'transport',
      ),
    );

    expect(find.text('New rule'), findsOneWidget);
    expect(chips(), findsOneWidget);
    expect(inRuleDialog(find.text(sms.replaceAll('\n', ' '))), findsOneWidget);
    expect(boxText(tester), isEmpty);
    expect(find.text('If the SMS contains any of (1)'), findsOneWidget);
    expect(enabled(tester, button('Create')), isTrue);

    await tester.tap(button('Create'));
    await tester.pumpAndSettle();
    final mine = p.rules.where((r) => !r.isBuiltIn).single;
    expect(mine.pattern, sms.replaceAll('\n', ' '));
    expect(mine.categoryId, 'transport');
  });

  testWidgets('a trimmed suggestion added as a chip saves once', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await open(
      tester,
      p,
      (c) => showRuleDialog(c, patternSuggestion: 'TASTY CORNER ref 1234'),
    );
    // The suggestion is a chip; tapping it brings it back for trimming.
    await tester.tap(inRuleDialog(find.text('TASTY CORNER ref 1234')));
    await tester.pumpAndSettle();
    await tester.enterText(addBox, 'TASTY CORNER');
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    expect(chips(), findsOneWidget);
    // Text left over that repeats a chip is not stored twice.
    await tester.enterText(addBox, 'tasty corner');
    await tester.pump();
    await classifyAs(tester, 'Food & Dining');
    await tester.tap(button('Create'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn).single.pattern, 'TASTY CORNER');
  });

  testWidgets('editing a rule pair keeps the twin in step', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma | appa', 'food');
    await p.addRule('amma | appa', 'salary');
    final rule = p.rules.firstWhere(
      (r) => !r.isBuiltIn && r.categoryId == 'food',
    );
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    expect(find.text('Edit rule pair'), findsOneWidget);
    expect(chips(), findsNWidgets(2));
    expect(find.text('Other direction'), findsOneWidget);
    await tester.enterText(addBox, 'akka');
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();

    final mine = p.rules.where((r) => !r.isBuiltIn).toList();
    expect(mine, hasLength(2));
    expect(mine.map((r) => r.pattern).toSet(), {'amma | appa | akka'});
    expect(mine.map((r) => r.categoryId).toSet(), {'food', 'salary'});
  });

  testWidgets('at 320dp with 2x text the sheet fits, long chips included', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    const long =
        'Rs 320.00 debited from A/c XX1234 to VPA tasty.corner@okbank '
        'TASTY CORNER on 12-Oct-26';
    await p.addRule([...fifteen, long].join(' | '), 'food');
    await p.addRule([...fifteen, long].join(' | '), 'salary');
    final rule = p.rules.firstWhere(
      (r) => !r.isBuiltIn && r.categoryId == 'food',
    );
    await open(
      tester,
      p,
      (c) => showRuleDialog(c, existing: rule),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(chips(), findsNWidgets(16));
    // The long condition stays on one line inside the sheet.
    final dialogRect = tester.getRect(find.byType(EditorSheetBody));
    final longChip = find.ancestor(
      of: find.text(long),
      matching: find.byType(InputChip),
    );
    expect(tester.getRect(longChip).right, lessThanOrEqualTo(dialogRect.right));
    // Add box and Add button both reachable.
    await tester.enterText(addBox, 'akka');
    await tester.pump();
    await tester.ensureVisible(button('Add'));
    await tester.pumpAndSettle();
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    expect(chips(), findsNWidgets(17));
    await tester.enterText(addBox, 'a|b');
    await tester.pump();
    expect(tester.takeException(), isNull);
    await discard(tester);

    // A new rule with a long suggestion fits too, as one chip.
    await open(
      tester,
      p,
      (c) => showRuleDialog(c, patternSuggestion: '$long\n$long'),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(chips(), findsOneWidget);
    expect(inRuleDialog(find.text('$long $long')), findsOneWidget);
  });

  testWidgets('the rule sheet fits a small phone with the keyboard up', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final rule = await fifteenRule(p);
    await open(
      tester,
      p,
      (c) => showRuleDialog(c, existing: rule),
      size: const Size(320, 568),
      textScale: 2,
      keyboard: 280,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('editor-save')).hitTestable(), findsOne);
  });

  testWidgets('a new rule from Cockpit waits for a category, and Spam leads '
      'the list', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await open(tester, p, (c) => showRuleDialog(c));

    expect(find.text('Pick what to classify as'), findsOneWidget);
    expect(enabled(tester, button('Create')), isFalse);
    await tester.tap(find.text('Classify as'));
    await tester.pumpAndSettle();
    expect(find.text('Spam: never import'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Spam: never import')).dy,
      lessThan(tester.getTopLeft(find.text('EXPENSES')).dy),
    );
  });

  group('Make rule merge', () {
    List<ClassifierRule> mine(FinanceProvider p) =>
        p.rules.where((r) => !r.isBuiltIn).toList();

    testWidgets('a selection on a row in Food adds to the Food rule', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule('swiggy', 'food');
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'zomato',
          categorySuggestion: 'food',
        ),
      );

      expect(find.text('Add to Food & Dining rule'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'swiggy'), findsOneWidget);
      final fresh = find.widgetWithText(InputChip, 'zomato · new');
      expect(fresh, findsOneWidget);
      expect(tester.widget<InputChip>(fresh).selected, isTrue);
      expect(find.text('If the SMS contains any of (2)'), findsOneWidget);
      await tester.tap(button('Add to rule'));
      await tester.pumpAndSettle();

      expect(mine(p), hasLength(1));
      expect(mine(p).single.pattern, 'swiggy | zomato');
      expect(mine(p).single.categoryId, 'food');
      expect(
        find.text('Added "zomato" to your Food & Dining rule'),
        findsOneWidget,
      );
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(mine(p).single.pattern, 'swiggy');
    });

    Tx smsRow(String id, String body) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 250,
      note: '',
      date: DateTime(2026, 9, 12, 13),
      source: TxSource.sms,
      smsBody: body,
      sender: 'AD-DEMOBK',
    );

    testWidgets('a newer rule that claims the message makes it a new rule '
        'at the top, saying which rule comes first', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('z1', 'Rs 250 paid by UPI to SAMPLE ZOMATO'),
      ]);
      await p.addRule('swiggy', 'food');
      // Newer, so it sits above the food rule and claims the row.
      await p.addRule('upi', 'transport');
      String category() =>
          p.transactions.singleWhere((t) => t.id == 'z1').categoryId;
      expect(category(), 'transport');
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'zomato',
          categorySuggestion: 'food',
        ),
      );

      expect(find.text('New rule'), findsOneWidget);
      expect(find.text('Add to Food & Dining rule'), findsNothing);
      expect(
        find.text(
          'Your "upi" rule comes first for a message with these words, so '
          'this is saved as a new rule above it.',
        ),
        findsOneWidget,
      );
      await tester.tap(button('Create'));
      await tester.pumpAndSettle();

      expect(mine(p).map((r) => r.pattern), ['zomato', 'upi', 'swiggy']);
      expect(mine(p).first.categoryId, 'food');
      expect(category(), 'food');
      expect(find.text('1 transaction reclassified'), findsOneWidget);
    });

    testWidgets('Add to rule keeps the rule where it is, so a rule above it '
        'keeps its rows', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('i1', 'Rs 250 paid to SAMPLE SWIGGY INSTAMART'),
      ]);
      await p.addRule('swiggy', 'food');
      // Newer, so it sits above the food rule and claims the row.
      await p.addRule('instamart', 'shopping');
      String category() =>
          p.transactions.singleWhere((t) => t.id == 'i1').categoryId;
      expect(category(), 'shopping');
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'zomato',
          categorySuggestion: 'food',
        ),
      );

      // No message holds "zomato", so nothing above shadows the merge.
      expect(find.text('Add to Food & Dining rule'), findsOneWidget);
      expect(find.byKey(const ValueKey('rule-shadow-line')), findsNothing);
      await tester.tap(button('Add to rule'));
      await tester.pumpAndSettle();

      expect(mine(p).map((r) => r.pattern), ['instamart', 'swiggy | zomato']);
      expect(category(), 'shopping');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(mine(p).map((r) => r.pattern), ['instamart', 'swiggy']);
    });

    testWidgets('Undo after Add to rule puts the moved rows back in their '
        'own categories', (tester) async {
      final p = FinanceProvider();
      await p.load();
      // Older, so it sits below the food rule.
      await p.addRule('demopay', 'transport');
      await p.addRule('swiggy', 'food');
      // Loaded after the rules, so no rule has sorted them: one no rule
      // matches, one the lower rule would claim on a re-sort.
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to SAMPLE QWERTYMART'),
        smsRow(
          'q2',
          'Rs 250 paid to SAMPLE QWERTYMART via DEMOPAY',
        ).copyWith(categoryId: 'shopping'),
      ]);
      String category(String id) =>
          p.transactions.singleWhere((t) => t.id == id).categoryId;
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'qwertymart',
          categorySuggestion: 'food',
        ),
      );

      expect(find.text('Add to Food & Dining rule'), findsOneWidget);
      await tester.tap(button('Add to rule'));
      await tester.pumpAndSettle();
      expect(category('q1'), 'food');
      expect(category('q2'), 'food');
      expect(
        find.textContaining('2 transactions reclassified'),
        findsOneWidget,
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(mine(p).map((r) => r.pattern), ['swiggy', 'demopay']);
      expect(category('q1'), 'other_expense');
      expect(category('q2'), 'shopping');
    });

    test('a spam rule above the target shadows the merge; a rule for the '
        'other direction does not', () async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('z1', 'Rs 250 paid by UPI to SAMPLE ZOMATO'),
      ]);
      await p.addRule('swiggy', 'food');
      // Income only: it never claims an expense row.
      await p.addRule('upi', 'salary');
      ClassifierRule rule(String pattern) =>
          p.rules.firstWhere((r) => r.pattern == pattern);
      expect(p.ruleShadowingMerge(rule('swiggy'), null, ['zomato']), isNull);

      // A spam rule claims every direction; the row is confirmed, so the
      // rule leaves it in place.
      await p.restoreRules([
        ClassifierRule(
          id: 'spam_upi',
          pattern: 'upi',
          categoryId: kSpamCategoryId,
        ),
        ...p.rules,
      ]);
      expect(p.transactions.any((t) => t.id == 'z1'), isTrue);
      expect(
        p.ruleShadowingMerge(rule('swiggy'), null, ['zomato'])?.id,
        'spam_upi',
      );
      // Words no message holds shadow nothing.
      expect(p.ruleShadowingMerge(rule('swiggy'), null, ['dominos']), isNull);
    });

    testWidgets('changing Classify as to another category makes it a new '
        'rule', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule('swiggy', 'food');
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'zomato',
          categorySuggestion: 'food',
        ),
      );
      await classifyAs(tester, 'Transport');

      expect(find.text('New rule'), findsOneWidget);
      expect(find.text('Add to Food & Dining rule'), findsNothing);
      await tester.tap(button('Create'));
      await tester.pumpAndSettle();
      expect(mine(p), hasLength(2));
      expect(
        mine(p).firstWhere((r) => r.categoryId == 'transport').pattern,
        'zomato',
      );
    });

    testWidgets('a word the rule already has disables Add to rule', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule('swiggy', 'food');
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'SWIGGY',
          categorySuggestion: 'food',
        ),
      );

      expect(
        find.text('These words are already in your Food & Dining rule'),
        findsOneWidget,
      );
      expect(enabled(tester, button('Add to rule')), isFalse);
    });

    testWidgets('a built-in rule and a pair leg are never merge targets', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      // A built-in food rule, and no food rule of the user's.
      await p.restoreRules([
        ...p.rules,
        ClassifierRule(
          id: 'builtin_test_food',
          pattern: 'zomato',
          categoryId: 'food',
        ),
      ]);
      expect(mine(p), isEmpty);
      expect(p.rules.where((r) => r.categoryId == 'food'), isNotEmpty);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'tasty corner',
          categorySuggestion: 'food',
        ),
      );
      expect(find.text('New rule'), findsOneWidget);
      Navigator.of(tester.element(find.byType(EditorSheetBody))).pop();
      await tester.pumpAndSettle();

      // A food leg of a food and salary pair.
      await p.addRule('amma', 'food');
      await p.addRule('amma', 'salary');
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'tasty corner',
          categorySuggestion: 'food',
        ),
      );
      expect(find.text('New rule'), findsOneWidget);
    });
  });
}
