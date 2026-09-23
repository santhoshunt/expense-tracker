import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/utils/format.dart';

/// The Cockpit's info tips: each opens with its explanation, and the
/// monthly cap's tip works this month's figures into an example line.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  /// A tall surface, so every row of a tab is on screen without scrolling.
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpCockpit(
    WidgetTester tester,
    FinanceProvider p, {
    SettingsProvider? settings,
    int tab = 0,
  }) async {
    tallSurface(tester);
    final s = settings ?? (SettingsProvider()..load());
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: ClassifiersScreen(initialTab: tab)),
      ),
    );
    await pumpThrough(tester);
  }

  /// The tip titled [title], by the label a screen reader announces.
  Finder tipFinder(String title) => find.bySemanticsLabel('About $title');

  /// Opens the tip titled [title], checks its message starts with
  /// [messageStart], and closes it again.
  Future<void> expectTip(
    WidgetTester tester,
    String title,
    String messageStart,
  ) async {
    final tip = tipFinder(title);
    expect(tip, findsOneWidget, reason: 'tip "$title"');
    await tester.tap(tip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(messageStart), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(messageStart), findsNothing);
  }

  testWidgets('rules tab: ordering tip on the first header; the pair tip '
      'lives in the editor', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma', 'food');
    await p.addRule('amma', 'salary');
    await pumpCockpit(tester, p);

    expect(find.text('YOUR RULES'), findsOneWidget);
    expect(find.text('BUILT-IN'), findsOneWidget);
    await expectTip(tester, 'Your rules', 'Rules are checked top to bottom');
    expect(tipFinder('Built-in'), findsNothing);

    // The pair row shows its primary rule's category icon, not a
    // two-way arrow, and carries no tip of its own.
    expect(tipFinder('Rule pair'), findsNothing);
    expect(find.byIcon(Icons.swap_vert), findsNothing);
    final pairTile = find.ancestor(
      of: find.text('contains "amma"'),
      matching: find.byType(ListTile),
    );
    final primary = p.rules.firstWhere((r) => r.pattern == 'amma');
    expect(
      find.descendant(
        of: pairTile,
        matching: find.byIcon(categoryById(primary.categoryId).icon),
      ),
      findsOneWidget,
    );

    // The tile opens the pair editor, where the pair is explained next to
    // the Other direction field.
    await tester.tap(find.text('contains "amma"'));
    await pumpThrough(tester);
    expect(find.text('Edit rule pair'), findsOneWidget);
    await expectTip(tester, 'Rule pair', 'Picking a category here makes a');
    await expectTip(
      tester,
      'If the SMS contains…',
      'Matches whole words in the SMS text',
    );
    await expectTip(
      tester,
      'Then classify as',
      'Saving applies the rule to past SMS rows',
    );
  });

  testWidgets('with only built-in rules the tip moves to Built-in', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p);

    expect(find.text('YOUR RULES'), findsNothing);
    await expectTip(tester, 'Built-in', 'Rules are checked top to bottom');
  });

  testWidgets('import and transactions tabs explain their tools', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabImport);

    expect(find.text('FLAGGED AS SPAM WHEN CONTAINING'), findsOneWidget);
    await expectTip(
      tester,
      'Flagged as spam when containing',
      'Flagged messages are still imported',
    );
    // The tools row sits below every import rule, past the lazy list's
    // build extent.
    await tester.scrollUntilVisible(
      find.text('Test a message'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    await expectTip(tester, 'Test a message', 'Shows what the parser does');

    await tester.tap(find.text('New import rule'));
    await pumpThrough(tester);
    expect(
      find.text(
        'Case-insensitive, matches whole words, e.g. "will be debited"',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await pumpThrough(tester);

    await tester.tap(find.text('Transactions'));
    await pumpThrough(tester);
    await expectTip(
      tester,
      'Tap to recategorise',
      'Picking a category also switches the row',
    );
  });

  testWidgets('monthly cap tip shows this month against the cap', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 48677,
      note: 'Groceries',
      date: DateTime(now.year, now.month, 1, 0, 0, 1),
    );
    final s = SettingsProvider();
    await s.load();
    await s.setMonthlyBudget(60000);
    await pumpCockpit(tester, p, settings: s, tab: kCockpitTabBudgets);

    // Existing lookups by text still resolve to one widget each.
    expect(find.text('Monthly cap'), findsOneWidget);
    expect(find.text('Budget alerts'), findsOneWidget);

    final spent = p.budgetSpentInMonth(DateTime(now.year, now.month));
    expect(spent, 48677);
    final line =
        'This month: ${fmtMoneyCompact(spent)} of ${fmtMoneyCompact(60000)} '
        '(${(spent / 60000 * 100).round()}%)';
    await tester.tap(tipFinder('Monthly cap'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Counts confirmed spending only'), findsOne);
    expect(find.text(line), findsOneWidget);
    expect(line, contains('(81%)'));
    await tester.tap(find.text('Got it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectTip(tester, 'Budget alerts', 'Checks run only while');
    await expectTip(tester, 'Payment reminders', 'Card bills notify once');
    expect(
      find.text(
        'Card bills, your reminders and detected recurring payments, '
        'checked when the app opens',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Add budget'));
    await pumpThrough(tester);
    await expectTip(
      tester,
      'Only these / All except',
      'Only these: counts spending',
    );
  });

  testWidgets('without a cap the cap tip has no example line', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabBudgets);

    await tester.tap(tipFinder('Monthly cap'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Counts confirmed spending only'), findsOne);
    expect(find.textContaining('This month:'), findsNothing);
  });

  testWidgets('categories tab and editor explain groups and direction', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabCategories);

    await expectTip(tester, 'Groups', 'Groups add up their categories');
    await tester.tap(find.text('New category'));
    await pumpThrough(tester);
    await expectTip(tester, 'Direction', 'Changing direction re-types');
    await expectTip(tester, 'Transfer', 'Transfers are left out of income');
  });

  testWidgets('reminders tab and editor explain notifying and due days', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabReminders);

    await expectTip(tester, 'Reminders', 'Reminders notify only when');
    await tester.tap(find.text('New reminder'));
    await pumpThrough(tester);
    await expectTip(tester, 'Due day of month', 'Days 29 to 31 fall');
    await expectTip(tester, 'Category', 'Sets the icon and colour');
    expect(
      find.textContaining('notifies from 2 days before, when you open the app'),
      findsOneWidget,
    );
  });
}
