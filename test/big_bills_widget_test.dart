import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/reminder_editor_dialog.dart';

import 'dashboard_test_utils.dart';

/// Big bills ahead on screen: the Ahead card, its sheet, the Cockpit
/// Reminders note, and the editor's Half-yearly choice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  var seq = 0;

  Reminder reminder(
    String name, {
    SubscriptionCycle cycle = SubscriptionCycle.yearly,
    int anchor = 1,
    double? amount,
  }) => Reminder(
    id: 'r${seq++}',
    name: name,
    dayOfMonth: 5,
    categoryId: 'other_expense',
    expectedAmount: amount,
    cycle: cycle,
    anchorMonth: anchor,
  );

  Future<FinanceProvider> withReminders(List<Reminder> rs) async {
    final p = FinanceProvider();
    await p.load();
    for (final r in rs) {
      await p.restoreReminder(r);
    }
    return p;
  }

  /// One bill a month each: ₹1,000 set aside per bill.
  List<Reminder> threeBills() => [
    reminder('Insurance', anchor: 3, amount: 12000),
    reminder('School fees', cycle: SubscriptionCycle.halfYearly, amount: 6000),
    reminder(
      'Maintenance',
      cycle: SubscriptionCycle.quarterly,
      anchor: 2,
      amount: 3000,
    ),
  ];

  Future<void> pumpDashboard(
    WidgetTester tester,
    FinanceProvider p, {
    Size size = const Size(1080, 2400),
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
          home: const Scaffold(body: DashboardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(BottomSheet), matching: f);

  group('Ahead card', () {
    testWidgets('shows the monthly figure and the next two bills, and opens '
        'a sheet listing every bill', (tester) async {
      final p = await withReminders(threeBills());
      await pumpDashboard(tester, p);
      await openDashboardView(tester, 'Ahead');

      expect(find.text('Big bills ahead'), findsOneWidget);
      // Folded at first on Ahead: open it to reach the card.
      await openDashboardSection(tester, 'bigBills');
      expect(find.text(fmtMoneyTidy(3000)), findsWidgets);
      expect(find.text('a month to set aside'), findsOneWidget);
      expect(find.text('+1 more'), findsOneWidget);

      final card = find.text('a month to set aside');
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      for (final name in ['Insurance', 'School fees', 'Maintenance']) {
        expect(inSheet(find.text(name)), findsOneWidget, reason: name);
      }
      expect(
        inSheet(find.text('${fmtMoneyTidy(1000)} a month')),
        findsNWidgets(3),
      );
      expect(
        inSheet(find.text('${fmtMoneyTidy(36000)} a year')),
        findsOneWidget,
      );
      expect(
        inSheet(find.text('Half-yearly, day 5 of Jan and Jul')),
        findsOneWidget,
      );

      // A reminder row closes the sheet and opens its editor.
      await tester.tap(inSheet(find.text('Insurance')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Edit reminder'), findsOneWidget);
    });

    testWidgets('card and sheet fit 320dp at 1.3x text', (tester) async {
      final p = await withReminders([
        ...threeBills(),
        reminder(
          'Annual property tax for the flat in the city',
          anchor: 6,
          amount: 1234567,
        ),
      ]);
      // One row, so the first-run Get started card steps aside.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 90,
        note: 'Tea',
        date: DateTime(2025, 1, 10),
      );
      await pumpDashboard(
        tester,
        p,
        size: const Size(320, 1400),
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      await openDashboardView(tester, 'Ahead');
      await openDashboardSection(tester, 'bigBills');
      expect(tester.takeException(), isNull);
      final card = find.text('a month to set aside');
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Every bill row is a 48dp tap target at least.
      for (final row in tester.widgetList<InkWell>(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(InkWell),
        ),
      )) {
        if (row.onTap == null) continue;
        expect(
          tester.getSize(find.byWidget(row)).height,
          greaterThanOrEqualTo(48),
        );
      }
    });

    testWidgets('hides with no quarterly, half-yearly or yearly bill', (
      tester,
    ) async {
      final p = await withReminders([
        reminder('Rent', cycle: SubscriptionCycle.monthly, amount: 20000),
        reminder('Water', cycle: SubscriptionCycle.quarterly),
      ]);
      await pumpDashboard(tester, p);
      expect(find.text('Big bills ahead'), findsNothing);
      expect(find.text('a month to set aside'), findsNothing);
    });
  });

  group('Cockpit Reminders', () {
    Future<void> pumpReminders(WidgetTester tester, FinanceProvider p) async {
      tester.view.physicalSize = const Size(1080, 2400);
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
          child: const MaterialApp(
            home: ClassifiersScreen(initialTab: kCockpitTabReminders),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    final note = find.textContaining('also show in Big bills ahead');

    testWidgets('notes Big bills ahead when a big bill reminder exists', (
      tester,
    ) async {
      await pumpReminders(tester, await withReminders(threeBills()));
      expect(note, findsOneWidget);
    });

    testWidgets('no note for monthly or amount-less reminders only', (
      tester,
    ) async {
      await pumpReminders(
        tester,
        await withReminders([
          reminder('Rent', cycle: SubscriptionCycle.monthly, amount: 20000),
          reminder('Water', cycle: SubscriptionCycle.quarterly),
        ]),
      );
      expect(note, findsNothing);
    });
  });

  testWidgets('the Half-yearly chip saves a half-yearly cycle with the '
      'picked months', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReminderEditor(context, anchorMonth: 1),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'School fees');
    await tester.tap(find.text('Half-yearly'));
    await tester.pumpAndSettle();
    expect(find.text('Due months'), findsOneWidget);
    await tester.tap(find.text('Jan and Jul'));
    await tester.pumpAndSettle();
    // Six pairs, from Jan and Jul to Jun and Dec.
    expect(find.text('Jun and Dec'), findsOneWidget);
    await tester.tap(find.text('Mar and Sep'));
    await tester.pumpAndSettle();
    expect(find.text('Mar and Sep'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final r = p.reminders.single;
    expect(r.cycle, SubscriptionCycle.halfYearly);
    expect(r.anchorMonth, 3);
    expect(r.isOnce, isFalse);
  });
}
