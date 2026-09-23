import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/services/budget.dart';
import 'package:expense_tracker/services/notification_service.dart';

/// Cockpit deletes act at once and offer Undo (no confirm dialog), and the
/// undo puts the item back where it was: same id, same list position, and
/// for a budget the same fired-alert marker.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  /// Opens the Cockpit on [tab] on a tall surface, so every row of the tab
  /// is on screen without scrolling.
  Future<void> pumpCockpit(
    WidgetTester tester,
    FinanceProvider p,
    int tab,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(home: ClassifiersScreen(initialTab: tab)),
      ),
    );
    await pumpThrough(tester);
  }

  /// Seeds stored budgets with fixed ids: addBudget's ids come from the
  /// clock alone, so back-to-back adds could collide.
  Future<FinanceProvider> withBudgets(
    List<String> ids, {
    Map<String, Object> extraPrefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'spend_budgets_v1': jsonEncode([
        for (final id in ids)
          SpendBudget(
            id: id,
            name: id,
            limit: 5000,
            mode: BudgetMode.include,
            categoryIds: const {'food'},
          ).toJson(),
      ]),
      ...extraPrefs,
    });
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  testWidgets('budget delete offers Undo, which restores position and marker', (
    tester,
  ) async {
    final ids = ['Food', 'Travel', 'Fun'];
    // The 90% alert already fired this month for the middle budget.
    final alertKey = customBudgetAlertKey(ids[1], DateTime.now());
    final p = await withBudgets(ids, extraPrefs: {alertKey: 90});
    expect([for (final b in p.budgets) b.id], ids);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(alertKey), 90);

    await pumpCockpit(tester, p, kCockpitTabBudgets);
    await tester.tap(find.byTooltip('Delete budget').at(1));
    await pumpThrough(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Deleted budget "Travel"'), findsOneWidget);
    expect([for (final b in p.budgets) b.id], [ids[0], ids[2]]);
    expect(prefs.getInt(alertKey), isNull);

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    await pumpThrough(tester);

    expect([for (final b in p.budgets) b.id], ids);
    expect(p.budgets[1].name, 'Travel');
    expect(
      prefs.getInt(alertKey),
      90,
      reason: 'the 80% and 90% alerts must not fire again this month',
    );
  });

  testWidgets('budget with no fired alert restores without writing a marker', (
    tester,
  ) async {
    final p = await withBudgets(['Food']);
    final id = p.budgets.single.id;

    await pumpCockpit(tester, p, kCockpitTabBudgets);
    await tester.tap(find.byTooltip('Delete budget'));
    await pumpThrough(tester);
    expect(p.budgets, isEmpty);
    expect(find.text('No custom budgets yet.'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    await pumpThrough(tester);

    expect(p.budgets.single.id, id);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(customBudgetAlertKey(id, DateTime.now())), isNull);
  });

  testWidgets('reminder delete offers Undo, which restores its position', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    for (final (i, name) in ['Rent', 'Internet', 'Gym'].indexed) {
      await p.addReminder(
        name: name,
        dayOfMonth: 5 + i,
        categoryId: 'other_expense',
      );
    }
    final ids = [for (final r in p.reminders) r.id];

    await pumpCockpit(tester, p, kCockpitTabReminders);
    await tester.tap(find.byTooltip('Delete reminder').at(1));
    await pumpThrough(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Deleted reminder "Internet"'), findsOneWidget);
    expect([for (final r in p.reminders) r.id], [ids[0], ids[2]]);

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);

    expect(
      [for (final r in p.reminders) r.id],
      ids,
      reason: 'back in the middle, not appended',
    );
  });
}
