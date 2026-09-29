import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/widgets/dashboard_fold.dart';

import 'dashboard_test_utils.dart';

/// Trends and Breakdown fold their sections to one line; the order and the
/// hidden ones follow the Cockpit layout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final now = DateTime.now();
    recapClock = () => DateTime(now.year, now.month, 20, 10);
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  tearDown(() => recapClock = DateTime.now);

  Future<SettingsProvider> pump(
    WidgetTester tester, {
    Future<void> Function(SettingsProvider s)? setup,
  }) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 900,
      note: 'Zomato order',
      date: DateTime(now.year, now.month, 2),
      tags: const ['Goa trip'],
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 400,
      note: 'cab',
      date: DateTime(now.year, now.month - 1, 2),
    );
    // Records from before last month, so last month counts in full.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 100,
      note: 'bus',
      date: DateTime(now.year, now.month - 2, 15),
    );
    final s = SettingsProvider();
    await s.load();
    await setup?.call(s);
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
    return s;
  }

  DashboardFold fold(WidgetTester tester, String name) =>
      tester.widget<DashboardFold>(find.byKey(ValueKey('fold-$name')));

  testWidgets('Breakdown opens its first two sections, folds the rest', (
    tester,
  ) async {
    await pump(tester);
    await openDashboardView(tester, 'Breakdown');
    expect(fold(tester, 'donut').open, isTrue);
    expect(fold(tester, 'byCategory').open, isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('fold-merchants')),
      300,
      scrollable: verticalScrollable(),
    );
    final merchants = fold(tester, 'merchants');
    expect(merchants.open, isFalse);
    // A folded section says what it holds.
    expect(merchants.summary, 'Zomato Order ₹900');
    expect(find.text('Zomato Order ₹900'), findsOneWidget);
  });

  testWidgets('tapping a folded heading opens it, and that sticks', (
    tester,
  ) async {
    final s = await pump(tester);
    await openDashboardView(tester, 'Breakdown');
    await openDashboardSection(tester, 'byTags');
    expect(fold(tester, 'byTags').open, isTrue);
    expect(s.sectionOpen(DashboardSection.byTags), isTrue);
    final again = SettingsProvider();
    await again.load();
    expect(again.sectionOpen(DashboardSection.byTags), isTrue);
  });

  testWidgets('a hidden section is gone and the last row counts it', (
    tester,
  ) async {
    await pump(
      tester,
      setup: (s) => s.setSectionHidden(DashboardSection.merchants, true),
    );
    await openDashboardView(tester, 'Breakdown');
    await tester.drag(verticalScrollable(), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fold-merchants')), findsNothing);
    expect(find.text('Customise this page · 1 hidden'), findsOneWidget);
  });

  testWidgets('Trends follows the stored order', (tester) async {
    await pump(
      tester,
      setup: (s) => s.setDashboardOrder(DashboardPage.trends, [
        DashboardSection.sixMonths,
        DashboardSection.pace,
        DashboardSection.previousMonth,
        DashboardSection.usual,
        DashboardSection.categoryComparison,
      ]),
    );
    await openDashboardView(tester, 'Trends');
    final chart = tester.getTopLeft(
      find.byKey(const ValueKey('fold-sixMonths')),
    );
    final pace = tester.getTopLeft(find.byKey(const ValueKey('fold-pace')));
    expect(chart.dy, lessThan(pace.dy));
  });

  testWidgets('Trends summaries follow the cards', (tester) async {
    await pump(tester);
    await openDashboardView(tester, 'Trends');
    // 900 this month against 400 on the same days last month.
    expect(fold(tester, 'previousMonth').summary, startsWith('Up '));
    // One month on record: no usual yet, so no category reads as up.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('fold-categoryComparison')),
      300,
      scrollable: verticalScrollable(),
    );
    expect(fold(tester, 'categoryComparison').summary, isNull);
    // Its card keeps one title, the fold's.
    await openDashboardSection(tester, 'categoryComparison');
    expect(find.text('Categories vs usual'), findsOneWidget);
  });

  testWidgets('every Trends and Breakdown heading carries its tip', (
    tester,
  ) async {
    await pump(tester);
    final seen = <String, DashboardFold>{};
    for (final view in ['Trends', 'Breakdown']) {
      await openDashboardView(tester, view);
      for (var i = 0; i < 12; i++) {
        for (final f in tester.widgetList<DashboardFold>(
          find.byType(DashboardFold),
        )) {
          seen[(f.key! as ValueKey<String>).value] = f;
        }
        await tester.drag(verticalScrollable(), const Offset(0, -300));
        await tester.pumpAndSettle();
      }
    }
    expect(
      seen.keys,
      containsAll([
        for (final s in [
          'pace',
          'previousMonth',
          'usual',
          'categoryComparison',
          'sixMonths',
          'donut',
          'byCategory',
          'byTags',
          'merchants',
          'heatmap',
        ])
          'fold-$s',
      ]),
    );
    for (final e in seen.entries) {
      expect(e.value.tip, isNotNull, reason: e.key);
    }
  });

  testWidgets('an open Trends card leaves its tip to the heading', (
    tester,
  ) async {
    await pump(tester);
    await openDashboardView(tester, 'Trends');
    // Open by default, with its own card title and no second tip.
    expect(fold(tester, 'pace').open, isTrue);
    expect(find.bySemanticsLabel('About This month so far'), findsOneWidget);
    await openDashboardSection(tester, 'categoryComparison');
    expect(find.bySemanticsLabel('About Categories vs usual'), findsOneWidget);
  });

  testWidgets('Last 6 months folds to the finished months\' average', (
    tester,
  ) async {
    await pump(tester);
    await openDashboardView(tester, 'Trends');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('fold-sixMonths')),
      300,
      scrollable: verticalScrollable(),
    );
    // 400 last month. The month before starts on the 15th, so it is not
    // fully on record, and this month is still running.
    expect(fold(tester, 'sixMonths').summary, '₹400 a month on average');
    // A month back: last month is still a finished month. An average
    // anchored on the shown month would drop it and have nothing left.
    await tester.drag(verticalScrollable(), const Offset(0, 4000));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('fold-sixMonths')),
      300,
      scrollable: verticalScrollable(),
    );
    expect(fold(tester, 'sixMonths').summary, '₹400 a month on average');
  });

  testWidgets('the Overview never folds', (tester) async {
    await pump(tester);
    expect(find.byType(DashboardFold), findsNothing);
    await tester.drag(verticalScrollable(), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(find.text('Customise this page'), findsOneWidget);
  });

  testWidgets('a fold heading fits a narrow phone at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(1.6),
          ),
          child: Scaffold(
            body: DashboardFold(
              title: 'Against a usual month',
              summary: 'Up 12% on a usual month, and a long tail of words',
              tip: const Icon(Icons.info_outline),
              open: false,
              onChanged: (_) {},
              children: const [SizedBox(height: 40)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
