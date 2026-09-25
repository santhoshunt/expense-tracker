import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
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

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.textContaining('1 regular payment · '), findsOneWidget);
    expect(find.text('Up ${fmtMoney(150)}'), findsOneWidget);
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

    await tester.longPress(find.text('Netflix'));
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

    await tester.longPress(find.text('Netflix'));
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

  testWidgets('the Breakdown line opens the Subscriptions tab', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(
      app(p, await settings(), const Scaffold(body: DashboardScreen())),
    );
    await tester.pumpAndSettle();
    await openDashboardView(tester, 'Breakdown');

    final line = find.text('Subscriptions');
    await tester.scrollUntilVisible(
      line,
      300,
      scrollable: verticalScrollable(),
    );
    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
  });
}
