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

/// Transactions screen motion: the sticky month header, the review cards
/// folding away, and the selection bar folding in on a long-press.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget screen(FinanceProvider p) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: const MaterialApp(home: Scaffold(body: TransactionsScreen())),
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
