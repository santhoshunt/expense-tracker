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
    // The custom-category registry is module-global; reset between tests.
    setCustomCategories(const []);
  });

  final july = DateTime(2026, 7);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> spend(FinanceProvider p, String categoryId, double amount) =>
      p.addTransaction(
        type: categoryById(categoryId).type,
        categoryId: categoryId,
        amount: amount,
        note: '',
        date: DateTime(2026, 7, 10 + p.transactions.length),
      );

  SpendBudget budget(BudgetMode mode, Set<String> ids) => SpendBudget(
    id: 'b',
    name: 'Test',
    limit: 1000,
    mode: mode,
    categoryIds: ids,
  );

  test('include mode counts only picked categories', () async {
    final p = await loaded();
    await spend(p, 'food', 100);
    await spend(p, 'shopping', 50);
    await spend(p, 'transport', 25);

    expect(
      p.budgetSpentFor(budget(BudgetMode.include, {'food', 'transport'}), july),
      125,
    );
  });

  test('include mode counts a picked money-out transfer category', () async {
    final p = await loaded();
    final chit = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.payments,
      color: Colors.teal,
      isTransfer: true,
    );
    await spend(p, 'food', 100);
    await spend(p, chit, 300); // transfer — excluded from expense totals
    await spend(p, 'transfer_out', 40); // unpicked transfer — never counts

    expect(p.expenseInMonth(july), 100); // sanity: transfers stay excluded
    expect(
      p.budgetSpentFor(budget(BudgetMode.include, {'food', chit}), july),
      400,
    );
  });

  test(
    'exclude mode is total spend minus picked; transfers never count',
    () async {
      final p = await loaded();
      await spend(p, 'food', 100);
      await spend(p, 'shopping', 50);
      await spend(p, 'savings_out', 200); // transfer

      expect(
        p.budgetSpentFor(budget(BudgetMode.exclude, {'shopping'}), july),
        100,
      );
      // A (stale) transfer id in the exclude set changes nothing — transfers
      // aren't in the base to begin with.
      expect(
        p.budgetSpentFor(
          budget(BudgetMode.exclude, {'shopping', 'savings_out'}),
          july,
        ),
        100,
      );
      // Empty exclude set = all non-transfer spending.
      expect(p.budgetSpentFor(budget(BudgetMode.exclude, const {}), july), 150);
    },
  );

  test('include mode with an empty set spends nothing', () async {
    final p = await loaded();
    await spend(p, 'food', 100);
    expect(p.budgetSpentFor(budget(BudgetMode.include, const {}), july), 0);
  });

  test('budgets persist across reloads', () async {
    final p = await loaded();
    await p.addBudget(
      name: 'Personal spending',
      limit: 20000,
      mode: BudgetMode.exclude,
      categoryIds: {'shopping', 'entertainment'},
    );

    final p2 = await loaded();
    final b = p2.budgets.single;
    expect(b.name, 'Personal spending');
    expect(b.limit, 20000);
    expect(b.mode, BudgetMode.exclude);
    expect(b.categoryIds, {'shopping', 'entertainment'});
  });

  test('deleteCategory strips the id from budgets', () async {
    final p = await loaded();
    final catId = await p.addCategory(
      label: 'Family',
      type: TxType.expense,
      icon: Icons.payments,
      color: Colors.teal,
    );
    final budId = await p.addBudget(
      name: 'Personal',
      limit: 5000,
      mode: BudgetMode.exclude,
      categoryIds: {catId, 'shopping'},
    );
    await p.deleteCategory(catId);
    final b = p.budgets.firstWhere((b) => b.id == budId);
    expect(b.categoryIds, {'shopping'});

    final p2 = await loaded(); // the strip was persisted
    expect(p2.budgets.single.categoryIds, {'shopping'});
  });

  test('countsTowardBudget mirrors budgetSpentFor row by row', () async {
    final p = await loaded();
    final chit = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.payments,
      color: Colors.teal,
      isTransfer: true,
    );
    await spend(p, 'food', 100);
    await spend(p, chit, 300);
    await spend(p, 'savings_out', 200);
    await spend(p, 'salary', 1000); // income never counts

    final include = budget(BudgetMode.include, {'food', chit});
    final exclude = budget(BudgetMode.exclude, {'food'});

    double viaRows(SpendBudget b) => p.transactions
        .where((t) => p.countsTowardBudget(t, b))
        .fold(0.0, (sum, t) => sum + t.amount);

    expect(viaRows(include), p.budgetSpentFor(include, july)); // 400
    expect(viaRows(exclude), p.budgetSpentFor(exclude, july)); // 0
    expect(viaRows(include), 400);

    final salary = p.transactions.firstWhere((t) => t.categoryId == 'salary');
    expect(p.countsTowardBudget(salary, include), isFalse);
    // Transfers never count in exclude mode, even unpicked ones.
    final savings = p.transactions.firstWhere(
      (t) => t.categoryId == 'savings_out',
    );
    expect(p.countsTowardBudget(savings, exclude), isFalse);
  });

  test('update and delete budget', () async {
    final p = await loaded();
    final id = await p.addBudget(
      name: 'Personal',
      limit: 5000,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    await p.updateBudget(
      p.budgets.single.copyWith(name: 'Own spend', limit: 7000),
    );
    expect(p.budgets.single.name, 'Own spend');
    expect(p.budgets.single.limit, 7000);
    await p.deleteBudget(id);
    expect(p.budgets, isEmpty);
  });
}
