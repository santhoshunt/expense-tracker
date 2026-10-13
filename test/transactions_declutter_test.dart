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

/// The decluttered Transactions screen: sort, filters and export behind one
/// tune button in the search field, a day header over each day's rows under
/// a date sort, the rows of a day drawn as one card, and the review card's
/// tip shown only while the card is open.
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

  final tune = find.byTooltip('Sort, filter and export');

  Badge tuneBadge(WidgetTester tester) => tester.widget<Badge>(
    find.ancestor(of: find.byIcon(Icons.tune), matching: find.byType(Badge)),
  );

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

  Future<void> sortBy(WidgetTester tester, String label) async {
    await tester.tap(tune);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort by'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  final day1 = DateFormat('EEE d MMM').format(DateTime(2026, 7, 1));
  final day2 = DateFormat('EEE d MMM').format(DateTime(2026, 7, 2));

  testWidgets('the tune sheet holds sort, filters and export, and the badge '
      'marks an active filter', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    expect(tuneBadge(tester).isLabelVisible, isFalse);

    await tester.tap(tune);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('Sort by')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Date · newest first')),
      findsOneWidget,
      reason: 'the current sort',
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Filters')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Export CSV')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.byType(Badge)),
      findsNothing,
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);

    // A month deep-link is a filter: the button and the sheet both mark it.
    await tester.pumpWidget(
      screen(p, req: TxFilterRequest(month: DateTime(2026, 7)), token: 1),
    );
    await tester.pumpAndSettle();
    expect(tuneBadge(tester).isLabelVisible, isTrue);

    await tester.tap(tune);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: sheet, matching: find.byType(Badge)),
      findsOneWidget,
    );

    // Filters closes the tune sheet and opens the filter sheet.
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(find.text('Export CSV'), findsNothing);
    expect(find.text('Clear all'), findsOneWidget);
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

  testWidgets('the review card shows its tip only while open', (tester) async {
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

    final card = find.byKey(const ValueKey('pending-card'));
    final tip = find.descendant(
      of: card,
      matching: find.byIcon(Icons.info_outline),
    );
    final title = find.textContaining('Imported from SMS · 1');
    final header = find.ancestor(of: title, matching: find.byType(InkWell));
    expect(tip, findsOneWidget);
    final openHeight = tester.getSize(header.first).height;

    // The title folds the card, and the tip goes with the fold.
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(tip, findsNothing);
    expect(title, findsOneWidget);
    expect(tester.getSize(header.first).height, openHeight);
  });
}
