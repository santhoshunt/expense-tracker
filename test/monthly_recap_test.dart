import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/services/spend_comparison.dart';

/// Last month's recap: the same figures as the Overview, the change against
/// the month before, the top categories and merchant, and budgets over.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // Mid-September: the recap covers August, compared with July.
  final now = DateTime(2026, 9, 15, 10);
  final aug = DateTime(2026, 8);

  Future<(FinanceProvider, SettingsProvider)> load() async {
    final f = FinanceProvider();
    await f.load();
    final s = SettingsProvider();
    await s.load();
    return (f, s);
  }

  Future<void> add(
    FinanceProvider f,
    String category,
    double amount,
    DateTime date, {
    TxType type = TxType.expense,
    String note = '',
  }) => f.addTransaction(
    type: type,
    categoryId: category,
    amount: amount,
    note: note,
    date: date,
  );

  test('null when last month has no confirmed transactions', () async {
    final (f, s) = await load();
    await add(f, 'food', 100, DateTime(2026, 9, 2));
    await add(f, 'food', 100, DateTime(2026, 7, 2));
    expect(buildMonthlyRecap(f, s, now: now), isNull);
  });

  test('figures match the Overview totals for the month', () async {
    final (f, s) = await load();
    await add(f, 'food', 1200, DateTime(2026, 8, 3), note: 'Dinner');
    await add(f, 'bills', 800, DateTime(2026, 8, 10));
    await add(f, 'salary', 50000, DateTime(2026, 8, 1), type: TxType.income);
    await add(f, kSavingsTransferCategoryId, 5000, DateTime(2026, 8, 5));
    // A transfer between own accounts is not spending.
    await add(f, kTransferOutCategoryId, 9000, DateTime(2026, 8, 6));

    final r = buildMonthlyRecap(f, s, now: now)!;
    expect(r.month, aug);
    expect(r.spent, f.expenseInMonth(aug));
    expect(r.spent, 2000);
    expect(r.income, f.incomeInMonth(aug));
    expect(r.saved, f.savingsOutflowInMonth(aug));
    expect(r.saved, 5000);
  });

  test(
    'top three categories, largest first, and the biggest merchant',
    () async {
      final (f, s) = await load();
      await add(f, 'food', 300, DateTime(2026, 8, 2), note: 'Chai stall');
      await add(f, 'food', 300, DateTime(2026, 8, 9), note: 'Chai stall');
      await add(f, 'bills', 900, DateTime(2026, 8, 3), note: 'Power board');
      await add(f, 'transport', 200, DateTime(2026, 8, 4), note: 'Metro');
      await add(f, 'shopping', 100, DateTime(2026, 8, 5), note: 'Shoes');

      final r = buildMonthlyRecap(f, s, now: now)!;
      expect(
        [for (final e in r.topCategories) e.key.id],
        ['bills', 'food', 'transport'],
      );
      expect(r.topMerchant, isNotNull);
      expect(r.topMerchant!.total, 900);
    },
  );

  test('compares with the month before, both taken whole', () async {
    final (f, s) = await load();
    await add(f, 'food', 1000, DateTime(2026, 6, 1));
    await add(f, 'food', 1000, DateTime(2026, 7, 1));
    await add(f, 'food', 800, DateTime(2026, 8, 20));

    final r = buildMonthlyRecap(f, s, now: now)!;
    expect(r.vsPrevious.state, CompareState.ok);
    expect(r.vsPrevious.actual, 800);
    expect(r.vsPrevious.reference, 1000);
    expect(r.vsPrevious.delta, -200);
  });

  test('lists the monthly cap and custom budgets that ended over', () async {
    final (f, s) = await load();
    await s.setMonthlyBudget(1000);
    await f.addBudget(
      name: 'Eating out',
      limit: 500,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    await f.addBudget(
      name: 'Bills',
      limit: 5000,
      mode: BudgetMode.include,
      categoryIds: {'bills'},
    );
    await add(f, 'food', 600, DateTime(2026, 8, 2));
    await add(f, 'bills', 600, DateTime(2026, 8, 3));

    final r = buildMonthlyRecap(f, s, now: now)!;
    expect(
      [for (final b in r.budgetsOver) b.label],
      ['Monthly budget', 'Eating out'],
    );
    expect(r.budgetsOver.first.budgetId, isNull);
    expect(r.budgetsOver.first.pct, closeTo(1.2, 1e-9));
    expect(r.budgetsOver.last.budgetId, isNotNull);
  });

  group('recapBooking', () {
    final sep = DateTime(2026, 9);
    final oct = DateTime(2026, 10);

    test('books next month for this month once it has data', () {
      expect(recapBooking(now, [sep, aug]), (
        when: DateTime(2026, 10, 1, 9),
        month: sep,
      ));
    });

    test('nothing to recap: no booking', () {
      expect(recapBooking(now, [aug]), isNull);
    });

    test('before 09:00 on the 1st, last month is still due today', () {
      final early = DateTime(2026, 10, 1, 8, 30);
      // Whether or not October already has rows.
      for (final months in [
        [sep],
        [oct, sep],
      ]) {
        expect(recapBooking(early, months), (
          when: DateTime(2026, 10, 1, 9),
          month: sep,
        ));
      }
    });

    test('after 09:00 on the 1st, the next month takes over', () {
      final later = DateTime(2026, 10, 1, 9, 30);
      expect(recapBooking(later, [oct, sep]), (
        when: DateTime(2026, 11, 1, 9),
        month: oct,
      ));
      expect(recapBooking(later, [sep]), isNull);
    });

    test('January reaches back to December', () {
      final jan = DateTime(2027, 1, 1, 7);
      expect(recapBooking(jan, [DateTime(2026, 12)]), (
        when: DateTime(2027, 1, 1, 9),
        month: DateTime(2026, 12),
      ));
    });
  });

  test('a January recap covers December', () async {
    final (f, s) = await load();
    await add(f, 'food', 700, DateTime(2026, 12, 24));
    final r = buildMonthlyRecap(f, s, now: DateTime(2027, 1, 10))!;
    expect(r.month, DateTime(2026, 12));
    expect(r.spent, 700);
  });

  test('the note is due at 09:00 on the 1st of next month', () {
    expect(nextRecapTime(now), DateTime(2026, 10, 1, 9));
    expect(nextRecapTime(DateTime(2026, 12, 31, 23)), DateTime(2027, 1, 1, 9));
  });
}
