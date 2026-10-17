import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/home_app_bar.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/people_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/widgets/glossy.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

/// v1.38.1: the ⋮ menu has the same two sections on every tab, "This page"
/// (what the tab publishes) and then "App" (Cockpit, Who owes you; Settings
/// moved to its own bar button in v1.42.0);
/// import toasts give the counted and waiting figures. Names and amounts
/// are made up.
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<FinanceProvider> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
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
    return finance;
  }

  /// [HomeMenu] alone in an app bar, for [tab].
  Future<void> pumpMenu(WidgetTester tester, int tab) async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [HomeMenu(tab: tab)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
  }

  /// The menu row showing [label].
  Finder tile(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
  );

  group('the ⋮ menu', () {
    testWidgets('Dashboard: This page, then App', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);
      for (final label in [
        'Year view',
        'Month report (PDF)',
        'Customise page',
        'Cockpit',
        'Who owes you',
      ]) {
        expect(tile(label), findsOneWidget, reason: label);
      }
      // v1.42.0: Settings is the bar's own button now.
      expect(tile('Settings'), findsNothing);
      // The tip is the row's "i" now, not a row of its own.
      expect(find.text('About Year view'), findsNothing);
      expect(find.byTooltip('About Year view'), findsOneWidget);
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(top(find.text('This page')), lessThan(top(tile('Year view'))));
      expect(top(tile('Customise page')), lessThan(top(find.text('App'))));
      expect(top(find.text('App')), lessThan(top(tile('Cockpit'))));
      expect(find.byType(PopupMenuDivider), findsOneWidget);
    });

    testWidgets('the Year view row toggles the view', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);
      await tester.tap(tile('Year view'));
      await settle(tester);
      await openMenu(tester);
      expect(tile('Month view'), findsOneWidget);
      expect(tile('Year report (PDF)'), findsOneWidget);
      expect(tile('Year view'), findsNothing);
    });

    testWidgets('the "i" opens the Year view tip and leaves the view', (
      tester,
    ) async {
      await pumpHome(tester);
      await openMenu(tester);
      await tester.tap(find.byTooltip('About Year view'));
      await settle(tester);
      expect(find.textContaining('adds up the 12 months'), findsOneWidget);
      // The tip, then the menu, close on a tap outside.
      await tester.tapAt(const Offset(5, 880));
      await settle(tester);
      expect(find.textContaining('adds up the 12 months'), findsNothing);
      if (tile('Year view').evaluate().isNotEmpty) {
        await tester.tapAt(const Offset(5, 880));
        await settle(tester);
      }
      await openMenu(tester);
      expect(tile('Year view'), findsOneWidget, reason: 'still Month view');
      expect(tile('Month view'), findsNothing);
    });

    testWidgets('a screen reader reaches the tip as the row\'s action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpHome(tester);
      await openMenu(tester);
      // The menu merges each row into one node, the "i" included.
      const action = CustomSemanticsAction(label: 'About Year view');
      final row = tester.getSemantics(find.text('Year view'));
      expect(row, isSemantics(customActions: [action]));
      row.owner!.performAction(
        row.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(action),
      );
      await settle(tester);
      expect(find.textContaining('adds up the 12 months'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Transactions: the published entries lead and run', (
      tester,
    ) async {
      final owner = Object();
      addTearDown(() => AppNav.instance.pageMenu.detach(owner));
      var selected = 0;
      AppNav.instance.pageMenu.publish(owner, kHomeTabTransactions, [
        PageMenuAction(
          icon: Icons.checklist,
          label: 'Select',
          onTap: () => selected++,
        ),
        PageMenuAction(
          icon: Icons.table_view_outlined,
          label: 'Export CSV',
          onTap: () {},
        ),
      ]);
      await pumpMenu(tester, kHomeTabTransactions);
      await openMenu(tester);
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(find.text('This page'), findsOneWidget);
      expect(top(tile('Select')), lessThan(top(tile('Export CSV'))));
      expect(top(tile('Export CSV')), lessThan(top(find.text('App'))));
      expect(tile('Cockpit'), findsOneWidget);
      // Another tab's entries stay out.
      expect(tile('Year view'), findsNothing);
      await tester.tap(tile('Select'));
      await settle(tester);
      expect(selected, 1);
      expect(find.text('App'), findsNothing, reason: 'the menu closed');
    });

    testWidgets('a tab with nothing published shows App alone', (tester) async {
      await pumpMenu(tester, kHomeTabAccounts);
      await openMenu(tester);
      expect(find.text('This page'), findsNothing);
      expect(find.byType(PopupMenuDivider), findsNothing);
      expect(find.text('App'), findsOneWidget);
      expect(tile('Who owes you'), findsOneWidget);
    });

    testWidgets('Who owes you opens the People page', (tester) async {
      await pumpMenu(tester, kHomeTabDashboard);
      await openMenu(tester);
      await tester.tap(tile('Who owes you'));
      await settle(tester);
      expect(find.byType(PeopleScreen), findsOneWidget);
    });

    testWidgets('Accounts: New account, Balance breakdown, Statement', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.tap(find.text('Accounts').last);
      await settle(tester);
      await openMenu(tester);
      expect(find.text('This page'), findsOneWidget);
      for (final label in [
        'New account',
        'Balance breakdown',
        'Statement (PDF)',
      ]) {
        expect(tile(label), findsOneWidget, reason: label);
      }
      expect(tile('Year view'), findsNothing);
      await tester.tap(tile('Balance breakdown'));
      await settle(tester);
      // The menu closed and the sheet, titled the same, opened.
      expect(tile('Balance breakdown'), findsNothing);
      expect(find.text('Balance breakdown'), findsOneWidget);
      // Statement (PDF) asks which dates, through the shared flow.
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      await openMenu(tester);
      await tester.tap(tile('Statement (PDF)'));
      await settle(tester);
      expect(find.text('Export which dates?'), findsOneWidget);
      expect(find.text('All transactions'), findsOneWidget);
    });
  });

  testWidgets('Accounts shows the Savings chip only with a savings account', (
    tester,
  ) async {
    Finder chip(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is ChipTabs),
      matching: find.text(label),
    );
    final finance = await pumpHome(tester);
    await tester.tap(find.text('Accounts').last);
    await settle(tester);
    expect(chip('Wallets'), findsOneWidget);
    expect(chip('Savings'), findsNothing);
    await finance.addAccount(name: 'Test FD', type: AccountType.savings);
    await settle(tester);
    expect(chip('Savings'), findsOneWidget);
    await tester.tap(chip('Savings'));
    await settle(tester);
    expect(find.text('Test FD'), findsOneWidget);
    // The Wallets chip still opens the Wallets page.
    await tester.tap(chip('Wallets'));
    await settle(tester);
    expect(find.text('No wallets yet.'), findsOneWidget);
  });

  group('import toasts', () {
    test('counted and waiting', () {
      expect(importCountsText(10, 8), '8 added, 2 to review');
      expect(importCountsText(3, 1), '1 added, 2 to review');
    });

    test('none waiting', () {
      expect(importCountsText(8, 8), '8 added');
      expect(importCountsText(1, 1), '1 added');
    });

    test('none counted', () {
      expect(importCountsText(2, 0), '2 to review');
      expect(importCountsText(1, 0), '1 to review');
    });
  });
}
