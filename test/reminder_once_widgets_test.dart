import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/reminder_schedule.dart';
import 'package:expense_tracker/utils/dates.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/reminder_editor_dialog.dart';

/// One-time reminders in the editor (the Once choice and its date) and in
/// the Cockpit Reminders list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  String dayKey(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

  DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// A button that opens the editor through [open].
  Future<void> pumpEditor(
    WidgetTester tester,
    FinanceProvider p,
    Future<void> Function(BuildContext) open, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.widgetWithText(FilledButton, label);

  testWidgets('a prefilled date opens on Once and saves it as yearly', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final on = dateOnly(
      DateTime.now().add(const Duration(days: 10, milliseconds: 200)),
    );
    await pumpEditor(
      tester,
      p,
      (context) => showReminderEditor(context, onDate: on),
    );

    expect(find.text(fmtDate(on)), findsOneWidget);
    expect(find.text('Due day'), findsNothing, reason: 'date replaces day');
    // One button for a screen reader, label and value together.
    final field = find.bySemanticsLabel('Date, ${fmtDate(on)}');
    expect(field, findsOneWidget);
    expect(
      tester.getSemantics(field),
      isSemantics(
        label: 'Date, ${fmtDate(on)}',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'Passport fee');
    await tester.pump();
    await tester.tap(button('Create'));
    await tester.pumpAndSettle();

    final r = p.reminders.single;
    expect(r.onDate, dayKey(on));
    expect(r.isOnce, isTrue);
    expect(r.cycle, SubscriptionCycle.yearly);
    expect(r.anchorMonth, on.month);
    expect(r.dayOfMonth, on.day);
  });

  testWidgets('Once with no date waits for one from the picker', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpEditor(tester, p, (context) => showReminderEditor(context));

    // A new reminder still starts on Monthly.
    expect(find.text('Due day'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Gift');
    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a date'), findsOneWidget);
    expect(find.text('Due day'), findsNothing);
    expect(tester.widget<FilledButton>(button('Create')).onPressed, isNull);

    await tester.tap(find.text('Pick a date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a date'), findsNothing);
    await tester.tap(button('Create'));
    await tester.pumpAndSettle();

    final r = p.reminders.single;
    final picked = DateTime.parse(r.onDate!);
    expect(r.cycle, SubscriptionCycle.yearly);
    expect(r.dayOfMonth, picked.day);
    expect(r.anchorMonth, picked.month);
  });

  testWidgets('switching a once reminder to Monthly clears its date and '
      'keeps its day', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final on = dateOnly(
      DateTime.now().add(const Duration(days: 20, milliseconds: 200)),
    );
    await p.addReminder(
      name: 'Passport fee',
      dayOfMonth: on.day,
      categoryId: 'other_expense',
      cycle: SubscriptionCycle.yearly,
      anchorMonth: on.month,
    );
    await p.updateReminder(p.reminders.single.copyWith(onDate: dayKey(on)));
    await pumpEditor(
      tester,
      p,
      (context) => showReminderEditor(context, existing: p.reminders.single),
    );

    expect(find.text(fmtDate(on)), findsOneWidget, reason: 'opens on Once');
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(find.text('Due day'), findsOneWidget);
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();

    final r = p.reminders.single;
    expect(r.onDate, isNull);
    expect(r.cycle, SubscriptionCycle.monthly);
    expect(r.dayOfMonth, on.day);
  });

  testWidgets('the editor fits 320dp at 2x text, on Once and on Monthly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    final on = dateOnly(
      DateTime.now().add(const Duration(days: 3, milliseconds: 200)),
    );
    await pumpEditor(
      tester,
      p,
      (context) => showReminderEditor(context, onDate: on),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Quarterly'), findsOneWidget);
    // One text size for all four choices: none is shrunk to fit.
    final heights = {
      for (final label in ['Once', 'Monthly', 'Quarterly', 'Yearly'])
        tester.getSize(find.text(label)).height,
    };
    expect(heights, hasLength(1));
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cockpit lists a finished once reminder as done, deletable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    // Past its date by more than the grace week.
    final on = dateOnly(
      DateTime.now().subtract(const Duration(days: 20, milliseconds: 200)),
    );
    await p.addReminder(
      name: 'Passport fee',
      dayOfMonth: on.day,
      categoryId: 'other_expense',
      cycle: SubscriptionCycle.yearly,
      anchorMonth: on.month,
    );
    await p.updateReminder(p.reminders.single.copyWith(onDate: dayKey(on)));
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

    expect(find.textContaining('Once, ${on.day} '), findsOneWidget);
    expect(find.textContaining(' · done'), findsOneWidget);
    expect(find.textContaining(' · paid'), findsNothing);
    await tester.tap(find.byTooltip('Delete reminder'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(p.reminders, isEmpty);
  });

  testWidgets('a reminder paid this month switched to Once is not done', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now().add(const Duration(milliseconds: 200));
    final id = await p.addReminder(
      name: 'Rent',
      dayOfMonth: 1,
      categoryId: 'other_expense',
    );
    await p.markReminderPaid(id, DateTime(now.year, now.month, 1));
    expect(p.reminders.single.lastPaidMonth, monthKey(now));
    await pumpEditor(
      tester,
      p,
      (context) => showReminderEditor(context, existing: p.reminders.single),
    );

    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick a date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();

    final r = p.reminders.single;
    expect(r.isOnce, isTrue);
    expect(r.lastPaidMonth, isNull, reason: 'the old mark is not for it');
    expect(reminderFinished(r, now), isFalse);
  });

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

  testWidgets('Mark unpaid steps a paid reminder back a month; Undo '
      'restores it', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now().add(const Duration(milliseconds: 200));
    final id = await p.addReminder(
      name: 'Rent',
      dayOfMonth: 1,
      categoryId: 'other_expense',
    );
    // Unpaid: no button.
    await pumpReminders(tester, p);
    expect(find.text('Mark unpaid'), findsNothing);

    await p.markReminderPaid(id, DateTime(now.year, now.month, 1));
    await tester.pump();
    expect(find.textContaining(' · paid'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Mark unpaid'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      p.reminders.single.lastPaidMonth,
      monthKey(DateTime(now.year, now.month - 1)),
    );
    expect(find.text('Mark unpaid'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(p.reminders.single.lastPaidMonth, monthKey(now));
  });

  testWidgets('Mark unpaid takes a paid once reminder back from done', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final on = dateOnly(
      DateTime.now().add(const Duration(days: 5, milliseconds: 200)),
    );
    final id = await p.addReminder(
      name: 'Passport fee',
      dayOfMonth: on.day,
      categoryId: 'other_expense',
      cycle: SubscriptionCycle.yearly,
      anchorMonth: on.month,
      onDate: dayKey(on),
    );
    await p.markReminderPaid(id, on);
    await pumpReminders(tester, p);
    expect(find.textContaining(' · done'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Mark unpaid'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(p.reminders.single.lastPaidMonth, isNull);
    expect(find.textContaining(' · done'), findsNothing);
  });
}
