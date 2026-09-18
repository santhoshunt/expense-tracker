import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';

/// The transactions filter tabs ride a PageView: drags on the list (and on
/// blank space) switch pages, taps animate, deep-links jump without sliding,
/// and each page owns its own list controller.
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

  PageController pager(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller!;

  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: 'coffee',
      date: DateTime(2026, 7, 1),
    );
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 5000,
      note: 'pay',
      date: DateTime(2026, 7, 2),
    );
    return p;
  }

  testWidgets('a drag on the list switches the filter tab', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    expect(find.text('coffee'), findsOneWidget);
    await tester.fling(find.text('coffee'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    // Income page: only the income row remains.
    expect(find.text('pay'), findsOneWidget);
    expect(find.text('coffee'), findsNothing);
    expect(pager(tester).page, 1);
  });

  testWidgets('an empty page still swipes, and the ends stop', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    expect(find.textContaining('No transactions yet'), findsOneWidget);

    // Fling from blank whitespace: the page's transparent ColoredBox keeps
    // it hit-testable.
    Future<void> swipe(double dx) async {
      await tester.flingFrom(const Offset(400, 400), Offset(dx, 0), 1000);
      await tester.pumpAndSettle();
    }

    await swipe(-300);
    expect(pager(tester).page, 1);

    await swipe(-300);
    await swipe(-300);
    expect(pager(tester).page, 3);

    // End stop: a fourth swipe left stays on Transfers.
    await swipe(-300);
    expect(pager(tester).page, 3);

    await swipe(300);
    expect(pager(tester).page, 2);
  });

  testWidgets('a deep-link jumps to its tab without sliding', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      screen(p, req: const TxFilterRequest(type: TxType.expense), token: 1),
    );
    // Frame one runs the post-frame jump, frame two shows the landed page.
    // Two zero-duration pumps could not carry a 300ms slide, so landing
    // here proves it was a jump.
    await tester.pump();
    await tester.pump();

    expect(pager(tester).page, 2, reason: 'Expenses tab');
    expect(find.text('coffee'), findsOneWidget);
    expect(find.text('pay'), findsNothing);
  });

  testWidgets('the month jump drives the fronted page\'s own list', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    // Enough July expense rows that June starts off-screen, plus income
    // noise so the Expenses page differs from All.
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
      amount: 99,
      note: 'june row',
      date: DateTime(2026, 6, 15),
    );
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 5000,
      note: 'pay',
      date: DateTime(2026, 7, 2),
    );
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    // Front the Expenses page (each fling lands on the next page, so the
    // second one starts from the Income page's own row).
    await tester.fling(find.text('jul 20'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    await tester.fling(find.text('pay'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(pager(tester).page, 2);

    // The header shows the bare month name inside the current year and
    // appends the year outside it — mirror that so the test outlives 2026.
    final june = DateTime(2026, 6);
    final juneHeader = find.text(
      (june.year == DateTime.now().year
              ? DateFormat('MMMM').format(june)
              : DateFormat('MMMM yyyy').format(june))
          .toUpperCase(),
    );
    expect(juneHeader, findsNothing, reason: 'June starts below the fold');

    await tester.drag(find.text('jul 20'), const Offset(0, -50));
    // Let the jump controls finish sliding in (250ms) before tapping —
    // mid-slide their buttons sit off-screen and the tap would miss.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();

    expect(juneHeader, findsOneWidget, reason: 'the Expenses list scrolled');
  });
}
