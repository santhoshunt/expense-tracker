import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/weekly_digest.dart';
import 'package:expense_tracker/utils/format.dart';

import 'dashboard_test_utils.dart';

/// v1.39.0: the Overview's This week row and the weekly digest sheet it
/// opens, also from the ⋮ menu. Names and amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });
  tearDown(() => weekClock = DateTime.now);

  /// The Dashboard on the real month (its selector starts there), with the
  /// week pinned to the 1st's week through weekClock. The rows sit on the
  /// 1st at midnight: never in the future, whatever day the test runs.
  Future<List<TxFilterRequest>> pumpDashboard(WidgetTester tester) async {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, 1);
    weekClock = () => DateTime(now.year, now.month, 1, 10);
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 2400,
      note: 'test groceries',
      date: first,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 600,
      note: 'test fares',
      date: first,
    );
    final s = SettingsProvider();
    await s.load();
    final opened = <TxFilterRequest>[];
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          home: dashboardShell(DashboardScreen(onOpenTransactions: opened.add)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  // The row under the This week label: its tap target.
  Finder weekRow() => find
      .descendant(
        of: find.byKey(const ValueKey('presence-week')),
        matching: find.byType(InkWell),
      )
      .first;

  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(BottomSheet), matching: f);

  testWidgets('the row shows this week on the current month', (tester) async {
    await pumpDashboard(tester);
    expect(find.text('This week'), findsOneWidget);
    expect(
      find.descendant(of: weekRow(), matching: find.text(fmtMoneyWhole(3000))),
      findsOneWidget,
    );
    // Its tap target is at least 48dp tall.
    expect(tester.getSize(weekRow()).height, greaterThanOrEqualTo(48));
  });

  testWidgets('Year view hides the row; Month view brings it back', (
    tester,
  ) async {
    await pumpDashboard(tester);
    await tapMenuItem(tester, 'Year view');
    expect(find.text('This week'), findsNothing);
    await tapMenuItem(tester, 'Month view');
    expect(find.text('This week'), findsOneWidget);
  });

  testWidgets('another month hides the row', (tester) async {
    await pumpDashboard(tester);
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text('This week'), findsNothing);
  });

  testWidgets('the row opens the digest; a category opens its rows', (
    tester,
  ) async {
    final opened = await pumpDashboard(tester);
    await tester.tap(weekRow());
    await tester.pumpAndSettle();
    final week = weekStartOf(weekClock());
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('Spent so far')), findsOneWidget);
    expect(inSheet(find.text(fmtMoneyWhole(3000))), findsOneWidget);
    expect(inSheet(find.text('Top categories')), findsOneWidget);
    expect(inSheet(find.text('Biggest payments')), findsOneWidget);
    // This week has no later week to step to.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Next week'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(inSheet(find.text(categoryById('food').label)).first);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing, reason: 'closed first');
    final r = opened.single;
    expect(r.categoryId, 'food');
    expect(r.type, TxType.expense);
    expect(r.rangeCounted, isTrue);
    expect(r.range?.start, week);
    expect(r.range?.end, DateTime(week.year, week.month, week.day + 6));
  });

  testWidgets('Weekly digest in the menu opens the sheet', (tester) async {
    await pumpDashboard(tester);
    await tapMenuItem(tester, 'Weekly digest');
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.textContaining('Week of ')), findsOneWidget);
  });
}
