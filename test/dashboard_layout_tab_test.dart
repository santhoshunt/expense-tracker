import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';

/// Cockpit, Dashboard: reorder and hide each page's sections.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<SettingsProvider> pump(WidgetTester tester, int tab) async {
    // Tall enough for a whole page's rows, each with its 48dp Open/Folded
    // target, so the drags below never start off screen. On a phone the
    // page is longer than the screen and the list auto-scrolls during a
    // drag: it is the page's only scrollable.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: ClassifiersScreen(initialTab: tab)),
      ),
    );
    await tester.pumpAndSettle();
    return s;
  }

  testWidgets('the Dashboard group has a tab per page', (tester) async {
    await pump(tester, kCockpitTabDashBreakdown);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Trends'), findsOneWidget);
    expect(find.text('Breakdown'), findsOneWidget);
    expect(find.text('Top merchants'), findsOneWidget);
    expect(find.text('Folded'), findsWidgets);
  });

  testWidgets('Open / Folded sets how a section starts', (tester) async {
    final s = await pump(tester, kCockpitTabDashBreakdown);
    expect(s.sectionOpen(DashboardSection.merchants), isFalse);
    await tester.tap(find.bySemanticsLabel('Top merchants, starts folded'));
    await tester.pumpAndSettle();
    expect(s.sectionOpen(DashboardSection.merchants), isTrue);
    // Stored, the same state a tap on the dashboard heading sets.
    final again = SettingsProvider();
    await again.load();
    expect(again.sectionOpen(DashboardSection.merchants), isTrue);
    expect(find.bySemanticsLabel('Top merchants, starts open'), findsOneWidget);
    // A hidden section says so instead.
    await tester.tap(find.bySemanticsLabel('Show Top merchants'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Top merchants'),
        matching: find.text('Hidden'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a switch hides a section', (tester) async {
    final s = await pump(tester, kCockpitTabDashOverview);
    await tester.tap(find.bySemanticsLabel('Show Who owes you'));
    await tester.pumpAndSettle();
    expect(s.dashboardLayout(DashboardPage.overview).hidden, {
      DashboardSection.owed,
    });
    expect(s.hiddenSectionCount, 1);
  });

  testWidgets('dragging a row moves the section', (tester) async {
    final s = await pump(tester, kCockpitTabDashTrends);
    final handle = find.descendant(
      of: find.widgetWithText(ListTile, 'Last 6 months'),
      matching: find.byIcon(Icons.drag_indicator),
    );
    final top = tester.getTopLeft(
      find.widgetWithText(ListTile, 'This month so far'),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    // In steps: the list reorders as the dragged row passes the others.
    final start = tester.getCenter(handle);
    for (var y = start.dy; y > top.dy - 40; y -= 20) {
      await gesture.moveTo(Offset(start.dx, y));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      s.dashboardLayout(DashboardPage.trends).order.first,
      DashboardSection.sixMonths,
    );
  });

  testWidgets('dragging a row down moves the section down', (tester) async {
    final s = await pump(tester, kCockpitTabDashTrends);
    final handle = find.descendant(
      of: find.widgetWithText(ListTile, 'This month so far'),
      matching: find.byIcon(Icons.drag_indicator),
    );
    // Just past the target row's middle: the list swaps rows as the
    // dragged one's centre crosses theirs.
    final below = tester.getCenter(
      find.widgetWithText(ListTile, 'This month vs usual'),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    final start = tester.getCenter(handle);
    for (var y = start.dy; y < below.dy + 10; y += 20) {
      await gesture.moveTo(Offset(start.dx, y));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(s.dashboardLayout(DashboardPage.trends).order, [
      DashboardSection.previousMonth,
      DashboardSection.usual,
      DashboardSection.pace,
      DashboardSection.categoryComparison,
      DashboardSection.sixMonths,
    ]);
  });

  testWidgets('the Cockpit hub counts hidden sections', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    await s.setSectionHidden(DashboardSection.transfers, true);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: const MaterialApp(home: ClassifiersScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('1 hidden'), 200);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('1 hidden'), findsOneWidget);
  });

  testWidgets('Reset to default asks, then restores the page', (tester) async {
    final s = await pump(tester, kCockpitTabDashOverview);
    await s.setSectionHidden(DashboardSection.owed, true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    expect(find.text('Reset this page?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(s.dashboardLayout(DashboardPage.overview).hidden, isEmpty);
  });
}
