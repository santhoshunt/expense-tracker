import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';

/// The Overview's Month-end forecast card and the empty-account hint.
/// Amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p,
    SettingsProvider s,
    Widget home, {
    Size size = const Size(400, 2400),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// One row on the 1st of the running month, midnight: never in the
  /// future, whatever day the test runs.
  Future<FinanceProvider> ledger(double amount) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: amount,
      note: 'groceries',
      date: DateTime(now.year, now.month, 1),
    );
    return p;
  }

  Future<SettingsProvider> settings({double cap = 0}) async {
    final s = SettingsProvider();
    await s.load();
    if (cap > 0) await s.setMonthlyBudget(cap);
    return s;
  }

  testWidgets('shows on this month without a cap', (tester) async {
    final p = await ledger(1200);
    await pump(tester, p, await settings(), const DashboardScreen());
    expect(find.text('Month-end forecast'), findsOneWidget);
    expect(find.text('Spent so far'), findsOneWidget);
    expect(find.textContaining('under your'), findsNothing);
    expect(find.textContaining('over your'), findsNothing);
  });

  testWidgets('says how far under or over the cap', (tester) async {
    final p = await ledger(1200);
    await pump(tester, p, await settings(cap: 50000), const DashboardScreen());
    expect(find.textContaining('under your'), findsOneWidget);

    final over = await ledger(90000);
    await pump(
      tester,
      over,
      await settings(cap: 50000),
      const DashboardScreen(),
    );
    expect(find.textContaining('over your'), findsOneWidget);
  });

  testWidgets('the Year view drops it', (tester) async {
    final p = await ledger(1200);
    await pump(tester, p, await settings(), const DashboardScreen());
    expect(find.text('Month-end forecast'), findsOneWidget);
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('Month-end forecast'), findsNothing);
  });

  testWidgets('hidden from Cockpit, it goes', (tester) async {
    final p = await ledger(1200);
    final s = await settings(cap: 50000);
    await s.setSectionHidden(DashboardSection.forecast, true);
    await pump(tester, p, s, const DashboardScreen());
    expect(find.text('Month-end forecast'), findsNothing);
    expect(find.text('Monthly budget'), findsOneWidget);
  });

  testWidgets('fits 320dp at text scale 2', (tester) async {
    final p = await ledger(123456);
    await pump(
      tester,
      p,
      await settings(cap: 50000),
      const DashboardScreen(),
      size: const Size(320, 2400),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Month-end forecast'), findsOneWidget);
  });

  testWidgets('an emptied numbered account says so and offers a way out', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addAccount(name: 'Old HDFC', type: AccountType.bank);
    await p.addAccountKey(id, 'HDFC:4321');
    await p.setManualBalance(id, 5000);
    final hand = await p.addAccount(name: 'Cash', type: AccountType.bank);
    await p.setManualBalance(hand, 800);
    await pump(
      tester,
      p,
      await settings(),
      AccountsScreen(onViewAccount: (_) {}),
    );
    expect(
      find.textContaining('No transactions use this account'),
      findsOneWidget,
      reason: 'the numbered account only, not Cash',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Old HDFC"?'), findsOneWidget);
  });
}
