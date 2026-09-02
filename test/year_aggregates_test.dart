import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    Future<void> add(TxType type, String cat, double amount, DateTime date) =>
        p.addTransaction(
          type: type,
          categoryId: cat,
          amount: amount,
          note: cat,
          date: date,
        );
    await add(TxType.income, 'salary', 50000, DateTime(2025, 1, 1));
    await add(TxType.expense, 'food', 1000, DateTime(2025, 1, 5));
    await add(TxType.expense, 'food', 2000, DateTime(2025, 6, 5));
    await add(TxType.expense, 'transport', 500, DateTime(2025, 12, 31));
    await add(
      TxType.expense,
      kSavingsTransferCategoryId,
      4000,
      DateTime(2025, 3, 1),
    );
    // Next year: must not leak into 2025.
    await add(TxType.income, 'salary', 60000, DateTime(2026, 1, 1));
    await add(TxType.expense, 'food', 999, DateTime(2026, 1, 2));
    return p;
  }

  test('year totals sum the twelve months and stop at the boundary', () async {
    final p = await seeded();
    expect(p.incomeInYear(2025), 50000);
    expect(p.expenseInYear(2025), 3500);
    expect(p.savingsOutflowInYear(2025), 4000);
    expect(p.incomeInYear(2026), 60000);
    expect(p.expenseInYear(2026), 999);
    expect(p.expenseInYear(2024), 0);
  });

  test('expenseByCategoryInYear merges months, largest first', () async {
    final p = await seeded();
    final by = p.expenseByCategoryInYear(2025);
    expect(by.map((e) => e.key.id), ['food', 'transport']);
    expect(by.first.value, 3000);
    expect(by.last.value, 500);
  });

  test('monthlySeries has twelve entries, January first', () async {
    final p = await seeded();
    final series = p.monthlySeries(2025);
    expect(series, hasLength(12));
    expect(series.first.month, DateTime(2025, 1));
    expect(series.first.income, 50000);
    expect(series.first.expense, 1000);
    expect(series[5].expense, 2000);
    expect(series.last.expense, 500);
    expect(series[7].income + series[7].expense, 0);
  });
}
