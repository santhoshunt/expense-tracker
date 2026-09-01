import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/savings_goal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  var seq = 0;
  Tx tx({
    required TxType type,
    required String categoryId,
    required double amount,
    required DateTime date,
  }) => Tx(
    id: 't${seq++}',
    type: type,
    categoryId: categoryId,
    amount: amount,
    note: 'x',
    date: date,
  );

  group('signedForSavings', () {
    final d = DateTime(2026, 7, 1);

    test('transfer expense elsewhere = deposit here (+)', () {
      expect(
        signedForSavings(
          tx(
            type: TxType.expense,
            categoryId: kSavingsTransferCategoryId,
            amount: 5000,
            date: d,
          ),
        ),
        5000,
      );
    });

    test('transfer income elsewhere = withdrawal here (−)', () {
      expect(
        signedForSavings(
          tx(
            type: TxType.income,
            categoryId: kSavingsTransferCategoryId,
            amount: 2000,
            date: d,
          ),
        ),
        -2000,
      );
    });

    test('non-transfer rows keep their natural sign', () {
      expect(
        signedForSavings(
          tx(
            type: TxType.income,
            categoryId: 'other_income',
            amount: 300,
            date: d,
          ),
        ),
        300,
        reason: 'interest credit',
      );
      expect(
        signedForSavings(
          tx(
            type: TxType.expense,
            categoryId: 'other_expense',
            amount: 50,
            date: d,
          ),
        ),
        -50,
        reason: 'fee debit',
      );
    });
  });

  group('avgMonthlyNet', () {
    final now = DateTime(2026, 9, 1);

    test('averages the trailing 90 days to a calendar-month rate', () {
      final rows = [
        for (final daysAgo in [10, 40, 70])
          tx(
            type: TxType.expense,
            categoryId: kSavingsTransferCategoryId,
            amount: 10000,
            date: now.subtract(Duration(days: daysAgo)),
          ),
      ];
      // 30000 over 90 days ≈ 10146.67 per 30.44-day month.
      expect(
        avgMonthlyNet(rows, now: now),
        closeTo(30000 / (90 / 30.44), 0.01),
      );
    });

    test('rows outside the window are ignored', () {
      final rows = [
        tx(
          type: TxType.expense,
          categoryId: kSavingsTransferCategoryId,
          amount: 99999,
          date: now.subtract(const Duration(days: 91)),
        ),
      ];
      expect(avgMonthlyNet(rows, now: now), 0);
    });

    test('withdrawals subtract', () {
      final rows = [
        tx(
          type: TxType.expense,
          categoryId: kSavingsTransferCategoryId,
          amount: 10000,
          date: now.subtract(const Duration(days: 5)),
        ),
        tx(
          type: TxType.income,
          categoryId: kSavingsTransferCategoryId,
          amount: 4000,
          date: now.subtract(const Duration(days: 3)),
        ),
      ];
      expect(avgMonthlyNet(rows, now: now), closeTo(6000 / (90 / 30.44), 0.01));
    });
  });

  group('projectedGoalDate', () {
    final now = DateTime(2026, 9, 1);

    test('projects from the deposit rate', () {
      final projected = projectedGoalDate(
        balance: 50000,
        goal: 60000,
        avgMonthlyNet: 5000,
        now: now,
      );
      // 10000 remaining at 5000/month = 2 months → ceil(60.88) = 61 days.
      expect(projected, now.add(const Duration(days: 61)));
    });

    test('goal reached → null', () {
      expect(
        projectedGoalDate(
          balance: 60000,
          goal: 60000,
          avgMonthlyNet: 5000,
          now: now,
        ),
        isNull,
      );
    });

    test('zero or negative rate → null (no honest estimate)', () {
      expect(
        projectedGoalDate(
          balance: 100,
          goal: 60000,
          avgMonthlyNet: 0,
          now: now,
        ),
        isNull,
      );
      expect(
        projectedGoalDate(
          balance: 100,
          goal: 60000,
          avgMonthlyNet: -50,
          now: now,
        ),
        isNull,
      );
    });
  });

  group('Account.goalAmount', () {
    test('JSON round-trip and absence', () {
      final a = Account(
        id: 'a1',
        name: 'RD',
        type: AccountType.savings,
        keys: const {},
        goalAmount: 500000,
      );
      expect(Account.fromJson(a.toJson()).goalAmount, 500000);
      expect(
        Account.fromJson({
          'id': 'a1',
          'name': 'RD',
          'type': 'savings',
          'keys': const [],
        }).goalAmount,
        isNull,
      );
    });

    test('copyWith clears via clearGoalAmount', () {
      final a = Account(
        id: 'a1',
        name: 'RD',
        type: AccountType.savings,
        keys: const {},
        goalAmount: 500000,
      );
      expect(a.copyWith(clearGoalAmount: true).goalAmount, isNull);
      expect(a.copyWith(goalAmount: 1000).goalAmount, 1000);
    });
  });

  group('FinanceProvider.setSavingsGoal', () {
    test('sets, persists, clears; rejects non-positive', () async {
      final p = FinanceProvider();
      await p.load();
      final id = await p.addAccount(name: 'RD', type: AccountType.savings);

      await p.setSavingsGoal(id, 500000);
      expect(p.accountById(id)!.goalAmount, 500000);

      await p.setSavingsGoal(id, 0);
      await p.setSavingsGoal(id, -5);
      await p.setSavingsGoal(id, double.nan);
      expect(p.accountById(id)!.goalAmount, 500000, reason: 'unchanged');

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.accountById(id)!.goalAmount, 500000);

      await p.setSavingsGoal(id, null);
      expect(p.accountById(id)!.goalAmount, isNull);
    });
  });
}
