import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';

/// Transactions screen motion: the sticky month header, the review cards
/// folding away, and the selection bar folding in on a long-press.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget screen(FinanceProvider p, {double textScale = 1}) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const Scaffold(body: TransactionsScreen()),
    ),
  );

  /// The header's label: the bare month name inside the current year, with
  /// the year appended outside it, so the tests outlive 2026.
  Finder monthLabel(DateTime month) => find.text(
    (month.year == DateTime.now().year
            ? DateFormat('MMMM').format(month)
            : DateFormat('MMMM yyyy').format(month))
        .toUpperCase(),
  );

  final sticky = find.byKey(const ValueKey('sticky-month-header'));

  testWidgets('the sticky header names the month of the top row', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    for (var d = 1; d <= 20; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 10.0 + d,
        note: 'jul $d',
        date: DateTime(2026, 7, d),
      );
    }
    // Enough June rows that the list can scroll June's own header away.
    for (var d = 1; d <= 10; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 50.0 + d,
        note: 'jun $d',
        date: DateTime(2026, 6, d),
      );
    }
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    final july = monthLabel(DateTime(2026, 7));
    final june = monthLabel(DateTime(2026, 6));
    expect(sticky, findsNothing, reason: 'at the top the real header shows');
    expect(july, findsOneWidget);

    // Well past July's header (a short drag leaves it partly on screen).
    await tester.dragFrom(const Offset(300, 450), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(sticky, findsOneWidget);
    expect(find.descendant(of: sticky, matching: july), findsOneWidget);
    expect(july, findsOneWidget, reason: "July's own header scrolled away");

    // On into June, until June's own header has scrolled away too.
    for (var i = 0; i < 10; i++) {
      if (find.descendant(of: sticky, matching: june).evaluate().isNotEmpty) {
        break;
      }
      await tester.dragFrom(const Offset(300, 450), const Offset(0, -200));
      await tester.pumpAndSettle();
    }
    expect(find.descendant(of: sticky, matching: june), findsOneWidget);
    expect(find.descendant(of: sticky, matching: july), findsNothing);

    // Back to the top: the overlay goes again.
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(300, 250), const Offset(0, 400));
      await tester.pumpAndSettle();
    }
    expect(sticky, findsNothing);
  });

  // 3x: past the scale where the band outgrows the button's 40dp.
  for (final scale in [1.0, 3.0]) {
    testWidgets('the band takes over where the header label is, totals level, '
        'text x$scale', (tester) async {
      final p = FinanceProvider();
      await p.load();
      for (var d = 1; d <= 20; d++) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 10.0 + d,
          note: 'jul $d',
          date: DateTime(2026, 7, d),
        );
      }
      await tester.pumpWidget(screen(p, textScale: scale));
      await tester.pumpAndSettle();

      final july = monthLabel(DateTime(2026, 7));
      final total = find.text('−${fmtMoneyCompact(410)}');
      final labelTop = tester.getTopLeft(july).dy;
      final totalRight = tester.getTopRight(total).dx;
      final list = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ScrollablePositionedList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      Future<void> scrollTo(double px) async {
        list.position.jumpTo(px);
        // Positions publish after layout; the band rebuilds a frame later.
        await tester.pump();
        await tester.pump();
        expect(list.position.pixels, px);
      }

      // The label is still below the band's spot: one name, no band.
      await scrollTo(10);
      expect(sticky, findsNothing);
      expect(july, findsOneWidget);

      // Just past the hand-off the band's label sits where the list
      // header's label was, and its total ends where the header's did.
      await scrollTo(25);
      expect(sticky, findsOneWidget);
      final pinned = find.descendant(of: sticky, matching: july);
      expect(
        tester.getTopLeft(pinned).dy,
        moreOrLessEquals(labelTop - 24, epsilon: 0.1),
      );
      expect(
        tester.getTopRight(find.descendant(of: sticky, matching: total)).dx,
        moreOrLessEquals(totalRight, epsilon: 0.5),
      );
    });
  }

  testWidgets('tapping the sticky header opens the month list', (tester) async {
    final p = FinanceProvider();
    await p.load();
    for (var d = 1; d <= 20; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 10.0 + d,
        note: 'jul $d',
        date: DateTime(2026, 7, d),
      );
    }
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 70,
      note: 'jun 1',
      date: DateTime(2026, 6, 1),
    );
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(300, 450), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(sticky, findsOneWidget);

    // A drag that starts on the strip still scrolls the list beneath it.
    final before = tester.getTopLeft(find.text('jul 10'));
    await tester.dragFrom(tester.getCenter(sticky), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('jul 10')).dy, lessThan(before.dy));

    // The strip itself ignores pointers (so drags reach the list); the tap
    // is caught by the translucent detector wrapped round it.
    await tester.tap(sticky, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Jump to month'), findsWidgets);
    expect(find.text('June 2026'), findsOneWidget);
  });

  testWidgets('a tap that stops a fling does not open the month list', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    for (var d = 1; d <= 28; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 10.0 + d,
        note: 'jul $d',
        date: DateTime(2026, 7, d),
      );
    }
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(300, 450), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(sticky, findsOneWidget);

    await tester.flingFrom(const Offset(300, 500), const Offset(0, -200), 2000);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(tester.getCenter(sticky));
    await tester.pumpAndSettle();
    expect(find.text('Jump to month'), findsNothing);
  });

  testWidgets('the review card folds away once its queue empties', (
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

    final title = find.textContaining('Imported from SMS · 1');
    final card = find.byKey(const ValueKey('pending-card'));
    expect(title, findsOneWidget);
    expect(tester.getSize(card).height, greaterThan(40));

    await p.confirmAllPending();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(title, findsOneWidget, reason: 'still folding away');

    await tester.pumpAndSettle();
    expect(title, findsNothing);
    expect(tester.getSize(card).height, 0, reason: 'takes no space');
  });

  testWidgets('a long-press enters selection and shows the bar', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: 'coffee',
      date: DateTime(2026, 7, 1),
    );
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    final clear = find.byTooltip('Clear selection');
    expect(clear, findsNothing);

    await tester.longPress(find.text('coffee'));
    await tester.pumpAndSettle();
    expect(clear, findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'tile marked');

    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(clear, findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
  });
}
