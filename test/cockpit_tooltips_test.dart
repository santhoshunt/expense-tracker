import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
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
    expect(find.textContaining('Built-in rules · '), findsOneWidget);
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
    // the Other direction field; a pair opens with that expander open.
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
      'Classify as',
      'Saving applies the rule to past SMS rows',
    );
  });

  testWidgets('with only built-in rules, Your rules keeps the tip and the '
      'built-ins wait in a fold', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p);

    expect(find.text('YOUR RULES'), findsOneWidget);
    expect(find.text('No rules of your own yet.'), findsOneWidget);
    await expectTip(tester, 'Your rules', 'Rules are checked top to bottom');
    expect(tipFinder('Built-in'), findsNothing);
    expect(find.text('Restore built-in rules'), findsOneWidget);
  });

  testWidgets('import and transactions tabs explain their tools', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabImport);

    // The tester leads the tab; the core checks wait folded under it.
    expect(find.text('Paste a bank SMS to see what import would do'), findsOne);
    await expectTip(tester, 'Test a message', 'Shows what the parser does');
    const check = 'The message must state an amount in Rs, INR or ₹.';
    expect(find.text('Core checks · 4'), findsOneWidget);
    expect(find.text(check).hitTestable(), findsNothing);
    await tester.tap(find.text('Core checks · 4'));
    await pumpThrough(tester);
    expect(find.text(check).hitTestable(), findsOneWidget);

    expect(find.text('FLAGGED AS SPAM WHEN CONTAINING'), findsOneWidget);
    await expectTip(
      tester,
      'Flagged as spam when containing',
      'Flagged messages are still imported',
    );

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

    await tester.tap(find.text('Results'));
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

    // The heading and the cap field's label; the alert switches moved to
    // Settings, Notifications.
    expect(find.text('Monthly cap'), findsNWidgets(2));
    expect(find.text('Budget alerts'), findsNothing);

    final spent = p.budgetSpentInMonth(DateTime(now.year, now.month));
    expect(spent, 48677);
    final line =
        'This month: ${fmtMoneyTidy(spent)} of ${fmtMoneyTidy(60000)} '
        '(${(spent / 60000 * 100).round()}%)';
    expect(line, startsWith('This month: ₹48,677 of ₹60,000'));
    await tester.tap(tipFinder('Monthly cap'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Counts confirmed spending only'), findsOne);
    expect(find.text(line), findsOneWidget);
    expect(line, contains('(81%)'));
    await tester.tap(find.text('Got it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('New budget'));
    await pumpThrough(tester);
    await expectTip(
      tester,
      'Only these or All except',
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
    await pumpCockpit(tester, p, tab: kCockpitTabGroups);

    await expectTip(tester, 'Groups', 'Groups add up their categories');

    // A fresh app: a new home on the same MaterialApp keeps the old route.
    await tester.pumpWidget(const SizedBox());
    await pumpCockpit(tester, p, tab: kCockpitTabCategories);
    expect(tipFinder('Groups'), findsNothing);
    await tester.tap(find.text('New category'));
    await pumpThrough(tester);
    await expectTip(tester, 'Direction', 'Changing direction re-types');
    // The switch and its tip wait behind the Transfer options expander.
    expect(tipFinder('Transfer'), findsNothing);
    await tester.tap(find.text('Transfer options'));
    await pumpThrough(tester);
    await expectTip(tester, 'Transfer', 'Transfers are left out of income');
  });

  testWidgets('reminders tab and editor explain notifying and due days', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabReminders);

    await expectTip(tester, 'Reminders', 'Reminders notify only when');
    // The Overview card goes by its title, Next 7 days.
    expect(find.textContaining('They show in Next 7 days'), findsOneWidget);
    await tester.tap(find.text('New reminder'));
    await pumpThrough(tester);
    await expectTip(tester, 'Due day', 'Days 29 to 31 fall');
    await expectTip(tester, 'Category', 'Sets the icon and colour');
    expect(
      find.textContaining(
        'notifies from 2 days before. Alerts are checked when the app opens '
        'and about every 6 hours while it is closed.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('mark it paid from the Next 7 days card.'),
      findsOneWidget,
    );
  });

  testWidgets('Notifications page: one timing sentence, in its intro and '
      'each alert tip', (tester) async {
    tallSurface(tester);
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: const MaterialApp(home: NotificationsPage()),
      ),
    );
    await pumpThrough(tester);

    const timing =
        'Alerts are checked when the app opens and about every 6 hours '
        'while it is closed.';
    expect(find.text(timing), findsOneWidget);
    expect(find.text('Budget alerts'), findsOneWidget);
    // No cap and no custom budget yet: the switch says what it needs.
    expect(
      find.text('Set a cap or a custom budget to enable alerts'),
      findsOneWidget,
    );
    expect(
      find.text('Card bills, your reminders and detected recurring payments'),
      findsOneWidget,
    );
    for (final (title, start) in const [
      ('Budget alerts', 'Each alert fires at most once'),
      ('Unusual spending alerts', 'A category alerts once a month'),
      ('Payment reminders', 'Card bills notify once'),
    ]) {
      final tip = tipFinder(title);
      await tester.tap(tip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining(start), findsOneWidget);
      expect(find.textContaining(timing), findsNWidgets(2), reason: title);
      await tester.tap(find.text('Got it'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  });
}
