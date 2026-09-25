import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/notification_service.dart';

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

  Widget cockpit(FinanceProvider p) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: const MaterialApp(home: ClassifiersScreen()),
  );

  testWidgets('Cockpit hub lists the three groups with live counts, and each '
      'opens its page', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('amma', 'food');
    final now = DateTime.now();
    await p.addBudget(
      name: 'Eating out',
      limit: 100,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'Dinner',
      date: DateTime(now.year, now.month, 1, 0, 0, 1),
    );
    await p.addReminder(
      name: 'Rent',
      dayOfMonth: 5,
      categoryId: 'other_expense',
    );
    await tester.pumpWidget(cockpit(p));
    await pumpThrough(tester);

    expect(find.text('Cockpit'), findsOneWidget);
    String n(int count, String one, String many) =>
        '$count ${count == 1 ? one : many}';
    final hub = <(String, String, String, String)>[
      (
        'Classify',
        'Rules, import filters, review',
        // Only the rule added above: built-ins are not the user's own.
        '1 rule · '
            '${n(p.importRules.length, 'import filter', 'import filters')}',
        'Rules',
      ),
      (
        'Organise',
        'Categories, groups and tags',
        '${customCategories.length + kCategories.length} categories · '
            '0 tags',
        'New category',
      ),
      (
        'Plan',
        'Budgets, reminders and subscriptions',
        '1 budget · 1 reminder · 0 subscriptions · 1 over',
        'Budgets',
      ),
    ];
    for (final (title, gist, count, _) in hub) {
      expect(find.text(title), findsOneWidget);
      expect(find.text(gist), findsOneWidget);
      expect(find.text(count), findsOneWidget, reason: '$title count');
    }
    for (final (title, _, _, marker) in hub) {
      await tester.tap(find.text(title));
      await pumpThrough(tester);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text(title)),
        findsOneWidget,
      );
      expect(find.text(marker), findsOneWidget, reason: '$title page');
      await tester.pageBack();
      await pumpThrough(tester);
    }
    expect(find.text('Cockpit'), findsOneWidget);
  });

  testWidgets('Plan hosts Budgets and Reminders tabs with add flows', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(cockpit(p));
    await pumpThrough(tester);

    await tester.tap(find.text('Plan'));
    await pumpThrough(tester);
    expect(find.text('Budgets'), findsOneWidget);
    expect(find.text('Reminders'), findsOneWidget);

    await tester.tap(find.text('Budgets'));
    await pumpThrough(tester);
    expect(find.text('Monthly cap'), findsOneWidget);
    expect(find.text('No custom budgets yet.'), findsOneWidget);
    // The FAB is the only add flow; the inline button duplicated it.
    expect(find.text('Add budget'), findsNothing);
    expect(find.text('New budget'), findsOneWidget, reason: 'FAB follows tab');

    await tester.tap(find.text('Reminders'));
    await pumpThrough(tester);
    expect(find.text('No reminders yet.'), findsOneWidget);
    expect(find.text('Add reminder'), findsNothing);
    expect(find.text('New reminder'), findsOneWidget);
  });

  testWidgets('Settings lost the moved sections and points at Cockpit', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);

    // Every group page, since the root list builds no sections itself.
    for (final group in [
      'Appearance',
      'SMS import',
      'Backup and data',
      'Privacy',
      'Categories and rules',
      'About',
    ]) {
      await tester.tap(find.text(group));
      await pumpThrough(tester);
      expect(find.text('Monthly cap', skipOffstage: false), findsNothing);
      expect(find.text('Custom budgets', skipOffstage: false), findsNothing);
      expect(find.text('Add reminder', skipOffstage: false), findsNothing);
      await tester.pageBack();
      await pumpThrough(tester);
    }
    // The pointer row lives on the Categories and rules page.
    await tester.tap(find.text('Categories and rules'));
    await pumpThrough(tester);
    await tester.scrollUntilVisible(
      find.text('Rules, import filters, categories, budgets and reminders'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('Open Cockpit'), findsOneWidget);
    expect(
      find.text('Rules, import filters, categories, budgets and reminders'),
      findsOneWidget,
    );
  });
}
