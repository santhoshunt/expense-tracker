import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/glossy.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

import 'dashboard_test_utils.dart';

/// The v1.37.0 layout: the month selector and ⋯ menu in the app bar, the
/// balance card's stat columns, the budget rows, the budget and
/// forecast sharing a card, Upcoming's Show all and the notice slot.
/// Amounts and notes are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    LaunchActions.instance.resetForTest();
    availableUpdate.value = null;
    appLocked.value = false;
  });

  tearDown(() => appLocked.value = true);

  final now = DateTime.now();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<(FinanceProvider, SettingsProvider)> pumpHome(
    WidgetTester tester, {
    Future<void> Function(FinanceProvider, SettingsProvider)? seed,
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    await seed?.call(finance, settings);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider.value(value: settings),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
    return (finance, settings);
  }

  Future<void> spend(
    FinanceProvider p,
    String category,
    double amount,
    DateTime date,
  ) => p.addTransaction(
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: 'test $category',
    date: date,
  );

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
  }

  group('the app bar', () {
    testWidgets('the Dashboard title is the month, with its arrows', (
      tester,
    ) async {
      await pumpHome(tester);
      final month = fmtMonth(DateTime(now.year, now.month));
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text(month)),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Previous month'));
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(fmtMonth(DateTime(now.year, now.month - 1))),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Cockpit'), findsNothing);
      // Settings is its own button beside the ⋯.
      expect(find.byTooltip('Settings'), findsOneWidget);
    });

    testWidgets('⋯ holds the page entries, then Cockpit and Who owes you', (
      tester,
    ) async {
      await pumpHome(tester);
      await openMenu(tester);
      for (final label in [
        'This page',
        'Year view',
        'Month report (PDF)',
        'Customise page',
        'App',
        'Cockpit',
        'Who owes you',
      ]) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('Settings'), findsNothing);
      expect(find.byTooltip('About Year view'), findsOneWidget);
      await tester.tap(find.text('Year view'));
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('${now.year}'),
        ),
        findsOneWidget,
        reason: 'the title is the year now',
      );
      await openMenu(tester);
      expect(find.text('Month view'), findsOneWidget);
      expect(find.text('Year report (PDF)'), findsOneWidget);
    });

    testWidgets('the Year button beside the arrows switches the view', (
      tester,
    ) async {
      await pumpHome(tester);
      final toYear = find.descendant(
        of: find.byType(AppBar),
        matching: find.widgetWithText(TextButton, 'Year'),
      );
      expect(toYear, findsOneWidget);
      expect(find.byTooltip('Show Year view'), findsOneWidget);
      // The label no longer carries a ▾; it still opens the picker.
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
      await tester.tap(toYear);
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('${now.year}'),
        ),
        findsOneWidget,
      );
      final toMonth = find.descendant(
        of: find.byType(AppBar),
        matching: find.widgetWithText(TextButton, 'Month'),
      );
      expect(toMonth, findsOneWidget);
      expect(find.byTooltip('Show Month view'), findsOneWidget);
      await tester.tap(toMonth);
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(fmtMonth(DateTime(now.year, now.month))),
        ),
        findsOneWidget,
      );
    });

    testWidgets('About Year view opens the tip', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);
      await tester.tap(find.byTooltip('About Year view'));
      await settle(tester);
      expect(find.textContaining('adds up the 12 months'), findsOneWidget);
    });

    testWidgets('other tabs show their own page entries, then the App ones', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.tap(find.text('Transactions').last);
      await settle(tester);
      await openMenu(tester);
      expect(find.text('Export CSV'), findsOneWidget);
      expect(find.text('Cockpit'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Year view'), findsNothing);
      // Close the menu; Settings is the bar's own button.
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      await tester.tap(find.byTooltip('Settings'));
      await settle(tester);
      expect(find.text('Appearance'), findsOneWidget);
    });

    testWidgets('the page tabs are underline tabs', (tester) async {
      await pumpHome(tester);
      expect(find.byWidgetPredicate((w) => w is UnderlineTabs), findsOneWidget);
      await tester.tap(find.text('Trends'));
      await settle(tester);
      expect(find.text('This month so far'), findsWidgets);
    });
  });

  group('the balance card', () {
    testWidgets('holds Income, Spent and Saved side by side', (tester) async {
      await pumpHome(
        tester,
        seed: (p, _) => spend(p, 'food', 420, DateTime(now.year, now.month, 1)),
      );
      // Each label's tip button is on screen, side by side in one row: the
      // old strip scrolled sideways and cut Saved off.
      final rows = <double>{};
      for (final label in ['Income', 'Spent', 'Saved']) {
        final tip = find.bySemanticsLabel('About $label');
        expect(tip.hitTestable(), findsOneWidget, reason: label);
        final r = tester.getRect(tip);
        expect(r.right, lessThanOrEqualTo(400), reason: label);
        rows.add(r.top.roundToDouble());
      }
      expect(rows, hasLength(1), reason: 'one row');
      // The figure opens the month's spending; the label is its tip.
      await tester.tap(find.text(fmtMoneyWhole(420)).first);
      await settle(tester);
      expect(find.text('test food'), findsOneWidget);
    });

    testWidgets('the Spent label opens its tip, not the rows', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.bySemanticsLabel('About Spent'));
      await settle(tester);
      expect(find.textContaining('Confirmed spending'), findsOneWidget);
    });

    testWidgets('Hide income leaves two columns', (tester) async {
      await pumpHome(tester, seed: (_, s) => s.setHideIncome(true));
      expect(find.text('Income'), findsNothing);
      expect(find.text('Spent'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
    });
  });

  group('budgets', () {
    testWidgets('custom budgets are rows, and a row opens its sheet', (
      tester,
    ) async {
      await pumpHome(
        tester,
        seed: (p, _) async {
          for (final (name, cat) in [
            ('Eating out', 'food'),
            ('Rides', 'transport'),
            ('Gadgets', 'shopping'),
          ]) {
            await p.addBudget(
              name: name,
              limit: 4000,
              mode: BudgetMode.include,
              categoryIds: {cat},
            );
          }
          await spend(p, 'food', 1000, DateTime(now.year, now.month, 1));
        },
      );
      final budgets = find.text('Eating out');
      await tester.scrollUntilVisible(
        budgets,
        300,
        scrollable: verticalScrollable(),
      );
      // Clear of the floating Add button at the bottom edge.
      await tester.drag(verticalScrollable(), const Offset(0, -200));
      await settle(tester);
      for (final name in ['Eating out', 'Rides', 'Gadgets']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(
        find.text('${fmtMoneyTidy(1000)} of ${fmtMoneyTidy(4000)} · 25%'),
        findsOneWidget,
      );
      final left = find.text('${fmtMoneyTidy(3000)} left');
      expect(left, findsOneWidget);
      // v1.43.2: the amount sits at the row's right end, centred between
      // the name and the line under it.
      expect(tester.getRect(left).right, greaterThan(300));
      // The line checked above; its spaces round the dot are no-break.
      final under = find.textContaining(RegExp(r'4,000\W+25%'));
      final middle =
          (tester.getCenter(budgets).dy + tester.getCenter(under).dy) / 2;
      expect((tester.getCenter(left).dy - middle).abs(), lessThan(4));
      // One row each, stacked: the old grid set two side by side.
      final rides = tester.getTopLeft(find.text('Rides'));
      final eating = tester.getTopLeft(budgets);
      expect(rides.dy, greaterThan(eating.dy));
      expect(rides.dx, eating.dx);
      await tester.tap(budgets);
      await settle(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('the cap and the forecast share one card', (tester) async {
      await pumpHome(
        tester,
        seed: (p, s) async {
          await s.setMonthlyBudget(20000);
          await spend(p, 'food', 3000, DateTime(now.year, now.month, 1));
        },
      );
      // The label above the card; the card holds the budget bar's legend
      // and, under a hairline, the forecast.
      expect(find.text('Monthly budget'), findsOneWidget);
      final card = find
          .ancestor(
            of: find.text('Spent, confirmed'),
            matching: find.byType(FrostedPanel),
          )
          .first;
      expect(
        find.descendant(of: card, matching: find.text('Month-end forecast')),
        findsOneWidget,
      );
    });

    testWidgets('with the forecast hidden the budget card stands alone', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'dashboard_layout_v1':
            '{"pages":{"overview":{"order":[],"hidden":["forecast"]}},'
            '"open":{}}',
      });
      await pumpHome(
        tester,
        seed: (p, s) async {
          await s.setMonthlyBudget(20000);
          await spend(p, 'food', 3000, DateTime(now.year, now.month, 1));
        },
      );
      expect(find.text('Monthly budget'), findsOneWidget);
      expect(find.text('Month-end forecast'), findsNothing);
    });
  });

  testWidgets('Upcoming shows six, then Show all', (tester) async {
    await pumpHome(
      tester,
      seed: (p, _) async {
        for (var i = 0; i < 8; i++) {
          await p.addReminder(
            name: 'Bill $i',
            dayOfMonth: now.day,
            expectedAmount: 100.0 + i,
            categoryId: 'bills',
          );
        }
      },
    );
    final showAll = find.text('Show all 8 upcoming');
    await tester.scrollUntilVisible(
      showAll,
      300,
      scrollable: verticalScrollable(),
    );
    expect(showAll, findsOneWidget);
  });

  testWidgets('one notice shows without a pager', (tester) async {
    await pumpHome(tester);
    availableUpdate.value = UpdateList('1.36.0', [
      ReleaseOption(
        tag: 'v1.37.0',
        publishedAt: DateTime(2026, 10, 13),
        sizeBytes: 1,
        notes: '',
        downloadUrl: UpdateService.assetUrlFor('v1.37.0'),
      ),
    ]);
    await settle(tester);
    expect(find.text('Update available: v1.37.0'), findsOneWidget);
    expect(find.textContaining(' of 2'), findsNothing);
  });

  testWidgets('fits 320dp at text x2 on every Dashboard page', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpHome(
      tester,
      size: const Size(320, 640),
      seed: (p, s) async {
        await s.setMonthlyBudget(20000);
        await p.addBudget(
          name: 'Eating out',
          limit: 4000,
          mode: BudgetMode.include,
          categoryIds: {'food'},
        );
        await spend(p, 'food', 3000, DateTime(now.year, now.month, 1));
      },
    );
    expect(tester.takeException(), isNull);
    for (final page in ['Trends', 'Breakdown']) {
      await tester.tap(find.text(page));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: page);
    }
    // The other two tabs, through the bottom bar.
    for (final tab in ['Transactions', 'Accounts']) {
      await tester.tap(find.text(tab).last);
      await settle(tester);
      final e = tester.takeException();
      expect(
        e,
        isNull,
        reason: '$tab: ${e is FlutterError ? e.toStringDeep() : e}',
      );
    }
  });
}
