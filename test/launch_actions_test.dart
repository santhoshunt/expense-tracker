import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/category_donut_chart.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';

/// Shortcut, tile and notification actions: they wait for the app lock,
/// run once, and land on top of whatever is open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    LaunchActions.instance.resetForTest();
    appLocked.value = false;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(LaunchActions.channel, null);
    LaunchActions.instance.resetForTest();
    appLocked.value = true;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    Future<void> Function(FinanceProvider)? seed,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    await seed?.call(finance);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
  }

  // The add sheet's amount field.
  final addSheet = find.widgetWithText(TextFormField, 'Amount');

  testWidgets('a cold-start action waits for unlock, then runs once', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      LaunchActions.channel,
      (call) async => call.method == 'takeLaunchAction' ? 'add_expense' : null,
    );
    appLocked.value = true;
    await LaunchActions.instance.init();
    expect(LaunchActions.instance.pending.value, LaunchAction.addExpense);

    await pumpHome(tester);
    expect(addSheet, findsNothing, reason: 'still locked');

    appLocked.value = false;
    await settle(tester);
    expect(addSheet, findsOneWidget);
    expect(LaunchActions.instance.pending.value, isNull);

    // Closing the sheet and relocking does not replay it.
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    appLocked.value = true;
    appLocked.value = false;
    await settle(tester);
    expect(addSheet, findsNothing);
  });

  testWidgets('a warm launch from the native side opens the sheet', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      LaunchActions.channel,
      (call) async => null,
    );
    await LaunchActions.instance.init();
    await pumpHome(tester);
    expect(addSheet, findsNothing);

    await messenger.handlePlatformMessage(
      LaunchActions.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('launchAction', 'add_expense'),
      ),
      (_) {},
    );
    await settle(tester);
    expect(addSheet, findsOneWidget);
  });

  testWidgets('the sheet opens over an open page, which stays', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    expect(find.text('Appearance'), findsOneWidget);

    LaunchActions.instance.pending.value = LaunchAction.addExpense;
    await settle(tester);
    expect(addSheet, findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget, reason: 'not popped');
  });

  group('the recap notification', () {
    final now = DateTime.now();
    tearDown(() => recapClock = DateTime.now);

    Future<void> seed(FinanceProvider p) async {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 250,
        note: 'this month',
        date: DateTime(now.year, now.month, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 400,
        note: 'last month',
        date: DateTime(now.year, now.month - 1, 2),
      );
    }

    /// Leaves the Dashboard on Trends, goes to Transactions, then taps the
    /// note: the view it lands on is the one the note chose.
    Future<void> tapNotification(WidgetTester tester) async {
      await pumpHome(tester, seed: seed);
      await tester.tap(find.text('Trends'));
      await settle(tester);
      await tester.tap(find.text('Transactions').last);
      await settle(tester);
      expect(find.text('Breakdown'), findsNothing);

      LaunchActions.instance.onNotificationPayload(kRecapPayload);
      await settle(tester);
      expect(
        find.text('Breakdown'),
        findsOneWidget,
        reason: 'on the Dashboard',
      );
      expect(LaunchActions.instance.pending.value, isNull);
    }

    testWidgets('in the recap week opens the recap on the Overview', (
      tester,
    ) async {
      recapClock = () => DateTime(now.year, now.month, 3, 10);
      await tapNotification(tester);
      // Back from Trends: its comparison is gone, the recap is showing.
      expect(find.text('This month so far'), findsNothing);
      expect(find.byType(MonthlyRecapCard), findsOneWidget);
    });

    testWidgets('after it opens this month so far on Trends', (tester) async {
      recapClock = () => DateTime(now.year, now.month, 20, 10);
      // Folded by the user: the note opens it for this visit, and the
      // user's choice of how it starts stays.
      SharedPreferences.setMockInitialValues({
        'dashboard_layout_v1': '{"pages":{},"open":{"pace":false}}',
      });
      await tapNotification(tester);
      final settings = tester
          .element(find.byType(HomeScreen))
          .read<SettingsProvider>();
      expect(settings.sectionOpen(DashboardSection.pace), isFalse);
      expect(find.byType(MonthPaceCard).hitTestable(), findsOneWidget);
      // Choosing Folded afterwards (Cockpit) folds it again.
      await settings.setSectionOpen(DashboardSection.pace, true);
      await settle(tester);
      await settings.setSectionOpen(DashboardSection.pace, false);
      await settle(tester);
      expect(find.byType(MonthPaceCard).hitTestable(), findsNothing);
      // Folded to its heading.
      expect(find.text('This month so far'), findsOneWidget);
    });
  });

  group('a home-screen widget tap', () {
    final now = DateTime.now();

    Future<void> seed(FinanceProvider p) async {
      // Last month too: This month so far needs a month to compare.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 400,
        note: 'last month',
        date: DateTime(now.year, now.month - 1, 2),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 250,
        note: 'lunch today',
        // Midnight today: never in the future, whatever time it runs.
        date: DateTime(now.year, now.month, now.day),
      );
    }

    testWidgets('Spending split opens its section on Breakdown', (
      tester,
    ) async {
      // Folded by the user: the tap opens it for this visit only.
      SharedPreferences.setMockInitialValues({
        'dashboard_layout_v1': '{"pages":{},"open":{"donut":false}}',
      });
      await pumpHome(tester, seed: seed);
      await tester.tap(find.text('Transactions').last);
      await settle(tester);
      LaunchActions.instance.pending.value = LaunchAction.openBreakdown;
      await settle(tester);
      await settle(tester);
      final settings = tester
          .element(find.byType(HomeScreen))
          .read<SettingsProvider>();
      expect(settings.sectionOpen(DashboardSection.donut), isFalse);
      expect(find.byType(CategoryDonutChart).hitTestable(), findsOneWidget);
    });

    testWidgets('Month pace opens This month so far on Trends', (tester) async {
      // Past the recap week, when the pace card takes the recap's place.
      recapClock = () => DateTime(now.year, now.month, 20, 10);
      addTearDown(() => recapClock = DateTime.now);
      await pumpHome(tester, seed: seed);
      LaunchActions.instance.pending.value = LaunchAction.openPace;
      await settle(tester);
      await settle(tester);
      expect(find.byType(MonthPaceCard).hitTestable(), findsOneWidget);
    });

    testWidgets("Today and Add opens today's transactions", (tester) async {
      await pumpHome(tester, seed: seed);
      LaunchActions.instance.pending.value = LaunchAction.openToday;
      await settle(tester);
      expect(find.text('lunch today'), findsOneWidget);
    });
  });

  testWidgets('the Upcoming widget opens a folded Next 7 days for the visit', (
    tester,
  ) async {
    final now = DateTime.now();
    await pumpHome(
      tester,
      seed: (p) => p.addReminder(
        name: 'Test rent',
        dayOfMonth: now.day,
        expectedAmount: 500,
        categoryId: 'bills',
      ),
    );
    final settings = tester
        .element(find.byType(HomeScreen))
        .read<SettingsProvider>();
    // Folded by the user.
    await settings.toggleSection('upcoming');
    await settle(tester);
    final row = find.text('Test rent');
    expect(row.hitTestable(), findsNothing);

    LaunchActions.instance.pending.value = LaunchAction.openUpcoming;
    await settle(tester);
    await tester.pumpAndSettle();
    expect(row.hitTestable(), findsOneWidget, reason: 'open for the visit');
    expect(settings.isSectionCollapsed('upcoming'), isTrue);

    // A header tap ends the visit: folded again, the stored choice kept.
    await tester.tap(find.text('Next 7 days'));
    await tester.pumpAndSettle();
    expect(row.hitTestable(), findsNothing);
    expect(settings.isSectionCollapsed('upcoming'), isTrue);
  });

  testWidgets("an unusual spending alert opens the category's history on "
      'its own month', (tester) async {
    final now = DateTime.now();
    // Last month's alert, tapped this month.
    final alerted = DateTime(now.year, now.month - 1);
    await pumpHome(
      tester,
      seed: (p) => p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 250,
        note: 'lunch',
        date: DateTime(alerted.year, alerted.month, 3),
      ),
    );
    // In Year view and off the Dashboard: the alert brings back Month view
    // on the alert's month.
    // Year view is in the app bar's ⋯ menu; the title turns to the year.
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    await tester.tap(find.text('Year view').last);
    await settle(tester);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('${now.year}'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Transactions').last);
    await settle(tester);

    LaunchActions.instance.onNotificationPayload(
      unusualPayload('food', alerted),
    );
    await settle(tester);
    expect(find.text('Usual month'), findsOneWidget, reason: 'sheet open');
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Food & Dining'),
      ),
      findsOneWidget,
    );
    // The records start in the alert's month: the window is that month.
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(fmtMonth(alerted)),
      ),
      findsOneWidget,
    );
    expect(
      find.text('In ${DateFormat('MMMM').format(alerted)}'),
      findsOneWidget,
    );
    expect(find.text('Year total'), findsNothing, reason: 'Month view');
    expect(LaunchActions.instance.pending.value, isNull);
    expect(LaunchActions.instance.takeHistory(), isNull);
  });

  test('each home-screen widget names its own place', () {
    expect(LaunchActions.fromName('open_budget'), LaunchAction.openBudget);
    expect(LaunchActions.fromName('open_budgets'), LaunchAction.openBudgets);
    expect(LaunchActions.fromName('open_pace'), LaunchAction.openPace);
    expect(LaunchActions.fromName('open_upcoming'), LaunchAction.openUpcoming);
    expect(LaunchActions.fromName('open_today'), LaunchAction.openToday);
    expect(
      LaunchActions.fromName('open_breakdown'),
      LaunchAction.openBreakdown,
    );
  });

  test('bill and budget alerts map to their widget taps', () {
    for (final (payload, action) in [
      (kUpcomingPayload, LaunchAction.openUpcoming),
      (kBudgetPayload, LaunchAction.openBudget),
      (kBudgetsPayload, LaunchAction.openBudgets),
    ]) {
      LaunchActions.instance.onNotificationPayload(payload);
      expect(LaunchActions.instance.pending.value, action, reason: payload);
      // The same action the home-screen widget's launch name gives.
      expect(LaunchActions.fromName(payload), action, reason: payload);
      LaunchActions.instance.pending.value = null;
    }
    // Other launch names are not notification payloads.
    LaunchActions.instance.onNotificationPayload('add_expense');
    expect(LaunchActions.instance.pending.value, isNull);
  });

  testWidgets('a bill alert tap opens a folded Next 7 days for the visit', (
    tester,
  ) async {
    final now = DateTime.now();
    await pumpHome(
      tester,
      seed: (p) => p.addReminder(
        name: 'Test rent',
        dayOfMonth: now.day,
        expectedAmount: 500,
        categoryId: 'bills',
      ),
    );
    final settings = tester
        .element(find.byType(HomeScreen))
        .read<SettingsProvider>();
    await settings.toggleSection('upcoming');
    await settle(tester);
    // Off the Dashboard, as a tap from the shade often finds the app.
    await tester.tap(find.text('Transactions').last);
    await settle(tester);
    final row = find.text('Test rent');
    expect(row.hitTestable(), findsNothing);

    LaunchActions.instance.onNotificationPayload(kUpcomingPayload);
    await settle(tester);
    await tester.pumpAndSettle();
    expect(row.hitTestable(), findsOneWidget, reason: 'open for the visit');
    expect(settings.isSectionCollapsed('upcoming'), isTrue);
    expect(LaunchActions.instance.pending.value, isNull);
  });

  test('unknown native names and payloads are ignored', () {
    expect(LaunchActions.fromName('add_expense'), LaunchAction.addExpense);
    expect(LaunchActions.fromName('import_sms'), LaunchAction.importSms);
    expect(LaunchActions.fromName('delete_everything'), isNull);
    expect(LaunchActions.fromName(null), isNull);
    LaunchActions.instance.onNotificationPayload('budget');
    expect(LaunchActions.instance.pending.value, isNull);
  });
}
