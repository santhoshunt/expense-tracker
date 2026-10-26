import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/widgets/grouped_surface.dart';

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

  testWidgets('Cockpit hub lists the four groups with live counts, and each '
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
    // Each count keeps its noun with a non-breaking space.
    const nb = ' ';
    // v1.43.2: every space inside a fact is no-break.
    String n(int count, String one, String many) =>
        '$count$nb${(count == 1 ? one : many).replaceAll(' ', nb)}';
    final hub = <(String, String, String)>[
      (
        'Categories and rules',
        // In the order of the name. Only the rule added above: built-ins
        // are not the user's own.
        // v1.43.2: a no-break space before each dot.
        '${n(customCategories.length + kCategories.length, 'category', 'categories')}$nb· '
            '1${nb}rule$nb· '
            '${n(p.importRules.length, 'import rule', 'import rules')}',
        'Rules',
      ),
      (
        'Groups and tags',
        '${n(p.groups.length, 'group', 'groups')}$nb· 0${nb}tags',
        'New group',
      ),
      // A passed limit leads the line.
      (
        'Budgets and bills',
        '1${nb}budget over$nb· 1${nb}budget$nb· 1${nb}reminder$nb· '
            '0${nb}subscriptions',
        'Budgets',
      ),
      ('Dashboard layout', 'All${nb}sections${nb}shown', 'Overview'),
    ];
    for (final (title, count, _) in hub) {
      // The fourth row can sit below a short screen's fold.
      await tester.scrollUntilVisible(find.text(count), 200);
      expect(find.text(title), findsOneWidget);
      expect(find.text(count), findsOneWidget, reason: '$title count');
    }
    // The gists said what the counts already say.
    for (final gist in [
      'Rules, import rules, review',
      'Categories, groups and tags',
      'Budgets, reminders and subscriptions',
      'Order and show the dashboard sections',
    ]) {
      expect(find.text(gist), findsNothing, reason: gist);
    }
    // The four groups are the rows of one grouped card.
    expect(find.byType(GroupedSurface), findsNWidgets(4));
    for (final (title, _, marker) in hub) {
      await tester.ensureVisible(find.text(title));
      await pumpThrough(tester);
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

  testWidgets('Budgets and bills hosts Budgets and Reminders tabs with add '
      'flows', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(cockpit(p));
    await pumpThrough(tester);

    await tester.tap(find.text('Budgets and bills'));
    await pumpThrough(tester);
    expect(find.text('Budgets'), findsOneWidget);
    expect(find.text('Reminders'), findsOneWidget);

    await tester.tap(find.text('Budgets'));
    await pumpThrough(tester);
    // The heading and the cap field's label.
    expect(find.text('Monthly cap'), findsNWidgets(2));
    // The alert switches moved to Settings, Notifications.
    expect(find.text('Budget alerts'), findsNothing);
    expect(find.text('Notification settings'), findsOneWidget);
    final list = find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('No custom budgets yet.'),
      300,
      scrollable: list,
    );
    expect(find.text('No custom budgets yet.'), findsOneWidget);
    // Back up: scrolling down hides the FAB.
    await tester.drag(list, const Offset(0, 600));
    await pumpThrough(tester);
    // The FAB is the only add flow; the inline button duplicated it.
    expect(find.text('Add budget'), findsNothing);
    expect(find.text('New budget'), findsOneWidget, reason: 'FAB follows tab');

    await tester.tap(find.text('Reminders'));
    await pumpThrough(tester);
    expect(find.text('No reminders yet.'), findsOneWidget);
    expect(find.text('Add reminder'), findsNothing);
    expect(find.text('New reminder'), findsOneWidget);
  });

  testWidgets('Settings lost the moved sections; a Cockpit card leads it', (
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
        // Settings on its own: how the app bar reaches it is the home
        // screen's test, and this one reads only what Settings holds.
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpThrough(tester);

    // Every group page, since the root list builds no sections itself.
    for (final group in [
      'Appearance',
      'SMS import',
      'Notifications',
      'Card rewards',
      'Backup and data',
      'Privacy',
      'About',
    ]) {
      // The last rows sit below a short test screen.
      await tester.ensureVisible(find.text(group));
      await pumpThrough(tester);
      await tester.tap(find.text(group));
      await pumpThrough(tester);
      expect(find.text('Monthly cap', skipOffstage: false), findsNothing);
      expect(find.text('Custom budgets', skipOffstage: false), findsNothing);
      expect(find.text('Add reminder', skipOffstage: false), findsNothing);
      await tester.pageBack();
      await pumpThrough(tester);
    }
    // Category order moved beside the categories.
    expect(find.text('Category order'), findsNothing);
    // The Cockpit card on top opens the hub.
    await tester.ensureVisible(find.text('Cockpit'));
    await pumpThrough(tester);
    await tester.tap(find.text('Cockpit'));
    await pumpThrough(tester);
    expect(find.widgetWithText(AppBar, 'Cockpit'), findsOneWidget);
    expect(find.text('Categories and rules'), findsOneWidget);
  });
}
