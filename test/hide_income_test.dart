import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';

import 'dashboard_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('SettingsProvider.hideIncome', () {
    test('defaults off, persists across reload', () async {
      final s = SettingsProvider();
      await s.load();
      expect(s.hideIncome, isFalse);
      await s.setHideIncome(true);

      final s2 = SettingsProvider();
      await s2.load();
      expect(s2.hideIncome, isTrue);
    });

    test('rides the backup block', () async {
      final s = SettingsProvider();
      await s.load();
      await s.setHideIncome(true);
      final map = s.toBackupMap();
      expect(map['hideIncome'], isTrue);

      SharedPreferences.setMockInitialValues({});
      final s2 = SettingsProvider();
      await s2.load();
      await s2.applyBackupMap(map);
      expect(s2.hideIncome, isTrue);
      // A backup from before the key existed keeps the current value.
      await s2.applyBackupMap(const {});
      expect(s2.hideIncome, isTrue);
    });
  });

  Widget dashboard(FinanceProvider finance, SettingsProvider settings) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
      );

  Future<(FinanceProvider, SettingsProvider)> seeded() async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    final now = DateTime.now();
    await finance.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 50000,
      note: 'Salary',
      date: DateTime(now.year, now.month, 1),
    );
    await finance.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 900,
      note: 'lunch',
      date: DateTime(now.year, now.month, 1),
    );
    return (finance, settings);
  }

  testWidgets('dashboard drops the Income tile and legend when hidden', (
    tester,
  ) async {
    final (finance, settings) = await seeded();
    await tester.pumpWidget(dashboard(finance, settings));
    await tester.pump(const Duration(milliseconds: 700));
    await openDashboardView(tester, 'Month');

    // The stat card at the top (the chart legend is lazy-built lower down).
    expect(find.text('Income'), findsOneWidget);
    expect(find.text(fmtMoney(50000)), findsOneWidget);

    await settings.setHideIncome(true);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Income'), findsNothing);
    expect(find.text(fmtMoney(50000)), findsNothing);
    // Expense stays untouched, unmasked.
    expect(find.text('Spent'), findsOneWidget);
    expect(find.textContaining(kMaskedAmount), findsNothing);

    // The chart legend also loses its Income entry. It lives on the Trends
    // sub-tab, alongside the bar chart it labels.
    await openDashboardView(tester, 'Trends');
    await tester.scrollUntilVisible(
      find.text('Expense'),
      300,
      scrollable: verticalScrollable(),
    );
    await tester.pump();
    expect(find.text('Expense'), findsOneWidget);
    expect(find.text('Income'), findsNothing);

    await settings.setHideIncome(false);
    await tester.pump(const Duration(milliseconds: 700));
    // The legend entry is back…
    expect(find.text('Income'), findsAtLeastNWidgets(1));
    // …and so is the stat card, which lives on the other sub-tab.
    await openDashboardView(tester, 'Month');
    expect(find.text('Income'), findsOneWidget);
    expect(find.text(fmtMoney(50000)), findsOneWidget);
  });

  testWidgets('transactions month header masks the income total', (
    tester,
  ) async {
    final (finance, settings) = await seeded();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: const MaterialApp(home: Scaffold(body: TransactionsScreen())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('+${fmtMoneyCompact(50000)}'), findsOneWidget);

    await settings.setHideIncome(true);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('+$kMaskedAmount'), findsOneWidget);
    expect(find.text('+${fmtMoneyCompact(50000)}'), findsNothing);
    // The expense total beside it stays real.
    expect(find.text('−${fmtMoneyCompact(900)}'), findsOneWidget);
  });
}
