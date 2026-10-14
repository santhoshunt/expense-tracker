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

  /// The sort chips head the Filters sheet; a pick applies at once, and
  /// Apply closes the sheet.
  Future<void> sortBy(WidgetTester tester, String label) async {
    await tester.tap(tune);
    await tester.pumpAndSettle();
    final chip = find.widgetWithText(ChoiceChip, label);
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
  }

  final day1 = DateFormat('EEE d MMM').format(DateTime(2026, 7, 1));
  final day2 = DateFormat('EEE d MMM').format(DateTime(2026, 7, 2));

  testWidgets('the tune button opens Filters with the sort at the top and '
      'Export CSV at the bottom; the badge marks an active filter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    expect(tuneBadge(tester).isLabelVisible, isFalse);

    // One tap: straight into the Filters sheet.
    await tester.tap(tune);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);
    expect(inSheet(find.text('Filters')), findsOneWidget);
    expect(inSheet(find.text('Clear all')), findsOneWidget);
    expect(inSheet(find.text('Sort by')), findsOneWidget);
    final current = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Date · newest first'),
    );
    expect(current.selected, isTrue, reason: 'the current sort');
    // Sort heads the sheet, above Date; Export CSV ends it.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(
      top(inSheet(find.text('Sort by'))),
      lessThan(top(find.text('Date'))),
    );
    final export = inSheet(find.text('Export CSV'));
    await tester.ensureVisible(export);
    await tester.pumpAndSettle();
    expect(export, findsOneWidget);
    expect(top(export), greaterThan(top(find.text('Amount range'))));

    // A sort pick applies at once: the day headers go with a date sort.
    await tester.ensureVisible(
      find.widgetWithText(ChoiceChip, 'Amount · high to low'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Amount · high to low'));
    await tester.pumpAndSettle();
    expect(find.text(day1), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.text(day1), findsNothing);

    // A month deep-link is a filter: the button marks it.
    await tester.pumpWidget(
      screen(p, req: TxFilterRequest(month: DateTime(2026, 7)), token: 1),
    );
    await tester.pumpAndSettle();
    expect(tuneBadge(tester).isLabelVisible, isTrue);
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
