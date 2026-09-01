import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/format.dart';

/// Balance-anchor precedence when SMS rows are re-dated (a salary moved to
/// the 1st of next month), plus the dashboard's next-month arrow reaching
/// months that only exist because of such rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  ParsedTxn bankTxn({
    required TxType type,
    required double amount,
    required double avlBal,
    required DateTime date,
    required String ref,
  }) => ParsedTxn(
    type: type,
    amount: amount,
    merchant: 'X',
    date: date,
    ref: ref,
    categoryId: type == TxType.income ? 'salary' : 'other_expense',
    sender: 'VM-HDFCBK',
    rawBody:
        'Rs.$amount ${type == TxType.income ? 'credited to' : 'debited from'}'
        ' a/c XX1234. Avl Bal Rs.$avlBal.',
    acctKey: 'HDFC:1234',
    balanceAfter: avlBal,
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('re-dating clears the stated balance', () {
    test('updateTransaction to another day drops balanceAfter', () async {
      final p = await loaded();
      await p.addImported([
        bankTxn(
          type: TxType.expense,
          amount: 100,
          avlBal: 5000,
          date: DateTime(2026, 8, 20, 10),
          ref: 'R1',
        ),
      ]);
      final t = p.pendingTransactions.single;
      expect(t.balanceAfter, 5000);

      await p.updateTransaction(t.copyWith(date: DateTime(2026, 8, 21, 10)));
      final moved = p.pendingTransactions.single;
      expect(moved.balanceAfter, isNull);
    });

    test('a same-day time-only edit keeps balanceAfter', () async {
      final p = await loaded();
      await p.addImported([
        bankTxn(
          type: TxType.expense,
          amount: 100,
          avlBal: 5000,
          date: DateTime(2026, 8, 20, 0, 0),
          ref: 'R1',
        ),
      ]);
      final t = p.pendingTransactions.single;
      // Correcting the midnight "time unknown" sentinel is a legit edit —
      // the anchor stays honest on the same day.
      await p.updateTransaction(
        t.copyWith(date: DateTime(2026, 8, 20, 18, 45)),
      );
      expect(p.pendingTransactions.single.balanceAfter, 5000);
    });

    test('bulk setDateTimeForMany onto a new day drops balanceAfter', () async {
      final p = await loaded();
      await p.addImported([
        bankTxn(
          type: TxType.expense,
          amount: 100,
          avlBal: 5000,
          date: DateTime(2026, 8, 20, 10),
          ref: 'R1',
        ),
      ]);
      final id = p.pendingTransactions.single.id;
      await p.setDateTimeForMany({id}, DateTime(2026, 8, 22, 9, 30));
      expect(p.pendingTransactions.single.balanceAfter, isNull);
      expect(p.pendingTransactions.single.date, DateTime(2026, 8, 22, 9, 30));
    });
  });

  group('balance derivation around re-dated rows', () {
    test(
      'salary moved to tomorrow: spends subtract, manual overwrite sticks',
      () async {
        final p = await loaded();
        final now = DateTime.now();
        // Baseline anchor ten days back, then the salary alert an hour ago.
        await p.addImported([
          bankTxn(
            type: TxType.expense,
            amount: 100,
            avlBal: 20000,
            date: now.subtract(const Duration(days: 10)),
            ref: 'R1',
          ),
          bankTxn(
            type: TxType.income,
            amount: 75000,
            avlBal: 95000,
            date: now.subtract(const Duration(hours: 1)),
            ref: 'R2',
          ),
        ]);
        // Pending rows don't count toward account figures.
        await p.confirmAllPending();
        final acc = p.accounts.single;
        expect(p.accountBalance(acc), 95000);

        // Sandy's move: salary belongs to next month's budget.
        final salary = p.transactions.firstWhere(
          (t) => t.type == TxType.income,
        );
        await p.updateTransaction(
          salary.copyWith(date: now.add(const Duration(days: 1))),
        );
        // The future-day row neither anchors nor pre-counts: balance falls
        // back to the older anchor.
        expect(p.accountBalance(p.accountById(acc.id)!), 20000);

        // A spend made today subtracts instead of being swallowed.
        final spendId = await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 500,
          note: '',
          date: now,
        );
        await p.assignAccount(spendId, acc.id);
        expect(p.accountBalance(p.accountById(acc.id)!), 19500);

        // And "Set balance…" takes precedence immediately.
        await p.setManualBalance(acc.id, 90000);
        expect(p.accountBalance(p.accountById(acc.id)!), 90000);
      },
    );
  });

  group('dashboard next-month arrow', () {
    Widget app(FinanceProvider p) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: p),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
    );

    IconButton nextArrow(WidgetTester tester) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Next month'),
        matching: find.byType(IconButton),
      ),
    );

    testWidgets('disabled at the current month with no future data', (
      tester,
    ) async {
      final p = await loaded();
      await tester.pumpWidget(app(p));
      expect(nextArrow(tester).onPressed, isNull);
    });

    testWidgets('steps into a future month that has data', (tester) async {
      final p = await loaded();
      final now = DateTime.now();
      final nextMonth = DateTime(now.year, now.month + 1, 1, 12);
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 75000,
        note: 're-dated salary',
        date: nextMonth,
      );
      await tester.pumpWidget(app(p));

      expect(nextArrow(tester).onPressed, isNotNull);
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text(fmtMonth(nextMonth)), findsWidgets);
      // And no further: the arrow stops at the latest month with data.
      expect(nextArrow(tester).onPressed, isNull);
    });
  });
}
