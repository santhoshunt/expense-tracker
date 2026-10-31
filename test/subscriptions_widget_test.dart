import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/subscriptions.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/animated_fold.dart';

import 'dashboard_test_utils.dart';

/// The Subscriptions tab and the Breakdown line that opens it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// Netflix every 30 days, due today, with the last payment up ₹150; a gym
  /// that stopped months ago.
  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    for (final (ago, amount) in [(90, 499.0), (60, 499.0), (30, 649.0)]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: amount,
        note: 'Netflix',
        date: day.subtract(Duration(days: ago)),
      );
    }
    for (final ago in [240, 210, 180]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'health',
        amount: 1000,
        note: 'Gym',
        date: day.subtract(Duration(days: ago)),
      );
    }
    return p;
  }

  Widget app(FinanceProvider p, SettingsProvider s, Widget home) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: home),
      );

  Future<SettingsProvider> settings() async {
    final s = SettingsProvider();
    await s.load();
    return s;
  }

  testWidgets('lists active payments with totals and a price rise; '
      'stopped ones fold', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(
      app(
        p,
        await settings(),
        const ClassifiersScreen(initialTab: kCockpitTabSubscriptions),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Budgets and bills'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.textContaining('1 regular payment · '), findsOneWidget);
    // Whole rupees: paise only when there are some.
    expect(find.text('Up ${fmtMoneyTidy(150)}'), findsOneWidget);
    expect(find.text('Up ₹150'), findsOneWidget);
    expect(find.text('Stopped (1)'), findsOneWidget);
    // AnimatedFold keeps its child built at zero height; ask it directly.
    bool folded() => tester
        .widget<AnimatedFold>(
          find.ancestor(
            of: find.text('Gym'),
            matching: find.byType(AnimatedFold),
          ),
        )
        .collapsed;
    expect(folded(), isTrue);

    await tester.tap(find.text('Stopped (1)'));
    await tester.pumpAndSettle();
    expect(folded(), isFalse);
  });

  testWidgets('hiding moves a payment to Hidden, and Undo brings it back', (
    tester,
  ) async {
    final p = await seeded();
    final s = await settings();
    await tester.pumpWidget(
      app(p, s, const ClassifiersScreen(initialTab: kCockpitTabSubscriptions)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(s.hiddenUpcoming, contains('expense|netflix'));
    expect(find.text('Hidden (1)'), findsOneWidget);
    expect(find.textContaining('Regular payments show here'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(s.hiddenUpcoming, isEmpty);
    expect(find.text('Netflix'), findsOneWidget);
  });

  testWidgets('a tap opens the actions sheet, led by See transactions; rows '
      'leave the yearly cost to the header; a marked one shows a pin', (
    tester,
  ) async {
    final p = await seeded();
    await p.setSubscriptionPins({'expense|netflix': SubscriptionCycle.monthly});
    await tester.pumpWidget(
      app(
        p,
        await settings(),
        const ClassifiersScreen(initialTab: kCockpitTabSubscriptions),
      ),
    );
    await tester.pumpAndSettle();

    // The header line only; the stopped Gym row is built but folded.
    expect(find.textContaining('a year'), findsOneWidget);
    expect(find.textContaining('marked by you'), findsNothing);
    expect(find.byTooltip('Marked by you'), findsOneWidget);

    final tile = find.ancestor(
      of: find.text('Netflix'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: tile, matching: find.byTooltip('More')),
      findsNothing,
    );
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );
    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    expect(find.text('See transactions'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Make a reminder'), findsOneWidget);
    expect(find.text('Change cycle'), findsOneWidget);
    expect(find.text('Hide'), findsOneWidget);
    expect(find.text('Mark unpaid'), findsNothing, reason: 'not marked paid');
  });

  testWidgets('a payment marked paid by hand offers Mark unpaid; Undo puts '
      'the mark back', (tester) async {
    final p = await seeded();
    final s = await settings();
    final hit = cachedSubscriptions(p, s.hiddenUpcoming).active.single.hit;
    await p.markPatternPaid(hit.key, hit.nextDue);
    final marked = p.patternPaidThrough(hit.key);
    expect(marked, isNotNull);
    await tester.pumpWidget(
      app(p, s, const ClassifiersScreen(initialTab: kCockpitTabSubscriptions)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark unpaid'));
    await tester.pumpAndSettle();
    expect(p.patternPaidThrough(hit.key), isNull);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.patternPaidThrough(hit.key), marked);
  });

  testWidgets('a hidden income pattern is listed under Hidden with Unhide, '
      'and nowhere else', (tester) async {
    final p = await seeded();
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    for (final ago in [90, 60, 30]) {
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 50000,
        note: 'Salary',
        date: day.subtract(Duration(days: ago)),
      );
    }
    final s = await settings();
    await s.hideUpcoming('income|salary');
    await tester.pumpWidget(
      app(p, s, const ClassifiersScreen(initialTab: kCockpitTabSubscriptions)),
    );
    await tester.pumpAndSettle();

    // Not a payment: the count and totals stay Netflix's alone.
    expect(find.textContaining('1 regular payment · '), findsOneWidget);
    expect(find.text('Hidden (1)'), findsOneWidget);
    await tester.tap(find.text('Hidden (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Salary'), findsOneWidget);
    final unhide = find.widgetWithText(TextButton, 'Unhide');
    await tester.ensureVisible(unhide);
    await tester.pumpAndSettle();
    await tester.tap(unhide);
    await tester.pumpAndSettle();

    expect(s.hiddenUpcoming, isEmpty);
    expect(find.text('Hidden (1)'), findsNothing);
    expect(find.text('Salary'), findsNothing, reason: 'income is no payment');
  });

  testWidgets('rows with a rise or Unhide fit 320dp at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = await seeded();
    final s = await settings();
    await s.hideUpcoming('expense|gym');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const ClassifiersScreen(initialTab: kCockpitTabSubscriptions),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Up ${fmtMoneyTidy(150)}'), findsOneWidget);
    // The list builds lazily, and at 2x text the fold starts below it.
    final fold = find.text('Hidden (1)');
    await tester.scrollUntilVisible(
      fold,
      200,
      scrollable: find
          .ancestor(of: find.text('Netflix'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Unhide'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // ListTile squeezes a title rather than throwing: the names must keep
    // a readable width beside the badge and Unhide.
    expect(tester.getSize(find.text('Netflix')).width, greaterThan(60));
    expect(tester.getSize(find.text('Gym')).width, greaterThan(40));
  });

  testWidgets('"Make a reminder" opens the editor prefilled', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(
      app(
        p,
        await settings(),
        const ClassifiersScreen(initialTab: kCockpitTabSubscriptions),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a reminder'));
    await tester.pumpAndSettle();
    final name = tester.widget<TextField>(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
    );
    expect(name.controller?.text, 'Netflix');
  });

  testWidgets('See transactions opens its own tab, so uncounted wallet rows '
      'stay out', (tester) async {
    final p = await seeded();
    TxFilterRequest? opened;
    final owner = Object();
    AppNav.instance.attachHome(
      owner,
      setTab: (_) {},
      openTransactions: (r) => opened = r,
    );
    addTearDown(() => AppNav.instance.detachHome(owner));
    await tester.pumpWidget(
      app(
        p,
        await settings(),
        const ClassifiersScreen(initialTab: kCockpitTabSubscriptions),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See transactions'));
    await tester.pumpAndSettle();
    // The Expense tab, not All: All also lists wallet rows that the
    // subscription's figures leave out.
    expect(opened?.type, TxType.expense);
    expect(opened?.query, 'netflix');
  });

  testWidgets('the Ahead line opens the Subscriptions tab', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(
      app(p, await settings(), const Scaffold(body: DashboardScreen())),
    );
    await tester.pumpAndSettle();
    await openDashboardView(tester, 'Ahead');

    // Folded at first: open it, then tap its card.
    await openDashboardSection(tester, 'subscriptions');
    final line = find.textContaining('regular payment');
    await tester.ensureVisible(line);
    await tester.pumpAndSettle();
    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(find.text('Budgets and bills'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
  });
}
