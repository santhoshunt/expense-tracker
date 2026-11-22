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

  group('Also set', () {
    List<ClassifierRule> mine(FinanceProvider p) =>
        p.rules.where((r) => !r.isBuiltIn).toList();

    // A confirmed SMS row no rule has sorted yet.
    Tx smsRow(
      String id,
      String body, {
      String categoryId = 'other_expense',
      String payee = '',
    }) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: categoryId,
      amount: 250,
      note: '',
      date: DateTime(2026, 9, 12, 13),
      source: TxSource.sms,
      smsBody: body,
      sender: 'AD-DEMOBK',
      payee: payee,
    );
    Tx row(FinanceProvider p, String id) =>
        p.transactions.singleWhere((t) => t.id == id);

    const fold = ValueKey('rule-extras');
    final payeeField = find.byKey(const ValueKey('rule-payee'));
    final tagField = find.widgetWithText(TextField, 'Tags');
    Finder foldValue(String value) =>
        find.descendant(of: find.byKey(fold), matching: find.text(value));
    String preview(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('rule-extras-preview')))
        .data!;

    /// Opens, or closes, the Also set fold.
    Future<void> toggleFold(WidgetTester tester) async {
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

    testWidgets('the fold waits for a category, is not there for spam, reads '
        'Nothing when closed and opens under the other direction', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await open(
        tester,
        p,
        (c) => showRuleDialog(c, patternSuggestion: 'quillfern'),
      );

      expect(find.text('Also set'), findsNothing);
      await classifyAs(tester, 'Spam: never import');
      expect(find.text('Also set'), findsNothing);
      await classifyAs(tester, 'Food & Dining');
      expect(find.text('Also set'), findsOneWidget);
      expect(foldValue('Nothing'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Money in goes to another category')).dy,
        lessThan(tester.getTopLeft(find.text('Also set')).dy),
      );
      // A closed fold builds nothing.
      expect(payeeField, findsNothing);
      expect(tagField, findsNothing);

      await toggleFold(tester);
      expect(payeeField, findsOneWidget);
      expect(tagField, findsOneWidget);
      expect(preview(tester), 'No past payments change.');
      expect(
        tester.getTopLeft(payeeField).dy,
        lessThan(tester.getTopLeft(tagField).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the closed line and the preview follow what is typed', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to SAMPLE QUILLFERN'),
        smsRow('q2', 'Rs 250 paid to SAMPLE QUILLFERN TEAS', payee: 'Meera'),
        smsRow('m1', 'Rs 250 paid to SAMPLE MAPLEWORTH'),
      ]);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'quillfern',
          categorySuggestion: 'food',
        ),
      );
      await toggleFold(tester);

      // Only the row with no Paid to of its own changes.
      await type(tester, payeeField, 'Quillfern Teas');
      expect(
        preview(tester),
        'Fills Paid to where you typed none. 1 past payment changes.',
      );
      // A tag reaches both matching rows. The comma adds it as a chip.
      await type(tester, tagField, 'Office,');
      expect(find.text('# Office'), findsOneWidget);
      expect(
        preview(tester),
        'Fills Paid to where you typed none. 2 past payments change.',
      );
      expect(foldValue('Paid to, 1 tag'), findsOneWidget);
      // Text still in the tag field counts as a tag.
      await type(tester, tagField, 'Tea');
      expect(foldValue('Paid to, 2 tags'), findsOneWidget);

      await type(tester, payeeField, '');
      expect(preview(tester), '2 past payments change.');
      expect(foldValue('2 tags'), findsOneWidget);
      await type(tester, tagField, '');
      expect(foldValue('1 tag'), findsOneWidget);

      // Closed, the line still says what is set.
      await toggleFold(tester);
      expect(payeeField, findsNothing);
      expect(foldValue('1 tag'), findsOneWidget);
      // Nothing was saved or touched by the preview.
      expect(mine(p), isEmpty);
      expect(row(p, 'q1').tags, isEmpty);
    });

    testWidgets('a new rule saves its Paid to and tags, fills past rows, and '
        'Undo takes the rule and the rows back', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to SAMPLE QUILLFERN'),
      ]);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'quillfern',
          categorySuggestion: 'food',
        ),
      );
      await toggleFold(tester);
      await type(tester, payeeField, '  Quillfern   Teas ');
      await type(tester, tagField, 'Office,');
      // Typed but not added: saved all the same.
      await type(tester, tagField, 'Tea');
      await tester.tap(button('Create'));
      await tester.pumpAndSettle();

      final saved = mine(p).single;
      expect(saved.pattern, 'quillfern');
      expect(saved.categoryId, 'food');
      expect(saved.payee, 'Quillfern Teas');
      expect(saved.tags, ['Office', 'Tea']);
      expect(row(p, 'q1').categoryId, 'food');
      expect(row(p, 'q1').payee, 'Quillfern Teas');
      expect(row(p, 'q1').tags, ['Office', 'Tea']);
      expect(find.text('1 transaction reclassified'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(mine(p), isEmpty);
      expect(row(p, 'q1').categoryId, 'other_expense');
      expect(row(p, 'q1').payee, isEmpty);
      expect(row(p, 'q1').tags, isEmpty);
    });

    testWidgets('an edit that only adds a Paid to updates past rows, says '
        'so, and Undo puts the rule and the rows back', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to SAMPLE QUILLFERN', categoryId: 'food'),
      ]);
      await p.addRule('quillfern', 'food');
      await open(tester, p, (c) => showRuleDialog(c, existing: mine(p).single));

      // A rule that sets nothing more opens with the fold closed.
      expect(foldValue('Nothing'), findsOneWidget);
      expect(payeeField, findsNothing);
      await toggleFold(tester);
      await type(tester, payeeField, 'Quillfern Teas');
      await tester.tap(button('Save'));
      await tester.pumpAndSettle();

      expect(mine(p).single.payee, 'Quillfern Teas');
      expect(row(p, 'q1').payee, 'Quillfern Teas');
      expect(find.text('1 transaction updated'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(mine(p).single.setsMore, isFalse);
      expect(row(p, 'q1').payee, isEmpty);
    });

    testWidgets('editing a rule that sets more opens the fold on its values, '
        'and clearing them saves a rule that sets nothing', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      await open(tester, p, (c) => showRuleDialog(c, existing: mine(p).single));

      expect(foldValue('Paid to, 1 tag'), findsOneWidget);
      expect(
        tester.widget<TextField>(payeeField).controller!.text,
        'Quillfern Teas',
      );
      expect(find.text('# Office'), findsOneWidget);

      await type(tester, payeeField, 'Maple Teas');
      await tester.tap(button('Save'));
      await tester.pumpAndSettle();
      expect(mine(p).single.payee, 'Maple Teas');
      expect(mine(p).single.tags, ['Office']);

      await open(tester, p, (c) => showRuleDialog(c, existing: mine(p).single));
      await type(tester, payeeField, '');
      await tester.ensureVisible(find.byTooltip('Remove tag Office'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove tag Office'));
      await tester.pumpAndSettle();
      expect(foldValue('Nothing'), findsOneWidget);
      await tester.tap(button('Save'));
      await tester.pumpAndSettle();
      expect(mine(p).single.setsMore, isFalse);
      expect(mine(p).single.toJson().keys, ['id', 'pattern', 'categoryId']);
    });

    testWidgets('a typed Paid to or tag makes the sheet ask before it '
        'closes; an untouched rule closes at once', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      Future<void> dragDown() async {
        await tester.drag(
          find.byKey(const ValueKey('editor-sheet-handle')),
          const Offset(0, 300),
        );
        await tester.pumpAndSettle();
      }

      await open(tester, p, (c) => showRuleDialog(c, existing: mine(p).single));
      await dragDown();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(EditorSheetBody), findsNothing);

      await open(tester, p, (c) => showRuleDialog(c, existing: mine(p).single));
      await type(tester, payeeField, 'Maple Teas');
      await dragDown();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      // Back as it opened: no question.
      await type(tester, payeeField, 'Quillfern Teas');
      // Text in the tag field alone counts.
      await type(tester, tagField, 'Tea');
      await dragDown();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(mine(p).single.payee, 'Quillfern Teas');
      expect(mine(p).single.tags, ['Office']);
    });

    testWidgets('a Paid to makes Add to rule a new rule; without one the '
        'rule it joins keeps its own Paid to and tags', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule('swiggy', 'food', payee: 'Swiggy', tags: ['Delivery']);
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
      // The closed line says what the rule it joins sets.
      expect(foldValue('Paid to, 1 tag'), findsOneWidget);

      await toggleFold(tester);
      await type(tester, payeeField, 'Zomato');
      expect(find.text('New rule'), findsOneWidget);
      expect(find.text('Add to Food & Dining rule'), findsNothing);
      expect(button('Create'), findsOneWidget);
      // A new rule again: the line is its own.
      expect(foldValue('Paid to, 1 tag'), findsNothing);

      await type(tester, payeeField, '');
      expect(find.text('Add to Food & Dining rule'), findsOneWidget);
      expect(foldValue('Paid to, 1 tag'), findsOneWidget);
      await tester.tap(button('Add to rule'));
      await tester.pumpAndSettle();
      final merged = mine(p).single;
      expect(merged.pattern, 'swiggy | zomato');
      expect(merged.payee, 'Swiggy');
      expect(merged.tags, ['Delivery']);
    });

    testWidgets('words added to a rule that sets more: the fold and the '
        'preview say what the rows they reach take', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      await p.restoreTransactions([
        smsRow('m1', 'Rs 250 paid to SAMPLE MAPLEWORTH'),
        smsRow('m2', 'Rs 250 paid to SAMPLE MAPLEWORTH DEPOT', payee: 'Meera'),
        smsRow('z1', 'Rs 250 paid to SAMPLE ZEPHYRINE'),
      ]);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'mapleworth',
          categorySuggestion: 'food',
        ),
      );
      expect(find.text('Add to Food & Dining rule'), findsOneWidget);
      expect(foldValue('Paid to, 1 tag'), findsOneWidget);
      await toggleFold(tester);
      // Both rows take the tag, and the one with no Paid to that too.
      expect(
        preview(tester),
        'Fills Paid to where you typed none. 2 past payments change.',
      );

      await tester.tap(button('Add to rule'));
      await tester.pumpAndSettle();
      expect(mine(p).single.pattern, 'quillfern | mapleworth');
      expect(row(p, 'm1').payee, 'Quillfern Teas');
      expect(row(p, 'm1').tags, ['Office']);
      expect(row(p, 'm2').payee, 'Meera');
      expect(row(p, 'm2').tags, ['Office']);
      expect(row(p, 'z1').tags, isEmpty);
      expect(
        find.textContaining('2 transactions reclassified'),
        findsOneWidget,
      );
    });

    testWidgets('a rule that sets nothing still offers Undo when its save '
        'gives a row another rule\'s tags', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule('quillfern', 'food', tags: ['Office']);
      // Loaded after the rule, so no rule has sorted it yet.
      await p.restoreTransactions([
        smsRow('late', 'Rs 250 paid to SAMPLE QUILLFERN'),
      ]);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'mapleworth',
          categorySuggestion: 'shopping',
        ),
      );
      expect(find.text('New rule'), findsOneWidget);
      await toggleFold(tester);
      expect(preview(tester), '1 past payment changes.');
      await tester.tap(button('Create'));
      await tester.pumpAndSettle();

      expect(mine(p), hasLength(2));
      expect(row(p, 'late').categoryId, 'food');
      expect(row(p, 'late').tags, ['Office']);
      expect(find.text('1 transaction reclassified'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(mine(p).single.pattern, 'quillfern');
      expect(row(p, 'late').categoryId, 'other_expense');
      expect(row(p, 'late').tags, isEmpty);
    });

    testWidgets('the preview follows a payment that arrives while the sheet '
        'is open', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow('q1', 'Rs 250 paid to SAMPLE QUILLFERN'),
      ]);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'quillfern',
          categorySuggestion: 'food',
        ),
      );
      await toggleFold(tester);
      await type(tester, tagField, 'Office,');
      expect(preview(tester), '1 past payment changes.');

      await p.restoreTransactions([
        smsRow('q2', 'Rs 250 paid to SAMPLE QUILLFERN TEAS'),
      ]);
      // The next rebuild, here the fold closing and opening, counts again.
      await toggleFold(tester);
      await toggleFold(tester);
      expect(preview(tester), '2 past payments change.');
    });

    /// Picks [label] in Classify as, scrolling the list to it: the
    /// transfers are its last section.
    Future<void> classifyAsTransfer(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.text('Classify as'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Classify as'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(label),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('a transfer carries no Paid to: the field goes when a '
        'transfer category is picked, and the rule saves none', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas',
        tags: ['Office'],
      );
      await open(tester, p, (c) => showRuleDialog(c, existing: mine(p).single));
      expect(payeeField, findsOneWidget);

      await classifyAsTransfer(tester, 'To savings');
      expect(payeeField, findsNothing);
      expect(tagField, findsOneWidget);
      expect(foldValue('1 tag'), findsOneWidget);
      expect(preview(tester), 'No past payments change.');

      // Back on a spending category, what was typed is still there.
      await classifyAs(tester, 'Food & Dining');
      expect(
        tester.widget<TextField>(payeeField).controller!.text,
        'Quillfern Teas',
      );
      expect(foldValue('Paid to, 1 tag'), findsOneWidget);

      await classifyAsTransfer(tester, 'To savings');
      await tester.tap(button('Save'));
      await tester.pumpAndSettle();
      final saved = mine(p).single;
      expect(saved.categoryId, kSavingsTransferCategoryId);
      expect(saved.payee, isEmpty);
      expect(saved.tags, ['Office']);
    });

    testWidgets('on a pair with a transfer side only the other rule takes '
        'the Paid to, and the pair still opens on it', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule('amma', 'food');
      await p.addRule('amma', kTransferInCategoryId);
      ClassifierRule ruleIn(String categoryId) =>
          mine(p).singleWhere((r) => r.categoryId == categoryId);

      await open(tester, p, (c) => showRuleDialog(c, existing: ruleIn('food')));
      expect(find.text('Edit rule pair'), findsOneWidget);
      await toggleFold(tester);
      await type(tester, payeeField, 'Amma');
      await type(tester, tagField, 'Family,');
      await tester.tap(button('Save'));
      await tester.pumpAndSettle();
      expect(ruleIn('food').payee, 'Amma');
      expect(ruleIn('food').tags, ['Family']);
      expect(ruleIn(kTransferInCategoryId).payee, isEmpty);
      expect(ruleIn(kTransferInCategoryId).tags, ['Family']);

      // Opened from the transfer rule, the sheet shows the other rule's
      // Paid to, and an untouched save keeps it.
      await open(
        tester,
        p,
        (c) => showRuleDialog(c, existing: ruleIn(kTransferInCategoryId)),
      );
      expect(foldValue('Paid to, 1 tag'), findsOneWidget);
      expect(tester.widget<TextField>(payeeField).controller!.text, 'Amma');
      await tester.tap(button('Save'));
      await tester.pumpAndSettle();
      expect(ruleIn('food').payee, 'Amma');
      expect(ruleIn(kTransferInCategoryId).payee, isEmpty);
      expect(ruleIn(kTransferInCategoryId).tags, ['Family']);
    });

    testWidgets('one income rule words the field and the preview Received '
        'from; a pair keeps Paid to', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        smsRow(
          'in1',
          'Rs 250 received from SAMPLE QUILLFERN',
        ).copyWith(type: TxType.income, categoryId: 'other_income'),
      ]);
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'quillfern',
          categorySuggestion: 'salary',
        ),
      );
      await toggleFold(tester);
      expect(find.widgetWithText(TextField, 'Received from'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Paid to'), findsNothing);
      await type(tester, payeeField, 'Quillfern Works');
      expect(
        preview(tester),
        'Fills Received from where you typed none. 1 past payment changes.',
      );
      // The closed line names it as the field does.
      await toggleFold(tester);
      expect(foldValue('Received from'), findsOneWidget);
      expect(foldValue('Paid to'), findsNothing);
      await toggleFold(tester);

      // With the other direction set, the rule fills both ways.
      await tester.ensureVisible(
        find.text('Money out goes to another category'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Money out goes to another category'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Other direction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other direction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Food & Dining').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Paid to'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Received from'), findsNothing);
      expect(
        preview(tester),
        'Fills Paid to where you typed none. 1 past payment changes.',
      );
      await toggleFold(tester);
      expect(foldValue('Paid to'), findsOneWidget);
    });

    // v2.3.0 review: a rule whose category became a transfer after it was
    // saved keeps its stored Paid to, and fills none.
    testWidgets('words added to a rule in a transfer category: the closed '
        'line leaves out the Paid to that rule stores', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule(
        'quillfern',
        kSavingsTransferCategoryId,
        payee: 'Quillfern Fund',
        tags: ['Office'],
      );
      await open(
        tester,
        p,
        (c) => showRuleDialog(
          c,
          patternSuggestion: 'mapleworth',
          categorySuggestion: kSavingsTransferCategoryId,
        ),
      );
      expect(find.text('Add to To savings rule'), findsOneWidget);
      expect(foldValue('1 tag'), findsOneWidget);
      expect(foldValue('Paid to, 1 tag'), findsNothing);
    });

    testWidgets('at 320dp with 2x text the open fold fits', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addRule(
        'quillfern',
        'food',
        payee: 'Quillfern Teas and Savouries of the Old Town',
        tags: ['Office', 'Reimbursable', 'Tea'],
      );
      await open(
        tester,
        p,
        (c) => showRuleDialog(c, existing: mine(p).single),
        size: const Size(320, 568),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(foldValue('Paid to, 3 tags'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('rule-extras-preview')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
