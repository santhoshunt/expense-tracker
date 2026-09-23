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

/// Tooltip links jump through AppNav: inside the Cockpit a tab switch
/// happens in place, and from a pushed route a home jump pops back first.
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

  testWidgets('inside the Cockpit, openCockpit switches tab in place', (
    tester,
  ) async {
    final p = await providers();
    await tester.pumpWidget(app(p, const ClassifiersScreen()));
    await tester.pump();

    final inside = tester.element(find.byType(TabBarView));
    AppNav.instance.openCockpit(inside, kCockpitTabBudgets);
    await tester.pumpAndSettle();

    expect(find.byType(ClassifiersScreen), findsOneWidget, reason: 'no stack');
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.controller!.index, kCockpitTabBudgets);
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

  testWidgets('outside the Cockpit, openCockpit opens it on the tab', (
    tester,
  ) async {
    final p = await providers();
    await tester.pumpWidget(app(p, const Scaffold(body: Text('home'))));
    AppNav.instance.openCockpit(
      tester.element(find.text('home')),
      kCockpitTabCategories,
    );
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.controller!.index, kCockpitTabCategories);
  });
}
