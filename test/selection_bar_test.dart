import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

/// The long-press bar: four labelled actions and a More menu in one fixed
/// row that fits a narrow phone at large text sizes, plus the bulk Count in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 85000,
      note: 'payday',
      date: DateTime(2026, 9, 30, 18),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 120,
      note: 'coffeerun',
      date: DateTime(2026, 9, 16),
    );
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p, {
    Size size = const Size(400, 800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
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
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> select(WidgetTester tester, String note) async {
    // Found by its row, not its text: at 2x on 320dp the tile leaves the
    // note out to keep the date.
    await tester.longPress(
      find.byWidgetPredicate((w) => w is TransactionTile && w.tx.note == note),
    );
    // Past the bar's fold-in, so its buttons are tappable.
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final scale in [1.3, 2.0]) {
    testWidgets('fits 320dp at text scale $scale', (tester) async {
      final p = await seeded();
      await pump(tester, p, size: const Size(320, 640), textScale: scale);
      expect(tester.takeException(), isNull);
      await select(tester, 'coffeerun');
      expect(tester.takeException(), isNull);
      // The count is the number alone, level with the Clear button.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('selected'), findsNothing);
      expect(find.bySemanticsLabel('1 selected'), findsOneWidget);
      expect(
        tester.getCenter(find.text('1')).dy,
        moreOrLessEquals(
          tester.getCenter(find.byTooltip('Clear selection')).dy,
          epsilon: 0.5,
        ),
      );
      for (final tip in [
        'Set category',
        'Assign account',
        'Count in another date',
        'Delete',
        'More actions',
      ]) {
        expect(find.byTooltip(tip), findsOneWidget, reason: tip);
      }
      // Each label is a whole word at no less than kMinLabelScale of its
      // size, or absent (icon only); never cut to "C…" or shrunk to a speck.
      for (final label in ['Category', 'Account', 'Count in', 'Delete']) {
        final text = find.text(label);
        if (text.evaluate().isEmpty) continue;
        final shown = tester.getSize(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
        );
        final natural = tester.getSize(text);
        expect(
          shown.width / natural.width,
          greaterThanOrEqualTo(kMinLabelScale - 0.001),
          reason: label,
        );
      }
      for (final tip in ['Set category', 'Assign account', 'Delete']) {
        final slot = tester.getSize(
          find
              .descendant(
                of: find.byTooltip(tip),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(slot.height, greaterThanOrEqualTo(48), reason: tip);
      }
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('with room, every action shows its label', (tester) async {
    final p = await seeded();
    await pump(tester, p, size: const Size(800, 800));
    await select(tester, 'coffeerun');
    for (final label in ['Category', 'Account', 'Count in', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('More lists four actions, and Pair only with two selected', (
    tester,
  ) async {
    final p = await seeded();
    await pump(tester, p);
    await select(tester, 'coffeerun');
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    for (final key in ['select-all', 'tags', 'subscription', 'date-time']) {
      expect(find.byKey(ValueKey('bulk-more-$key')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('bulk-more-pair')), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('payday'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bulk-more-pair')), findsOneWidget);
  });

  testWidgets('bulk Count in moves the month figure, and Undo restores', (
    tester,
  ) async {
    final p = await seeded();
    await pump(tester, p);
    await select(tester, 'payday');
    await tester.tap(find.byTooltip('Count in another date'));
    await tester.pumpAndSettle();
    // The pickers open on the 1st of the next month, midnight.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining("account balances don't change"), findsOne);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    final salary = p.transactions.firstWhere((t) => t.note == 'payday');
    expect(salary.countIn, DateTime(2026, 10, 1));
    expect(salary.date, DateTime(2026, 9, 30, 18));
    expect(p.incomeInMonth(DateTime(2026, 9)), 0);
    expect(p.incomeInMonth(DateTime(2026, 10)), 85000);
    expect(find.text('Counts in 1 Oct'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.transactions.firstWhere((t) => t.note == 'payday').countIn, null);
    expect(p.incomeInMonth(DateTime(2026, 9)), 85000);
  });

  testWidgets('bulk Count in puts moved rows back, naming only those', (
    tester,
  ) async {
    final p = await seeded();
    final salary = p.transactions.firstWhere((t) => t.note == 'payday');
    await p.setCountInForMany({salary.id}, DateTime(2026, 10, 1));
    await pump(tester, p);
    await select(tester, 'payday');
    await tester.tap(find.textContaining('coffeerun'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Count in another date'));
    await tester.pumpAndSettle();
    // One of the two is moved, so the option is singular.
    await tester.tap(find.text('Count on its own date'));
    await tester.pumpAndSettle();
    // Two selected, one moved: the dialog counts the one.
    expect(find.text('Put 1 transaction back on its own date?'), findsOne);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(find.text('1 transaction back on its own date.'), findsOne);
    expect(p.transactions.every((t) => t.countIn == null), isTrue);
    expect(p.incomeInMonth(DateTime(2026, 9)), 85000);
  });
}
