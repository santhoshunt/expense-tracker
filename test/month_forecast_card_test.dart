import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/utils/format.dart';

/// The Monthly budget card's Due this month sheet (the Month-end forecast
/// card that once held it is gone) and the empty-account hint. Amounts are
/// made up.
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

  testWidgets('Due this month opens the list of what is due', (tester) async {
    final p = await ledger(1200);
    final now = DateTime.now();
    // Due on the month's last day: always ahead, or today.
    await p.restoreReminder(
      Reminder(
        id: 'broadband',
        name: 'Broadband',
        dayOfMonth: DateTime(now.year, now.month + 1, 0).day,
        categoryId: 'other_expense',
        expectedAmount: 799,
        // Last month's paid, so only this month's is due (an unpaid one
        // from the last week would show as overdue too).
        lastPaidMonth: _monthKey(DateTime(now.year, now.month - 1)),
      ),
    );
    await pump(tester, p, await settings(cap: 50000), const DashboardScreen());
    await tester.tap(find.text('Due this month (1)'));
    await tester.pumpAndSettle();
    Finder inSheet(Finder f) =>
        find.descendant(of: find.byType(BottomSheet), matching: f);
    expect(inSheet(find.text('Due this month')), findsOneWidget);
    expect(inSheet(find.text('Broadband')), findsOneWidget);
    expect(inSheet(find.textContaining('· reminder')), findsOneWidget);

    // Paid marks it, greys the row and takes it out of the total; Undo
    // puts it back.
    await tester.tap(inSheet(find.widgetWithText(TextButton, 'Paid')));
    await tester.pumpAndSettle();
    expect(find.text('Marked paid'), findsOneWidget);
    expect(p.reminders.single.lastPaidMonth, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Marked paid'), findsNothing);
    expect(
      p.reminders.single.lastPaidMonth,
      _monthKey(DateTime(now.year, now.month - 1)),
    );
  });

  testWidgets('an Add it for me reminder has no Paid button', (tester) async {
    final p = await ledger(1200);
    final now = DateTime.now();
    await p.restoreReminder(
      Reminder(
        id: 'sip',
        name: 'Monthly SIP',
        dayOfMonth: DateTime(now.year, now.month + 1, 0).day,
        categoryId: 'other_expense',
        expectedAmount: 2000,
        autoAdd: true,
        autoSince: '2020-01-01',
        lastPaidMonth: _monthKey(DateTime(now.year, now.month - 1)),
      ),
    );
    await pump(tester, p, await settings(cap: 50000), const DashboardScreen());
    await tester.tap(find.text('Due this month (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Added for you on the day'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Paid'), findsNothing);
  });

  testWidgets('the budget card says once how far under or over the cap', (
    tester,
  ) async {
    final p = await ledger(1200);
    await pump(tester, p, await settings(cap: 50000), const DashboardScreen());
    expect(find.text('${fmtMoneyWhole(48800)} left'), findsOneWidget);
    expect(find.textContaining('under your'), findsNothing);

    final over = await ledger(90000);
    await pump(
      tester,
      over,
      await settings(cap: 50000),
      const DashboardScreen(),
    );
    // (The stored ledger keeps the first row too: over by its sum.)
    expect(find.textContaining(' over the cap'), findsOneWidget);
    expect(find.textContaining('over your'), findsNothing);
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
    expect(find.text('Monthly budget'), findsOneWidget);
  });

  testWidgets('an emptied numbered account says so and offers a way out', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addAccount(name: 'Old HDFC', type: AccountType.bank);
    // An SMS-made number: one typed in by hand is waiting, not emptied.
    await p.addAccountKey(id, 'HDFC:4321', byHand: false);
    await p.setManualBalance(id, 5000);
    final hand = await p.addAccount(name: 'Cash', type: AccountType.bank);
    await p.setManualBalance(hand, 800);
    await pump(
      tester,
      p,
      await settings(),
      AccountsScreen(onViewAccount: (_) {}),
    );
    // Collapsed, a mark on the numbered account only, not Cash.
    expect(
      find.byTooltip(
        'No transactions use this account. Its set balance no longer counts '
        'in net balance. Merge it into the account that has its '
        'transactions, or delete it.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Old HDFC'));
    await tester.pumpAndSettle();
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

String _monthKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';
