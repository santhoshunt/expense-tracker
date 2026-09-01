import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('savings display vs balance', () {
    final month = DateTime(2026, 8);

    test(
      'as a transfer: display == gated figure, balance subtracts once',
      () async {
        final p = await loaded();
        await p.addTransaction(
          type: TxType.expense,
          categoryId: kSavingsTransferCategoryId,
          amount: 1000,
          note: 'RD',
          date: DateTime(2026, 8, 5),
        );
        expect(p.savingsOutflowInMonth(month), 1000);
        expect(p.savingsTransfersInMonth(month), 1000);
        expect(p.expenseInMonth(month), 0); // transfer, not spend
        expect(p.balance, -1000);
      },
    );

    test(
      'un-transferred: display keeps reporting, no double subtraction',
      () async {
        final p = await loaded();
        await p.addTransaction(
          type: TxType.expense,
          categoryId: kSavingsTransferCategoryId,
          amount: 1000,
          note: 'RD',
          date: DateTime(2026, 8, 5),
        );
        await p.overrideBuiltinCategory(
          id: kSavingsTransferCategoryId,
          label: 'To savings',
          icon: Icons.savings,
          color: Colors.teal,
          isTransfer: false,
        );
        // The Saved card figure survives the opt-out…
        expect(p.savingsOutflowInMonth(month), 1000);
        // …while the balance-side figure moves into plain expense.
        expect(p.savingsTransfersInMonth(month), 0);
        expect(p.expenseInMonth(month), 1000);
        expect(p.balance, -1000); // subtracted exactly once
      },
    );
  });

  group('budget breakdown', () {
    final month = DateTime(2026, 8);

    test(
      'include mode: breakdown sums to budgetSpentFor, transfers count',
      () async {
        final p = await loaded();
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 300,
          note: 'lunch',
          date: DateTime(2026, 8, 3),
        );
        await p.addTransaction(
          type: TxType.expense,
          categoryId: kSavingsTransferCategoryId, // expense-direction transfer
          amount: 700,
          note: 'RD',
          date: DateTime(2026, 8, 4),
        );
        await p.addBudget(
          name: 'Picked',
          limit: 5000,
          mode: BudgetMode.include,
          categoryIds: {'food', kSavingsTransferCategoryId},
        );
        final b = p.budgets.single;
        final breakdown = p.budgetBreakdownFor(b, month);
        final sum = breakdown.fold(0.0, (s, e) => s + e.value);
        expect(sum, p.budgetSpentFor(b, month));
        expect(p.budgetSpentFor(b, month), 1000);
        expect(breakdown.map((e) => e.key.id).toSet(), {
          'food',
          kSavingsTransferCategoryId,
        });
      },
    );

    test('exclude mode: breakdown sums to budgetSpentFor', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 300,
        note: 'lunch',
        date: DateTime(2026, 8, 3),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 200,
        note: 'cab',
        date: DateTime(2026, 8, 3),
      );
      await p.addBudget(
        name: 'No transport',
        limit: 5000,
        mode: BudgetMode.exclude,
        categoryIds: {'transport'},
      );
      final b = p.budgets.single;
      final breakdown = p.budgetBreakdownFor(b, month);
      final sum = breakdown.fold(0.0, (s, e) => s + e.value);
      expect(sum, p.budgetSpentFor(b, month));
      expect(p.budgetSpentFor(b, month), 300);
      expect(breakdown.single.key.id, 'food');
    });

    test('income-direction transfer rows count toward nothing', () async {
      final p = await loaded();
      // Row-level twin: an income-typed row never counts, even in a picked
      // expense transfer category.
      final t = Tx(
        id: 'x',
        type: TxType.income,
        categoryId: kSavingsTransferCategoryId,
        amount: 500,
        note: '',
        date: DateTime(2026, 8, 3),
      );
      await p.addBudget(
        name: 'Picked',
        limit: 5000,
        mode: BudgetMode.include,
        categoryIds: {kSavingsTransferCategoryId},
      );
      expect(p.countsTowardBudget(t, p.budgets.single), isFalse);
    });
  });

  group('day and weekday aggregation', () {
    test('expenseByDayInMonth buckets by day, money-out rows only', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'a',
        date: DateTime(2026, 8, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 50,
        note: 'b',
        date: DateTime(2026, 8, 1, 20),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 200,
        note: 'c',
        date: DateTime(2026, 8, 15),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 9999,
        note: 'pay',
        date: DateTime(2026, 8, 15),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: kSavingsTransferCategoryId, // transfer: excluded
        amount: 400,
        note: 'RD',
        date: DateTime(2026, 8, 15),
      );

      final byDay = p.expenseByDayInMonth(DateTime(2026, 8));
      expect(byDay[1], 150);
      expect(byDay[15], 200);
      expect(byDay.length, 2);

      final rows = p.expensesOnDay(DateTime(2026, 8, 15));
      expect(rows.single.note, 'c');
    });

    test('avgExpenseByWeekday divides by calendar occurrences', () async {
      final p = await loaded();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 12);
      final lastWeek = today.subtract(const Duration(days: 7));
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'a',
        date: lastWeek,
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 300,
        note: 'b',
        date: today,
      );

      final avg = p.avgExpenseByWeekday();
      final w = today.weekday - 1;
      // Span covers exactly two occurrences of this weekday (day 0 and 7).
      expect(avg[w], closeTo(200, 0.001));
      for (var i = 0; i < 7; i++) {
        if (i != w) expect(avg[i], 0);
      }
    });
  });
}
