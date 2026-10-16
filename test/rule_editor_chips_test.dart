import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';

/// The rule dialog with its category and Add box on top and the conditions
/// as chips below, so a rule with many conditions needs no scrolling to add
/// one, check the category or save.
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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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
      find.descendant(of: find.byType(AlertDialog).first, matching: f);
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

  testWidgets('a rule of 15 conditions shows the category and the Add box '
      'in the first view, with Save on', (tester) async {
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
    final bottom = tester.getRect(viewport).bottom;
    final top = tester.getRect(viewport).top;
    for (final f in [find.text('Classify as'), addBox]) {
      final r = tester.getRect(f);
      expect(r.top, greaterThanOrEqualTo(top));
      expect(r.bottom, lessThanOrEqualTo(bottom));
    }
    // The category reads before the Add box, and the chips after both.
    expect(
      tester.getTopLeft(find.text('Classify as')).dy,
      lessThan(tester.getTopLeft(addBox).dy),
    );
    expect(
      tester.getTopLeft(chips().first).dy,
      greaterThan(tester.getTopLeft(addBox).dy),
    );
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
    expect(find.text('Remove "|". Add each word on its own.'), findsOneWidget);
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

  testWidgets('tapping a chip edits it in place', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma | appa', 'food');
    final rule = p.rules.firstWhere((r) => !r.isBuiltIn);
    await open(tester, p, (c) => showRuleDialog(c, existing: rule));

    await tester.tap(inRuleDialog(find.text('amma')));
    await tester.pumpAndSettle();
    expect(find.text('Edit condition'), findsOneWidget);
    final editDialog = find.byType(AlertDialog).last;
    final field = find.descendant(
      of: editDialog,
      matching: find.byType(TextField),
    );
    final save = find.descendant(
      of: editDialog,
      matching: find.widgetWithText(FilledButton, 'Save'),
    );
    expect(tester.widget<TextField>(field).controller!.text, 'amma');

    // Same checks as the Add box.
    await tester.enterText(field, 'am|ma');
    await tester.pump();
    expect(
      find.descendant(
        of: editDialog,
        matching: find.text('Remove "|". Add each word on its own.'),
      ),
      findsOneWidget,
    );
    expect(enabled(tester, save), isFalse);
    await tester.enterText(field, 'APPA');
    await tester.pump();
    expect(find.text('Already a condition.'), findsOneWidget);
    expect(enabled(tester, save), isFalse);
    await tester.enterText(field, '');
    await tester.pump();
    expect(enabled(tester, save), isFalse);

    await tester.enterText(field, '  amma\nji ');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Edit condition'), findsNothing);
    expect(inRuleDialog(find.text('amma ji')), findsOneWidget);
    expect(chips(), findsNWidgets(2));

    // Cancel leaves the chip alone.
    await tester.tap(inRuleDialog(find.text('appa')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextField),
      ),
      'other',
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(inRuleDialog(find.text('appa')), findsOneWidget);

    await tester.tap(button('Save'));
    await tester.pumpAndSettle();
    expect(p.rules.where((r) => !r.isBuiltIn).single.pattern, 'amma ji | appa');
  });

  testWidgets('a Make rule suggestion waits in the Add box, and Save takes '
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
    expect(boxText(tester), sms);
    expect(chips(), findsNothing);
    expect(find.text('If the SMS contains any of (0)'), findsOneWidget);
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
    await tester.enterText(addBox, 'TASTY CORNER');
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    expect(chips(), findsOneWidget);
    // Text left over that repeats a chip is not stored twice.
    await tester.enterText(addBox, 'tasty corner');
    await tester.pump();
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

  testWidgets('at 320dp with 2x text the dialog fits, long chips included', (
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
    // The long condition stays on one line inside the dialog.
    final dialogRect = tester.getRect(find.byType(AlertDialog));
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
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // A new rule with a long suggestion in the box fits too.
    await open(
      tester,
      p,
      (c) => showRuleDialog(c, patternSuggestion: '$long\n$long'),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(boxText(tester), '$long\n$long');
  });
}
