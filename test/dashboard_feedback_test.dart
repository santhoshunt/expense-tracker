import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/comparison_series.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/utils/dates.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/comparison_chart_sheet.dart';
import 'package:expense_tracker/widgets/dashboard_fold.dart';
import 'package:expense_tracker/widgets/grouped_surface.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';
import 'package:expense_tracker/widgets/spending_heatmap.dart';

import 'dashboard_test_utils.dart';

/// The v1.38.0 Dashboard polish: a steady chart sheet, open folds as their
/// own cards, budget rows, the detected Upcoming row's actions with Undo,
/// the recap's Done and a reminder from a heatmap day. Amounts and names
/// are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final now = DateTime.now();
    // Past the recap week, so the Overview opens on the same cards each
    // run.
    recapClock = () => DateTime(now.year, now.month, 20, 10);
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  tearDown(() => recapClock = DateTime.now);

  Future<SettingsProvider> pumpDashboard(
    WidgetTester tester,
    FinanceProvider p, {
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: dashboardShell(const DashboardScreen())),
      ),
    );
    await tester.pumpAndSettle();
    return s;
  }

  group('comparison chart sheet', () {
    testWidgets('keeps its height between Last month and Usual', (
      tester,
    ) async {
      // Tall, so the content sets the sheet's height rather than its cap.
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final series = ComparisonSeries(
        month: DateTime(2026, 10),
        // A long month name: Last month's lines wrap more than Usual's.
        previousMonth: DateTime(2026, 9),
        days: 31,
        today: 10,
        actual: [for (var d = 1; d <= 10; d++) d * 120.0],
        predicted: [for (var d = 10; d <= 31; d++) d * 120.0],
        lastMonth: [for (var d = 1; d <= 30; d++) d * 100.0],
        usual: [for (var d = 1; d <= 31; d++) d * 90.0],
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showComparisonChartSheet(
                    context,
                    series: series,
                    startOnUsual: false,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final before = tester.getSize(find.byType(BottomSheet)).height;
      expect(
        find.textContaining('all of September').hitTestable(),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<bool>),
          matching: find.text('Usual'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BottomSheet)).height, before);
      expect(
        find.textContaining('a usual month').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('figures are whole rupees, as on the Trends card', (
      tester,
    ) async {
      final series = ComparisonSeries(
        month: DateTime(2026, 10),
        previousMonth: DateTime(2026, 9),
        days: 31,
        today: 10,
        actual: [for (var d = 1; d <= 10; d++) d * 120.25],
        predicted: [for (var d = 10; d <= 31; d++) d * 1525.24],
        lastMonth: [for (var d = 1; d <= 30; d++) d * 100.5],
        usual: null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showComparisonChartSheet(
                    context,
                    series: series,
                    startOnUsual: false,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 31 x ₹1,525.24 is ₹47,282.44.
      expect(
        find.textContaining('Forecast ${fmtMoneyWhole(47282.44)}'),
        findsWidgets,
      );
      expect(
        find.textContaining('So far ${fmtMoneyWhole(1202.5)}'),
        findsWidgets,
      );
      // No figure carries paise.
      expect(find.textContaining(RegExp(r'₹[\d,]+\.\d')), findsNothing);
    });

    testWidgets('a picked day reads two lines, inside 320dp at text x2', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final series = ComparisonSeries(
        month: DateTime(2026, 10),
        previousMonth: DateTime(2026, 9),
        days: 31,
        today: 10,
        actual: [for (var d = 1; d <= 10; d++) d * 120.0],
        predicted: [for (var d = 10; d <= 31; d++) d * 120.0],
        lastMonth: [for (var d = 1; d <= 30; d++) d * 100.0],
        usual: [for (var d = 1; d <= 31; d++) d * 90.0],
        dueByDay: {
          12: [(label: 'Rent', amount: 500, due: DateTime(2026, 10, 12))],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showComparisonChartSheet(
                    context,
                    series: series,
                    startOnUsual: false,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final chart = tester.getRect(
        find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              '${w.painter.runtimeType}' == '_ComparisonChartPainter',
        ),
      );
      // Right of the axis labels, near each edge: day 1, then the last.
      Future<Rect> pick(Offset at, String first, String second) async {
        await tester.tapAt(at);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(first), findsOneWidget);
        expect(find.text(second), findsOneWidget);
        return tester.getRect(
          find
              .ancestor(
                of: find.text(first),
                matching: find.byType(IgnorePointer),
              )
              .first,
        );
      }

      for (final bubble in [
        await pick(chart.topLeft + const Offset(41, 100), 'Thu Oct 1', 'Sep 1'),
        await pick(
          chart.topRight + const Offset(-1, 100),
          'Sat Oct 31',
          'All Sep',
        ),
      ]) {
        // Whole on screen, below the Today label, above the day dial.
        expect(bubble.left, greaterThanOrEqualTo(chart.left - 16));
        expect(bubble.right, lessThanOrEqualTo(chart.right + 16));
        expect(bubble.top, greaterThanOrEqualTo(chart.top + 14));
        expect(bubble.bottom, lessThanOrEqualTo(chart.bottom));
      }
      expect(find.text(fmtMoneyWhole(3720)), findsOneWidget);
      expect(find.text(fmtMoneyWhole(3000)), findsOneWidget);
      for (final gone in ['That day', 'Rent', 'Expected by then']) {
        expect(find.textContaining(gone), findsNothing, reason: gone);
      }

      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<bool>),
          matching: find.text('Usual'),
        ),
      );
      await tester.pumpAndSettle();
      // A usual month on the last day: all of it, labelled Usual.
      expect(find.text('All Sep'), findsNothing);
      expect(find.text(fmtMoneyWhole(2790)), findsOneWidget);
    });
  });

  group('folds', () {
    DashboardFold fold(WidgetTester tester, String name) =>
        tester.widget<DashboardFold>(find.byKey(ValueKey('fold-$name')));

    Rect surface(WidgetTester tester, String name) => tester.getRect(
      find
          .descendant(
            of: find.byKey(ValueKey('fold-$name')),
            matching: find.byType(GroupedSurface),
          )
          .first,
    );

    testWidgets('an open section is its own card; folded ones stay one', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 900,
        note: 'Zomato order',
        date: DateTime(now.year, now.month, 1),
        tags: const ['Goa trip'],
      );
      await pumpDashboard(tester, p);
      await openDashboardView(tester, 'Breakdown');

      // Spending split and By category start open: each its own card.
      for (final name in ['donut', 'byCategory']) {
        expect(fold(tester, name).open, isTrue, reason: name);
        expect(fold(tester, name).first, isTrue, reason: name);
        expect(fold(tester, name).last, isTrue, reason: name);
      }
      // A gap between the two open cards.
      expect(
        surface(tester, 'byCategory').top - surface(tester, 'donut').bottom,
        greaterThanOrEqualTo(10),
      );
      // By tags and Top merchants, both folded, share one card.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('fold-merchants')),
        300,
        scrollable: verticalScrollable(),
      );
      expect(fold(tester, 'byTags').first, isTrue);
      expect(fold(tester, 'byTags').last, isFalse);
      expect(fold(tester, 'merchants').first, isFalse);

      // Opened, Top merchants breaks out, and By tags ends its run.
      await openDashboardSection(tester, 'merchants');
      expect(fold(tester, 'merchants').first, isTrue);
      expect(fold(tester, 'merchants').last, isTrue);
      expect(fold(tester, 'byTags').last, isTrue);
    });
  });

  group('budget rows', () {
    testWidgets('fit 320dp at text x2, the overshoot in red', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      await p.addBudget(
        name: 'Weekend dining and takeaway',
        limit: 600,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1200,
        note: 'dinner',
        date: DateTime(now.year, now.month, 1),
      );
      await pumpDashboard(tester, p, size: const Size(320, 640));
      expect(tester.takeException(), isNull);

      final over = find.text('${fmtMoneyTidy(600)} over');
      await tester.scrollUntilVisible(
        over,
        300,
        scrollable: verticalScrollable(),
      );
      expect(tester.takeException(), isNull);
      // v1.43.1: the overshoot shares the ring's red.
      final ctx = tester.element(over);
      expect(
        tester.widget<Text>(over).style?.color,
        Theme.of(ctx).colorScheme.error,
      );
      expect(
        find.text('${fmtMoneyTidy(1200)} of ${fmtMoneyTidy(600)} · 200%'),
        findsOneWidget,
      );

      // A button for screen readers, its tap reachable.
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(
          find
              .ancestor(
                of: find.text('Weekend dining and takeaway'),
                matching: find.byType(InkWell),
              )
              .first,
        ),
        isSemantics(isButton: true, hasTapAction: true),
      );
      semantics.dispose();
    });
  });

  group('a detected Upcoming row', () {
    /// Netflix every 30 days, due today.
    Future<FinanceProvider> seeded() async {
      final p = FinanceProvider();
      await p.load();
      final today = DateTime.now();
      final day = DateTime(today.year, today.month, today.day);
      for (final ago in [90, 60, 30]) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'entertainment',
          amount: 499,
          note: 'Netflix',
          date: day.subtract(Duration(days: ago)),
        );
      }
      return p;
    }

    /// Next 7 days sits on Ahead, folded at first.
    Future<void> openUpcoming(WidgetTester tester) async {
      await openDashboardView(tester, 'Ahead');
      await openDashboardSection(tester, 'upcoming');
    }

    /// The Netflix row inside Next 7 days: the Expected balance section
    /// above it lists the payment too.
    final upcomingRow = find.descendant(
      of: find.byKey(const ValueKey('fold-upcoming')),
      matching: find.text('Netflix'),
    );

    Future<void> openRow(WidgetTester tester) async {
      await openUpcoming(tester);
      final row = upcomingRow;
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: verticalScrollable(),
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    testWidgets('a tap opens View transactions, Make a reminder and Hide', (
      tester,
    ) async {
      TxFilterRequest? opened;
      final owner = Object();
      AppNav.instance.attachHome(
        owner,
        setTab: (_) {},
        openTransactions: (r) => opened = r,
      );
      addTearDown(() => AppNav.instance.detachHome(owner));
      await pumpDashboard(tester, await seeded());

      await openRow(tester);
      expect(find.text('View transactions'), findsOneWidget);
      expect(find.text('Make a reminder'), findsOneWidget);
      expect(find.text('Hide'), findsOneWidget);

      await tester.tap(find.text('View transactions'));
      await tester.pumpAndSettle();
      expect(opened?.type, TxType.expense);
      expect(opened?.query, 'netflix');
    });

    testWidgets('Hide asks, hides, and Undo brings it back', (tester) async {
      final s = await pumpDashboard(tester, await seeded());

      await openRow(tester);
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.text('Hide "Netflix"?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Hide'));
      await tester.pumpAndSettle();
      expect(s.hiddenUpcoming, contains('expense|netflix'));

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(s.hiddenUpcoming, isEmpty);
    });

    testWidgets('its sheet fits 320dp at text x2', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpDashboard(tester, await seeded(), size: const Size(320, 640));
      await openRow(tester);
      final e = tester.takeException();
      expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
      expect(find.text('View transactions'), findsOneWidget);
      // The last action is reachable by scrolling the sheet.
      final hide = find.text('Hide');
      await tester.ensureVisible(hide);
      await tester.pumpAndSettle();
      expect(hide.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long-press no longer hides: it acts as the tap', (
      tester,
    ) async {
      await pumpDashboard(tester, await seeded());
      await openUpcoming(tester);
      final row = upcomingRow;
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: verticalScrollable(),
      );
      await tester.longPress(row);
      await tester.pumpAndSettle();
      // No hide question; Hide waits in the row's sheet.
      expect(find.text('Hide "Netflix"?'), findsNothing);
      expect(find.text('Hide'), findsOneWidget);
    });
  });

  testWidgets('Done puts the recap away, and Undo brings it back', (
    tester,
  ) async {
    final now = DateTime.now();
    final lastMonth = DateTime(now.year, now.month - 1);
    recapClock = () => DateTime(now.year, now.month, 3, 10);
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 400,
      note: 'Metro pass',
      date: DateTime(lastMonth.year, lastMonth.month, 2),
    );
    final s = await pumpDashboard(tester, p);
    expect(find.byType(MonthlyRecapCard), findsOneWidget);

    final done = find.widgetWithText(TextButton, 'Done');
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(s.recapDismissed, monthKey(lastMonth));
    expect(find.byType(MonthlyRecapCard), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(s.recapDismissed, isNull);
    expect(find.byType(MonthlyRecapCard), findsOneWidget);
  });

  group('heatmap', () {
    Future<void> pumpHeatmap(WidgetTester tester, DateTime month) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = FinanceProvider();
      await p.load();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: SpendingHeatmap(month: month)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a day ahead opens its sheet with Set a reminder', (
      tester,
    ) async {
      final now = DateTime.now();
      // Next month: every day of it is ahead, whatever today is.
      await pumpHeatmap(tester, DateTime(now.year, now.month + 1));
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing due on this day'), findsOneWidget);
      final set = find.text('Set a reminder');
      expect(set, findsOneWidget);

      await tester.tap(set);
      await tester.pumpAndSettle();
      expect(find.text('Nothing due on this day'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('a reminder with no amount gets its dot and sheet line', (
      tester,
    ) async {
      final now = DateTime.now();
      final p = FinanceProvider();
      await p.load();
      // Due today: today is always within "today to the month's end".
      await p.addReminder(
        name: 'Passport renewal',
        dayOfMonth: now.day,
        categoryId: 'other_expense',
      );
      await pumpDashboard(tester, p);
      await openDashboardView(tester, 'Breakdown');
      await openDashboardSection(tester, 'heatmap');
      expect(
        tester
            .widget<DashboardFold>(find.byKey(const ValueKey('fold-heatmap')))
            .open,
        isTrue,
      );
      final today = find.descendant(
        of: find.byType(SpendingHeatmap),
        matching: find.text('${now.day}'),
      );
      await tester.ensureVisible(today);
      await tester.pumpAndSettle();
      await tester.tap(today);
      await tester.pumpAndSettle();
      Finder inSheet(String text) => find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(text),
      );
      expect(inSheet('Due'), findsOneWidget);
      expect(inSheet('Passport renewal'), findsOneWidget);
      // No amount to show: no figure, not "₹0".
      expect(inSheet(fmtMoneyWhole(0)), findsNothing);
    });

    testWidgets('an empty day gone by opens nothing', (tester) async {
      final now = DateTime.now();
      await pumpHeatmap(tester, DateTime(now.year, now.month - 1));
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Set a reminder'), findsNothing);
    });
  });
}
