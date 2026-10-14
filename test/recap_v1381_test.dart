import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/services/spend_history.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';
import 'package:expense_tracker/widgets/spend_history_sheet.dart';

/// v1.38.1: the recap and pace cards sit flush (no margin), the recap's
/// top categories are one row each, the history sheet shows Rename for a
/// merchant, and the forecast's Spent so far says how many rows wait for
/// review. Names and amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // Fixed dates: August 2026 is the recapped month, September the running
  // one.
  final aug = DateTime(2026, 8);
  final recapDay = DateTime(2026, 9, 3, 10);
  final paceDay = DateTime(2026, 9, 20, 10);

  Future<(FinanceProvider, SettingsProvider)> providers({
    double scale = 1,
  }) async {
    final p = FinanceProvider();
    await p.load();
    Future<void> spend(String category, double amount, DateTime date) =>
        p.addTransaction(
          type: TxType.expense,
          categoryId: category,
          amount: amount * scale,
          note: 'test $category',
          date: date,
        );
    await spend('transport', 400, DateTime(2026, 8, 2));
    await spend('food', 250, DateTime(2026, 8, 5));
    await spend('shopping', 120, DateTime(2026, 8, 9));
    await spend('food', 180, DateTime(2026, 9, 4));
    final s = SettingsProvider();
    await s.load();
    return (p, s);
  }

  Future<void> pumpCard(
    WidgetTester tester,
    FinanceProvider p,
    SettingsProvider s,
    Widget card, {
    Size size = const Size(400, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(padding: const EdgeInsets.all(16), children: [card]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Card cardOf(WidgetTester tester, Type type) => tester.widget<Card>(
    find.descendant(of: find.byType(type), matching: find.byType(Card)).first,
  );

  testWidgets('the recap and pace cards have no margin', (tester) async {
    final (p, s) = await providers();
    await pumpCard(
      tester,
      p,
      s,
      MonthlyRecapCard(recap: buildMonthlyRecap(p, s, now: recapDay)!),
    );
    expect(cardOf(tester, MonthlyRecapCard).margin, EdgeInsets.zero);

    await pumpCard(
      tester,
      p,
      s,
      MonthPaceCard(pace: buildMonthPace(p, s, now: paceDay)!),
    );
    expect(cardOf(tester, MonthPaceCard).margin, EdgeInsets.zero);
  });

  testWidgets('the top categories are one row each, amount on the right', (
    tester,
  ) async {
    final (p, s) = await providers();
    final opened = <(String, DateTime)>[];
    await pumpCard(
      tester,
      p,
      s,
      MonthlyRecapCard(
        recap: buildMonthlyRecap(p, s, now: recapDay)!,
        onViewCategory: (id, month) => opened.add((id, month)),
      ),
    );
    expect(find.text('Top categories'), findsOneWidget);
    expect(find.textContaining('Top:'), findsNothing);
    expect(find.text(' · '), findsNothing);
    for (final (id, amount) in [
      ('transport', 400.0),
      ('food', 250.0),
      ('shopping', 120.0),
    ]) {
      final name = find.text(categoryById(id).label);
      expect(name, findsOneWidget, reason: id);
      final row = find.ancestor(of: name, matching: find.byType(InkWell)).first;
      final figure = find.descendant(
        of: row,
        matching: find.text(fmtMoney(amount)),
      );
      expect(figure, findsOneWidget, reason: id);
      expect(
        tester.getCenter(figure).dx,
        greaterThan(tester.getCenter(name).dx),
        reason: 'the amount sits right of the name',
      );
      expect(tester.getSize(row).height, greaterThanOrEqualTo(40));
      await tester.tap(row);
      expect(opened.last, (id, aug));
    }
    // Semantics: each row is a button.
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('Transport')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('the recap fits 320dp at double text size', (tester) async {
    final (p, s) = await providers(scale: 870);
    await pumpCard(
      tester,
      p,
      s,
      MonthlyRecapCard(
        recap: buildMonthlyRecap(p, s, now: recapDay)!,
        onViewCategory: (_, _) {},
      ),
      size: const Size(320, 1600),
      textScale: 2,
    );
    expect(find.text('Top categories'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Biggest merchant stacks at large text: the value gets the width.
    final label = find.text('Biggest merchant');
    expect(label, findsOneWidget);
    expect(
      tester.getTopLeft(find.textContaining('(1 payment)')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(label).dy),
    );
    expect(
      tester.getTopLeft(find.textContaining('(1 payment)')).dx,
      tester.getTopLeft(label).dx,
    );
  });

  group('the Overview', () {
    tearDown(() => recapClock = DateTime.now);

    /// The Overview in the recap week of the running month, with last
    /// month's pay and fares, this month's spending and one row waiting
    /// for review. Must use the real clock: the forecast is built only for
    /// the month DateTime.now() falls in (_monthPlanSlot has no clock to
    /// set), so the rows sit on the 1st and 2nd: never in the future. The
    /// recap's day is fixed through recapClock.
    Future<FinanceProvider> pumpOverview(
      WidgetTester tester, {
      required Size size,
      double textScale = 1,
    }) async {
      final now = DateTime.now();
      final last = DateTime(now.year, now.month - 1);
      recapClock = () => DateTime(now.year, now.month, 3, 10);
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 275000,
        note: 'test pay',
        date: DateTime(last.year, last.month, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 400,
        note: 'test fares',
        date: DateTime(last.year, last.month, 2),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 2400,
        note: 'test groceries',
        date: DateTime(now.year, now.month, 1),
      );
      await p.restoreTransaction(
        Tx(
          id: 'test-pending',
          type: TxType.expense,
          categoryId: 'food',
          amount: 300,
          note: 'test pending',
          date: DateTime(now.year, now.month, 1),
          pending: true,
        ),
      );
      final s = SettingsProvider();
      await s.load();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(body: DashboardScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return p;
    }

    testWidgets('at 320dp and double text the balance scales, never cut', (
      tester,
    ) async {
      final p = await pumpOverview(
        tester,
        size: const Size(320, 4000),
        textScale: 2,
      );
      final hero = find.byKey(const ValueKey('balance-figure'));
      final figure = find.descendant(
        of: hero,
        matching: find.text(fmtMoney(p.balance)),
      );
      expect(figure, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: figure, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'no ellipsis');
      expect(tester.getTopRight(hero).dx, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });

    testWidgets('at 320dp and double text the forecast labels wrap whole '
        'words', (tester) async {
      await pumpOverview(tester, size: const Size(320, 4000), textScale: 2);
      RenderParagraph paragraphOf(String text) {
        final label = find.text(text);
        expect(label, findsOneWidget, reason: text);
        return tester.renderObject<RenderParagraph>(
          find.descendant(of: label, matching: find.byType(RichText)),
        );
      }

      // Wrapped, never cut short.
      for (final text in [
        'Spent so far, with 1 to review',
        'Month-end forecast',
      ]) {
        expect(paragraphOf(text).didExceedMaxLines, isFalse, reason: text);
      }
      // The label column keeps room for a whole word: "spending" in Roboto
      // at double size is about 125dp, and 2x text in a 112dp column broke
      // it. (The test font's square glyphs are wider than Roboto's, so the
      // check is on the column, not the words.)
      expect(
        paragraphOf('Spent so far, with 1 to review').constraints.maxWidth,
        greaterThanOrEqualTo(140),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('at 390dp the forecast and recap amounts end together', (
      tester,
    ) async {
      await pumpOverview(tester, size: const Size(390, 4000));
      // Spent so far: this month's ₹2,400 and the ₹300 waiting.
      final forecastAmount = find.text(fmtMoney(2700));
      expect(forecastAmount, findsOneWidget);
      // The recap's Transport row: of its two ₹400 figures (Spent and the
      // row), the one level with the category name.
      final transport = find.descendant(
        of: find.byType(MonthlyRecapCard),
        matching: find.text('Transport'),
      );
      final rowY = tester.getCenter(transport).dy;
      final recapAmount = find
          .descendant(
            of: find.byType(MonthlyRecapCard),
            matching: find.text(fmtMoney(400)),
          )
          .evaluate()
          .where(
            (e) =>
                (tester.getCenter(find.byWidget(e.widget)).dy - rowY).abs() < 1,
          )
          .toList();
      expect(recapAmount, hasLength(1));
      expect(
        tester.getTopRight(forecastAmount).dx,
        moreOrLessEquals(
          tester.getTopRight(find.byWidget(recapAmount.single.widget)).dx,
          epsilon: 0.5,
        ),
      );
    });
  });

  test('pendingSpendCountIn counts the rows pendingSpendIn adds up', () async {
    final p = FinanceProvider();
    await p.load();
    Tx row(String id, DateTime date, {bool spam = false, String? cat}) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: cat ?? 'food',
      amount: 100,
      note: 'test $id',
      date: date,
      pending: true,
      suspectedSpam: spam,
    );
    await p.restoreTransactions([
      row('a', DateTime(2026, 9, 2)),
      row('b', DateTime(2026, 9, 5)),
      row('spam', DateTime(2026, 9, 6), spam: true),
      row('move', DateTime(2026, 9, 7), cat: 'transfer_out'),
      row('august', DateTime(2026, 8, 30)),
    ]);
    final sep = DateTime(2026, 9);
    expect(pendingSpendCountIn(p, sep), 2);
    expect(pendingSpendIn(p, sep), 200);
  });

  group('the history sheet', () {
    Future<void> openSheet(
      WidgetTester tester,
      FinanceProvider p,
      SettingsProvider s,
      HistorySubject subject,
    ) async {
      await pumpCard(
        tester,
        p,
        s,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpendHistorySheet(
              context,
              subject: subject,
              months: [DateTime(2026, 8), DateTime(2026, 9)],
              windowLabel: 'Aug to Sep 2026',
              yearView: false,
            ),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a merchant shows Rename, which renames it', (tester) async {
      final (p, s) = await providers();
      await openSheet(
        tester,
        p,
        s,
        const HistorySubject.merchant('upi|test cafe', 'Test Cafe'),
      );
      expect(find.text('Test Cafe'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Rename'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename merchant'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Corner Cafe');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(p.merchantAlias('test cafe'), 'Corner Cafe');
      expect(find.text('Corner Cafe'), findsOneWidget, reason: 'sheet title');
    });

    testWidgets('a category has no Rename', (tester) async {
      final (p, s) = await providers();
      await openSheet(
        tester,
        p,
        s,
        HistorySubject.category('food', categoryById('food').label),
      );
      expect(find.text('Rename'), findsNothing);
    });
  });

  testWidgets('Spent so far says how many rows wait for review', (
    tester,
  ) async {
    // Must use the real clock: the Dashboard builds the forecast only for
    // the running month, read from DateTime.now() in _monthPlanSlot with no
    // clock to set (recapClock moves only the recap). The rows sit on the
    // month's 1st at midnight: never in the future, whatever day it runs.
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, 1);
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1200,
      note: 'test groceries',
      date: first,
    );
    await p.restoreTransaction(
      Tx(
        id: 'test-pending',
        type: TxType.expense,
        categoryId: 'food',
        amount: 300,
        note: 'test pending',
        date: first,
        pending: true,
      ),
    );
    final s = SettingsProvider();
    await s.load();
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Spent so far, with 1 to review'), findsOneWidget);
    expect(find.text('Spent so far'), findsNothing);
  });
}
