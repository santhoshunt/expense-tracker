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

  /// Opens the row showing [rowText] in its editor and taps Delete there.
  Future<void> deleteInEditor(WidgetTester tester, String rowText) async {
    await tester.tap(find.text(rowText));
    await pumpThrough(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
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
    await deleteInEditor(tester, 'Travel');

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
    await deleteInEditor(tester, 'Food');
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
    await deleteInEditor(tester, 'Internet');

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

  testWidgets('rows carry no delete button; a new item has no Delete', (
    tester,
  ) async {
    final p = await withBudgets(['Food']);
    await pumpCockpit(tester, p, kCockpitTabBudgets);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text('New budget'));
    await pumpThrough(tester);
    expect(find.text('New budget'), findsWidgets);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('category Delete asks where rows go, then Undo puts back the '
      'category, its rows, rules, group and budgets', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addCategory(
      label: 'Pets',
      type: TxType.expense,
      icon: Icons.pets,
      color: Colors.teal,
    );
    const groupId = 'grp_wants'; // a starter group
    await p.assignCategoryToGroup(id, groupId);
    await p.addRule('petshop', id);
    await p.addBudget(
      name: 'Animals',
      limit: 2000,
      mode: BudgetMode.include,
      categoryIds: {id},
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: id,
      amount: 450,
      note: 'Food for the dog',
      date: DateTime.now().subtract(const Duration(days: 2)),
    );
    final rulesBefore = [for (final r in p.rules) r.id];

    await pumpCockpit(tester, p, kCockpitTabCategories);
    await tester.tap(find.text('Pets'));
    await pumpThrough(tester);
    await tester.tap(find.text('Delete'));
    await pumpThrough(tester);
    // The move-to dialog stays, with a red Delete.
    expect(find.text('Delete "Pets"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpThrough(tester);

    expect(
      find.text('Deleted category "Pets" · 1 transaction moved to Other'),
      findsOneWidget,
    );
    expect(customCategories.any((c) => c.id == id), isFalse);
    expect(p.transactions.single.categoryId, isNot(id));

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);

    expect(customCategories.any((c) => c.id == id), isTrue);
    expect(p.transactions.single.categoryId, id);
    expect([for (final r in p.rules) r.id], rulesBefore);
    expect(p.groupIdOf(id), groupId);
    expect(p.budgets.single.categoryIds, contains(id));
  });

  testWidgets('group Delete removes it at once, and Undo puts back its '
      'members', (tester) async {
    final p = FinanceProvider();
    await p.load();
    // A starter group, holding Shopping among others.
    const groupId = 'grp_wants';
    expect(p.groupIdOf('shopping'), groupId);
    final order = [for (final g in p.groups) g.id];

    await pumpCockpit(tester, p, kCockpitTabGroups);
    expect(find.text('Add group'), findsNothing);
    expect(find.text('New group'), findsOneWidget);
    await deleteInEditor(tester, 'Wants');

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Deleted group "Wants"'), findsOneWidget);
    expect(p.groups.where((g) => g.id == groupId), isEmpty);
    expect(p.groupIdOf('shopping'), isNull);

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);

    expect([for (final g in p.groups) g.id], order);
    expect(p.groupIdOf('shopping'), groupId);
  });

  testWidgets('rule and import rule Delete live in their editors, with '
      'Undo', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma', 'food');
    final rulesBefore = [for (final r in p.rules) r.id];

    await pumpCockpit(tester, p, kCockpitTabRules);
    await deleteInEditor(tester, 'contains "amma"');
    expect(find.text('Deleted rule "amma"'), findsOneWidget);
    expect(p.rules.any((r) => r.pattern == 'amma'), isFalse);
    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    expect([for (final r in p.rules) r.id], rulesBefore);

    final rule = p.importRules.first;
    final importBefore = [for (final r in p.importRules) r.id];
    // A fresh app: a new home on the same MaterialApp keeps the old route.
    await tester.pumpWidget(const SizedBox());
    await pumpCockpit(tester, p, kCockpitTabImport);
    await deleteInEditor(tester, 'contains "${rule.pattern}"');
    expect(find.text('Deleted rule "${rule.pattern}"'), findsOneWidget);
    expect(p.importRules.any((r) => r.id == rule.id), isFalse);
    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    expect([for (final r in p.importRules) r.id], importBefore);
  });
}
