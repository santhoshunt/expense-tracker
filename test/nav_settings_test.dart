import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/home_app_bar.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/unusual_spend_monitor.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

/// v1.42.0: Settings is a button beside the ⋮ on every tab, a shortcut into
/// the Cockpit goes Back to the hub, and turning Unusual spending on checks
/// at once. Amounts are made up.
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

  tearDown(() {
    appLocked.value = true;
    NotificationService.statusOverride = null;
  });

  /// Bounded pumps: the Settings screen's Drive section keeps a spinner up
  /// under tests, so pumpAndSettle would time out.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpHome(
    WidgetTester tester,
    FinanceProvider finance,
    SettingsProvider settings,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
  }

  Future<(FinanceProvider, SettingsProvider)> loaded() async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    return (finance, settings);
  }

  group('the Settings button', () {
    testWidgets('every tab shows it beside the ⋮, and it opens Settings', (
      tester,
    ) async {
      final (finance, settings) = await loaded();
      await pumpHome(tester, finance, settings);
      for (final tab in ['Dashboard', 'Transactions', 'Accounts']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(tab),
          ),
        );
        await settle(tester);
        final button = find.byTooltip('Settings');
        expect(button, findsOneWidget, reason: tab);
        // Just before the ⋮.
        expect(
          tester.getCenter(button).dx,
          lessThan(tester.getCenter(find.byTooltip('More')).dx),
          reason: tab,
        );
        await tester.tap(button);
        await settle(tester);
        expect(find.byType(SettingsScreen), findsOneWidget, reason: tab);
        await tester.pageBack();
        await settle(tester);
        expect(find.byType(SettingsScreen), findsNothing, reason: tab);
      }
    });

    testWidgets('the ⋮ lists Cockpit and People, not Settings', (tester) async {
      final (finance, settings) = await loaded();
      await pumpHome(tester, finance, settings);
      await tester.tap(find.byTooltip('More'));
      await settle(tester);
      Finder row(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
      );
      expect(row('Cockpit'), findsOneWidget);
      expect(row('People'), findsOneWidget);
      expect(row('Settings'), findsNothing);
      await tester.tap(row('Cockpit'));
      await settle(tester);
      expect(find.widgetWithText(AppBar, 'Cockpit'), findsOneWidget);
    });

    group('fits at 320dp with 2x text', () {
      final owner = Object();
      tearDown(() => AppNav.instance.dashboardHeader.detach(owner));

      /// Home's app bar pieces in a bar on a 320dp screen at 2x text.
      Future<void> pumpBar(
        WidgetTester tester, {
        required Widget title,
        double? titleSpacing,
        required List<Widget> actions,
      }) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(
                title: title,
                titleSpacing: titleSpacing,
                actions: actions,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      void expectOnScreen(WidgetTester tester, String tooltip) {
        final r = tester.getRect(
          find
              .ancestor(
                of: find.byTooltip(tooltip),
                matching: find.byType(IconButton),
              )
              .first,
        );
        expect(r.left, greaterThanOrEqualTo(0), reason: tooltip);
        expect(r.right, lessThanOrEqualTo(320), reason: tooltip);
      }

      testWidgets('the Dashboard month title', (tester) async {
        AppNav.instance.dashboardHeader.update(
          owner: owner,
          label: 'September 2026',
          yearMode: false,
          onPrev: () {},
          onNext: () {},
          onPick: () {},
        );
        // As home_screen.dart builds the bar on the Dashboard.
        await pumpBar(
          tester,
          title: const DashboardMonthTitle(),
          titleSpacing: 4,
          actions: const [
            SettingsButton(),
            HomeMenu(tab: kHomeTabDashboard),
          ],
        );
        expect(tester.takeException(), isNull);
        for (final t in ['Previous month', 'Next month', 'Settings', 'More']) {
          expectOnScreen(tester, t);
        }
        final label = tester.getRect(find.text('September 2026'));
        final settingsLeft = tester
            .getRect(
              find
                  .ancestor(
                    of: find.byTooltip('Settings'),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .left;
        expect(label.width, greaterThan(0));
        expect(label.right, lessThanOrEqualTo(settingsLeft));
      });

      testWidgets('the Transactions title with the SMS button', (tester) async {
        // As home_screen.dart builds the bar on Transactions.
        await pumpBar(
          tester,
          title: const Text('Transactions'),
          actions: [
            IconButton(
              tooltip: 'Import from SMS',
              icon: const Icon(Icons.sms_outlined),
              onPressed: () {},
            ),
            const SettingsButton(),
            const HomeMenu(tab: kHomeTabTransactions),
          ],
        );
        expect(tester.takeException(), isNull);
        for (final t in ['Import from SMS', 'Settings', 'More']) {
          expectOnScreen(tester, t);
        }
      });
    });
  });

  group('a Cockpit shortcut from outside the Cockpit', () {
    testWidgets('Back from the page lands on the hub, then where it began', (
      tester,
    ) async {
      final (finance, settings) = await loaded();
      NotificationService.statusOverride = () async =>
          NotificationStatus.enabled;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: finance),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => goCockpitRules(context),
                  child: const Text('start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();

      // The Classify page on Rules.
      expect(find.widgetWithText(AppBar, 'Classify'), findsOneWidget);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect((bar.tabs[bar.controller!.index] as Tab).text, 'Rules');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Cockpit'), findsOneWidget);
      expect(find.byType(CockpitGroupPage), findsNothing);
      // The hub's group rows.
      for (final g in CockpitGroup.values) {
        expect(find.text(g.title), findsOneWidget, reason: g.title);
      }

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('start'), findsOneWidget);
      expect(find.byType(ClassifiersScreen), findsNothing);
    });

    testWidgets('only the group page animates in', (tester) async {
      final (finance, settings) = await loaded();
      NotificationService.statusOverride = () async =>
          NotificationStatus.enabled;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: finance),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => goCockpitRules(context),
                  child: const Text('start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pump();
      await tester.pump();
      // One frame in: the hub is already fully in, the group page is still
      // on its way.
      ModalRoute<dynamic> routeOf(Finder f) =>
          ModalRoute.of(tester.element(f))!;
      final hub = routeOf(
        find.byWidgetPredicate(
          (w) => w is ClassifiersScreen && w.initialTab == null,
          skipOffstage: false,
        ),
      );
      final page = routeOf(find.byType(CockpitGroupPage, skipOffstage: false));
      expect(hub.animation!.value, 1.0, reason: 'the hub');
      expect(page.animation!.value, lessThan(1.0), reason: 'the page');
      await tester.pumpAndSettle();
    });
  });

  group('the Unusual spending switch', () {
    testWidgets('turning it on checks at once', (tester) async {
      final now = DateTime.now();
      final month = DateTime(now.year, now.month);
      final (finance, settings) = await loaded();
      Future<void> food(double amount, DateTime date) => finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: amount,
        note: 'groceries',
        date: date,
      );
      // A usual month of 1,000, then 4,000 this month: past both lines.
      for (var k = 1; k <= 3; k++) {
        await food(1000, DateTime(now.year, now.month - k, 1));
      }
      await food(4000, month);
      await settings.setUnusualAlerts(false);
      NotificationService.statusOverride = () async =>
          NotificationStatus.enabled;
      // Off Android, show() returns without the plugin, so the monitor
      // records its marker.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpHome(tester, finance, settings);
        final key = UnusualSpendMonitor.firedKey('food', month);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(key), isNull, reason: 'the switch is off');

        // No ledger change and no resume: only the switch.
        await settings.setUnusualAlerts(true);
        await settle(tester);
        expect(prefs.getBool(key), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
