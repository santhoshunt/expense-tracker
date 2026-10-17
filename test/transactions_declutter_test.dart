import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/grouped_surface.dart';

/// The decluttered Transactions screen: the sort and Filters chips under
/// the search (v1.43.0), a day header over each day's rows under a date
/// sort, its total on the rows' amount edge, the rows of a day drawn as one
/// card, and no review card on the tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget screen(FinanceProvider p, {TxFilterRequest? req, int token = 0}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TransactionsScreen(request: req, filterToken: token),
          ),
        ),
      );

  final sortChip = find.byIcon(Icons.swap_vert);
  final filtersChip = find.byIcon(Icons.tune);

  /// Two rows on 1 July (lunch after coffee) and one on 2 July.
  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: 'lunch',
      date: DateTime(2026, 7, 1, 13),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 50,
      note: 'coffee',
      date: DateTime(2026, 7, 1, 9),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 30,
      note: 'snack',
      date: DateTime(2026, 7, 2, 16),
    );
    return p;
  }

  /// The sort chip opens Sort by; a pick applies and closes it.
  Future<void> sortBy(WidgetTester tester, String label) async {
    await tester.tap(sortChip);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  final day1 = DateFormat('EEE d MMM').format(DateTime(2026, 7, 1));
  final day2 = DateFormat('EEE d MMM').format(DateTime(2026, 7, 2));

  testWidgets('the sort chip names the sort and opens Sort by; Filters '
      'counts what is on; the sheet holds filters only', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    expect(find.text('Newest first'), findsOneWidget);
    expect(find.text('Filters'), findsOneWidget);
    // No button in the search field any more.
    expect(find.byTooltip('Sort, filter and export'), findsNothing);

    // Filters opens the sheet: no sort, no export.
    await tester.tap(filtersChip);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);
    expect(inSheet(find.text('Filters')), findsOneWidget);
    expect(inSheet(find.text('Clear all')), findsOneWidget);
    expect(inSheet(find.text('Sort by')), findsNothing);
    expect(inSheet(find.text('Export CSV')), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);

    // The sort chip: Sort by over the four sorts; a pick applies.
    await tester.tap(sortChip);
    await tester.pumpAndSettle();
    expect(find.text('Sort by'), findsOneWidget);
    for (final label in [
      'Date · newest first',
      'Date · oldest first',
      'Amount · high to low',
      'Amount · low to high',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Amount · high to low'));
    await tester.pumpAndSettle();
    expect(find.text('Sort by'), findsNothing);
    expect(find.text(day1), findsNothing);
    expect(find.text('Largest first'), findsOneWidget);

    // A month deep-link is a filter: the chip counts it.
    await tester.pumpWidget(
      screen(p, req: TxFilterRequest(month: DateTime(2026, 7)), token: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('Filters · 1'), findsOneWidget);
    expect(find.bySemanticsLabel('1 filter on'), findsOneWidget);
    expect(find.bySemanticsLabel('1 filters on'), findsNothing);
  });

  testWidgets('day headers with the day total show under a date sort only', (
    tester,
  ) async {
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    expect(find.text(day1), findsOneWidget);
    expect(find.text(day2), findsOneWidget);
    expect(find.text(fmtMoneyTidy(-150)), findsOneWidget);
    expect(find.text(fmtMoneyTidy(-30)), findsOneWidget);
    // Newest first: 2 July's header, then 1 July's over its rows.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(top(find.text(day2)), lessThan(top(find.text('snack'))));
    expect(top(find.text('snack')), lessThan(top(find.text(day1))));
    expect(top(find.text(day1)), lessThan(top(find.text('lunch'))));
    // The day's total ends where the row amounts end.
    expect(
      tester.getTopRight(find.text(fmtMoneyTidy(-30))).dx,
      moreOrLessEquals(
        tester.getTopRight(find.text('−${fmtMoney(30)}')).dx,
        epsilon: 0.5,
      ),
    );

    await sortBy(tester, 'Amount · high to low');
    expect(find.text(day1), findsNothing);
    expect(find.text(day2), findsNothing);
    expect(find.text(fmtMoneyTidy(-150)), findsNothing);
    expect(find.text('lunch'), findsOneWidget, reason: 'the rows stay');
  });

  testWidgets('the rows of a day render inside one grouped surface', (
    tester,
  ) async {
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    GroupedSurface surface(String note) => tester.widget<GroupedSurface>(
      find.ancestor(of: find.text(note), matching: find.byType(GroupedSurface)),
    );
    (bool, bool) edges(String note) =>
        (surface(note).first, surface(note).last);

    // 1 July: lunch (13:00) opens the card, coffee (09:00) closes it.
    expect(edges('lunch'), (true, false));
    expect(edges('coffee'), (false, true));
    // 2 July holds one row: a card of its own.
    expect(edges('snack'), (true, true));

    // Any other sort draws the month as one card.
    await sortBy(tester, 'Amount · high to low');
    expect(edges('lunch'), (true, false));
    expect(edges('coffee'), (false, false));
    expect(edges('snack'), (false, true));
  });

  testWidgets('a row dated today sits under "Today"', (tester) async {
    final now = DateTime.now();
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 40,
      note: 'tea',
      // Midnight: never later than now, whatever the hour.
      date: DateTime(now.year, now.month, now.day),
    );
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('imports to review wait in the review sheet, not on the tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        Tx(
          id: 'p1',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 100,
          note: 'row p1',
          date: DateTime(2026, 7, 1),
          pending: true,
        ).toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    expect(find.textContaining('Imported from SMS'), findsNothing);
    expect(find.text('row p1'), findsNothing);
  });
}
