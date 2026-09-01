import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Module-global registries must not leak between tests.
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final july = DateTime(2026, 7);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('Tx.myShare model', () {
    final split = Tx(
      id: 's1',
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'team dinner',
      date: DateTime(2026, 7, 5, 21),
      myShare: 125,
    );

    test('derived getters', () {
      expect(split.isSplit, isTrue);
      expect(split.spendAmount, 125);
      expect(split.frontedAmount, 375);

      final plain = split.copyWith(clearMyShare: true);
      expect(plain.isSplit, isFalse);
      expect(plain.spendAmount, 500);
      expect(plain.frontedAmount, 0);
    });

    test('JSON round-trips; key omitted when null', () {
      final roundTrip = Tx.fromJson(
        jsonDecode(jsonEncode(split.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.myShare, 125);

      final plain = split.copyWith(clearMyShare: true);
      expect(plain.toJson().containsKey('myShare'), isFalse);
      expect(Tx.fromJson(plain.toJson()).myShare, isNull);
    });

    test('copyWith carries the share through unrelated edits', () {
      final edited = split.copyWith(note: 'edited', amount: 600);
      expect(edited.myShare, 125);
      expect(edited.copyWith(myShare: 200).myShare, 200);
    });

    test('migrateSmsBodyFromNote preserves the share', () {
      const body = 'Rs.500 debited from a/c XX1234';
      final legacy = Tx(
        id: 'l1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 500,
        note: body,
        date: DateTime(2026, 7, 5),
        source: TxSource.sms,
        myShare: 125,
      );
      final migrated = legacy.migrateSmsBodyFromNote();
      expect(migrated.smsBody, body);
      expect(migrated.myShare, 125);
    });
  });

  test('paid_for_others is a transfer category on a fresh install', () {
    // kTransferCategoryIds is the only registration until a registry writer
    // runs — a fresh install must already treat the category as a transfer.
    expect(kTransferCategoryIds, contains(kPaidForOthersCategoryId));
    expect(isTransferCategory(kPaidForOthersCategoryId), isTrue);
    expect(categoryById(kPaidForOthersCategoryId).isTransfer, isTrue);
    expect(categoryById(kPaidForOthersCategoryId).type, TxType.expense);
  });

  group('aggregations', () {
    Future<FinanceProvider> withSplit() async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 500,
        note: 'group dinner',
        date: DateTime(2026, 7, 5, 21),
        myShare: 125,
      );
      return p;
    }

    test(
      'only the share counts as expense; remainder is Paid for Others',
      () async {
        final p = await withSplit();
        expect(p.totalExpense, 125);
        expect(p.balance, -125);
        expect(p.expenseInMonth(july), 125);

        final food = p
            .expenseByCategory(july)
            .singleWhere((e) => e.key.id == 'food');
        expect(food.value, 125);

        expect(p.transferOutInMonth(july), 375);
        final fronted = p
            .transfersByCategoryInMonth(july)
            .singleWhere((e) => e.key.id == kPaidForOthersCategoryId);
        expect(fronted.value, 375);

        // Savings figures are untouched by splits.
        expect(p.totalSavingsTransfers, 0);
      },
    );

    test('heatmap folds use the share', () async {
      final p = await withSplit();
      expect(p.expenseByDayInMonth(july)[5], 125);
    });

    test('a food budget counts the share, not the full bill', () async {
      final p = await withSplit();
      const b = SpendBudget(
        id: 'b',
        name: 'Food',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      expect(p.budgetSpentFor(b, july), 125);
    });

    test('splitting an SMS row leaves the account anchor alone', () async {
      final p = await loaded();
      final now = DateTime.now();
      await p.importTransactions([
        Tx(
          id: 'sms1',
          type: TxType.expense,
          categoryId: 'food',
          amount: 500,
          note: '',
          date: DateTime(now.year, now.month, now.day, 12),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: 'HDFC:1234',
          balanceAfter: 5000,
        ),
      ], replace: false);
      final acc = p.accounts.single;
      expect(p.accountBalance(acc), 5000);

      await p.updateTransaction(p.transactions.single.copyWith(myShare: 125));
      // The bank stated 5000 after the full ₹500 debit — the split must not
      // shift the account balance, only the spend attribution.
      expect(p.accountBalance(acc), 5000);
      expect(p.accountSpentThisMonth(acc), 125);
    });
  });

  group('deleteCategory moveTo', () {
    Future<(FinanceProvider, String)> withCustomSplit() async {
      final p = await loaded();
      final chai = await p.addCategory(
        label: 'Chai runs',
        type: TxType.expense,
        icon: Icons.local_cafe,
        color: Colors.brown,
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: chai,
        amount: 500,
        note: '',
        date: DateTime(2026, 7, 5),
        myShare: 125,
      );
      return (p, chai);
    }

    test('rows move to the chosen category, share intact', () async {
      final (p, chai) = await withCustomSplit();
      await p.deleteCategory(chai, moveTo: 'food');
      final t = p.transactions.single;
      expect(t.categoryId, 'food');
      expect(t.type, TxType.expense);
      expect(t.myShare, 125);
    });

    test('a transfer target re-types the row and clears the share', () async {
      final (p, chai) = await withCustomSplit();
      await p.deleteCategory(chai, moveTo: kSavingsTransferCategoryId);
      final t = p.transactions.single;
      expect(t.categoryId, kSavingsTransferCategoryId);
      expect(t.myShare, isNull);
      expect(p.totalExpense, 0);
      expect(p.totalSavingsTransfers, 500);
    });

    test('no target (or an unknown one) still falls back to Other', () async {
      final (p, chai) = await withCustomSplit();
      await p.deleteCategory(chai, moveTo: 'no_such_category');
      expect(p.transactions.single.categoryId, 'other_expense');
    });
  });

  group('import/export', () {
    test(
      'CSV round-trips myShare; files without the column yield null',
      () async {
        final p = await loaded();
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 500,
          note: 'group dinner',
          date: DateTime(2026, 7, 5),
          myShare: 125,
        );
        final csv = BackupService.buildCsv(p);
        expect(csv.split('\r\n').first, contains('myShare'));
        expect(BackupService.txsFromCsv(csv).single.myShare, 125);

        final legacy = BackupService.txsFromCsv(
          'date,type,amount\r\n2026-07-01T10:00:00,expense,123.45',
        );
        expect(legacy.single.myShare, isNull);
      },
    );

    test('sanitizer clamps and clears invalid shares on import', () async {
      final p = await loaded();
      Tx row(String id, TxType type, String cat, double? share) => Tx(
        id: id,
        type: type,
        categoryId: cat,
        amount: 500,
        note: '',
        date: DateTime(2026, 7, 5),
        myShare: share,
      );
      await p.importTransactions([
        row('over', TxType.expense, 'food', 600), // > amount → clamp
        row('neg', TxType.expense, 'food', -10), // < 0 → clamp
        row('income', TxType.income, 'salary', 100), // wrong direction → null
        row('transfer', TxType.expense, kSavingsTransferCategoryId, 100),
      ], replace: true);

      Tx byId(String id) => p.transactions.singleWhere((t) => t.id == id);
      expect(byId('over').myShare, 500);
      expect(byId('over').frontedAmount, 0);
      expect(byId('neg').myShare, 0);
      expect(byId('income').myShare, isNull);
      expect(byId('transfer').myShare, isNull);
    });

    test('JSON backup is v10 and round-trips the share', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 500,
        note: 'group dinner',
        date: DateTime(2026, 7, 5),
        myShare: 125,
      );
      final data = p.exportData();
      expect(data['version'], greaterThanOrEqualTo(10));

      SharedPreferences.setMockInitialValues({});
      final target = FinanceProvider();
      await target.load();
      await target.importData(
        jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
        replace: true,
      );
      expect(target.transactions.single.myShare, 125);
      expect(target.totalExpense, 125);
    });
  });
}
