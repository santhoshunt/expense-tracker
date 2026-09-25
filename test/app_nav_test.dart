import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';

/// Tooltip links jump through AppNav: on a Cockpit group page a tab of the
/// same group switches in place, a tab of another group pushes that group's
/// page, and from a pushed route a home jump pops back first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  Future<FinanceProvider> providers() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Widget app(FinanceProvider p, Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: MaterialApp(home: home),
  );

  /// Group pages on the stack, the covered ones included.
  Finder groupPages() => find.byType(CockpitGroupPage, skipOffstage: false);

  /// The selected tab's label on the showing page.
  String selectedTab(WidgetTester tester) {
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    return (bar.tabs[bar.controller!.index] as Tab).text!;
  }

  testWidgets('on a group page, openCockpit to a tab of the same group '
      'switches in place', (tester) async {
    final p = await providers();
    await tester.pumpWidget(
      app(p, const ClassifiersScreen(initialTab: kCockpitTabBudgets)),
    );
    await tester.pump();
    expect(selectedTab(tester), 'Budgets');

    final inside = tester.element(find.byType(TabBarView));
    AppNav.instance.openCockpit(inside, kCockpitTabReminders);
    await tester.pumpAndSettle();

    expect(groupPages(), findsOneWidget, reason: 'no stack');
    expect(selectedTab(tester), 'Reminders');
  });

  testWidgets('openCockpit from Rules to Budgets pushes the Plan page', (
    tester,
  ) async {
    final p = await providers();
    await tester.pumpWidget(
      app(p, const ClassifiersScreen(initialTab: kCockpitTabRules)),
    );
    await tester.pump();
    expect(find.text('Classify'), findsOneWidget);

    AppNav.instance.openCockpit(
      tester.element(find.byType(TabBarView)),
      kCockpitTabBudgets,
    );
    await tester.pumpAndSettle();

    expect(groupPages(), findsNWidgets(2));
    expect(find.text('Plan'), findsOneWidget);
    expect(selectedTab(tester), 'Budgets');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Classify'), findsOneWidget);
    expect(selectedTab(tester), 'Rules');
  });

  testWidgets('a real tip link to a tab of the same group stays on the page', (
    tester,
  ) async {
    final p = await providers();
    await tester.pumpWidget(
      app(p, const ClassifiersScreen(initialTab: kCockpitTabReminders)),
    );
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('About Reminders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check Payment reminders →'));
    await tester.pumpAndSettle();

    expect(groupPages(), findsOneWidget, reason: 'no stack');
    expect(selectedTab(tester), 'Budgets');
  });

  testWidgets('from a pushed route, a home jump pops back and runs the '
      'registered handler', (tester) async {
    final p = await providers();
    final owner = Object();
    TxFilterRequest? opened;
    AppNav.instance.attachHome(
      owner,
      setTab: (_) {},
      openTransactions: (r) => opened = r,
    );
    addTearDown(() => AppNav.instance.detachHome(owner));

    await tester.pumpWidget(app(p, const Scaffold(body: Text('home'))));
    final root = tester.element(find.text('home'));
    Navigator.of(root).push(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('pushed'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);

    AppNav.instance.openTransactions(
      tester.element(find.text('pushed')),
      const TxFilterRequest(type: TxType.expense),
    );
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(opened?.type, TxType.expense);
  });

  testWidgets('outside the Cockpit, openCockpit opens the group page on the '
      'tab', (tester) async {
    final p = await providers();
    await tester.pumpWidget(app(p, const Scaffold(body: Text('home'))));
    final home = tester.element(find.text('home'));

    AppNav.instance.openCockpit(home, kCockpitTabReminders);
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
    expect(selectedTab(tester), 'Reminders');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Organise now holds Categories and Tags: the tab bar opens on the
    // requested one, with its add button.
    AppNav.instance.openCockpit(home, kCockpitTabCategories);
    await tester.pumpAndSettle();
    expect(find.text('Organise'), findsOneWidget);
    expect(selectedTab(tester), 'Categories');
    expect(find.text('New category'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    AppNav.instance.openCockpit(home, kCockpitTabSubscriptions);
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
    expect(selectedTab(tester), 'Subscriptions');
    // Nothing is added by hand there, so no add button.
    expect(find.text('New reminder'), findsNothing);
    expect(find.text('New budget'), findsNothing);
  });
}
