import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The custom-category registry is module-global; reset between tests.
    setCustomCategories(const []);
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  test('a custom "chit" transfer is excluded from expense totals '
      'but stays in the ledger', () async {
    final p = await loaded();
    final chitId = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.savings,
      color: Colors.teal,
      isTransfer: true,
    );
    expect(isTransferCategory(chitId), isTrue);

    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 640,
      note: 'dinner',
      date: DateTime(2026, 7, 2),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: chitId,
      amount: 5000,
      note: 'monthly chit',
      date: DateTime(2026, 7, 3),
    );

    expect(p.totalExpense, 640);
    expect(p.expenseInMonth(DateTime(2026, 7)), 640);
    expect(
      p.expenseByCategory(DateTime(2026, 7)).map((e) => e.key.id),
      isNot(contains(chitId)),
    );
    // Not surfaced as "saved" either — that figure is savings_out only.
    expect(p.totalSavingsTransfers, 0);
    // The row exists for auditing and per-account balances.
    expect(p.transactions.where((t) => t.categoryId == chitId).length, 1);
  });

  test(
    'an income-direction custom transfer is excluded from income totals',
    () async {
      final p = await loaded();
      final id = await p.addCategory(
        label: 'Friend repaid',
        type: TxType.income,
        icon: Icons.payments,
        color: Colors.green,
        isTransfer: true,
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 50000,
        note: 'salary',
        date: DateTime(2026, 7, 1),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: id,
        amount: 2000,
        note: 'gpay split',
        date: DateTime(2026, 7, 2),
      );
      expect(p.totalIncome, 50000);
      expect(p.incomeInMonth(DateTime(2026, 7)), 50000);
    },
  );

  test(
    'TxCategory JSON round-trips the transfer flag and defaults to false',
    () {
      const c = TxCategory(
        id: 'cat_1',
        label: 'Chit',
        icon: Icons.savings,
        color: Colors.teal,
        type: TxType.expense,
        isTransfer: true,
      );
      final back = TxCategory.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(back.isTransfer, isTrue);

      // Payloads written before the flag existed load as non-transfer.
      final legacy = TxCategory.fromJson({
        'id': 'cat_2',
        'label': 'Home',
        'type': 'expense',
        'icon': 'home',
        'color': 0xFF112233,
      });
      expect(legacy.isTransfer, isFalse);
      // And a non-transfer category writes the same payload it always did.
      expect(legacy.toJson().containsKey('transfer'), isFalse);
    },
  );

  test('the transfer flag survives a provider reload', () async {
    final p = await loaded();
    final id = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.savings,
      color: Colors.teal,
      isTransfer: true,
    );

    setCustomCategories(const []); // simulate a fresh process
    final p2 = FinanceProvider();
    await p2.load();
    expect(customCategories.single.isTransfer, isTrue);
    expect(isTransferCategory(id), isTrue);
    expect(p2.loaded, isTrue);
  });

  test(
    'deleting a transfer category reroutes its rows back into totals',
    () async {
      final p = await loaded();
      final id = await p.addCategory(
        label: 'Chit',
        type: TxType.expense,
        icon: Icons.savings,
        color: Colors.teal,
        isTransfer: true,
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: id,
        amount: 5000,
        note: 'chit',
        date: DateTime(2026, 7, 3),
      );
      expect(p.totalExpense, 0);
      await p.deleteCategory(id);
      expect(p.transactions.single.categoryId, 'other_expense');
      expect(p.totalExpense, 5000);
      expect(isTransferCategory(id), isFalse);
    },
  );

  test('backup export → replace-import restores custom categories', () async {
    final p = await loaded();
    final id = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.savings,
      color: Colors.teal,
      isTransfer: true,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: id,
      amount: 5000,
      note: 'chit',
      date: DateTime(2026, 7, 3),
    );
    final backup = jsonEncode(p.exportData());

    // Fresh install.
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    final target = FinanceProvider();
    await target.load();
    await target.importData(
      jsonDecode(backup) as Map<String, dynamic>,
      replace: true,
    );

    expect(customCategories.single.label, 'Chit');
    expect(customCategories.single.isTransfer, isTrue);
    // The restored row resolves to the real category, not the "Other"
    // fallback, and stays out of expense totals.
    expect(target.transactions.single.category.label, 'Chit');
    expect(target.totalExpense, 0);
  });

  test('a backup without categories imports cleanly and leaves existing '
      'custom categories alone', () async {
    final p = await loaded();
    await p.addCategory(
      label: 'Pets',
      type: TxType.expense,
      icon: Icons.pets,
      color: Colors.brown,
    );
    // v3-era backup shape: no 'categories' key at all.
    final added = await p.importData({
      'app': 'expense_tracker',
      'version': 3,
      'transactions': <Map<String, dynamic>>[],
      'accounts': <Map<String, dynamic>>[],
    }, replace: true);
    expect(added, 0);
    expect(customCategories.single.label, 'Pets');
  });

  test(
    'merge import unions categories by id — existing definitions win',
    () async {
      final p = await loaded();
      final keptId = await p.addCategory(
        label: 'Chit (mine)',
        type: TxType.expense,
        icon: Icons.savings,
        color: Colors.teal,
        isTransfer: true,
      );
      await p.importData({
        'app': 'expense_tracker',
        'version': 4,
        'transactions': <Map<String, dynamic>>[],
        'accounts': <Map<String, dynamic>>[],
        'categories': [
          {
            'id': keptId,
            'label': 'Chit (backup)',
            'type': 'expense',
            'icon': 'savings',
            'color': 0xFF112233,
          },
          {
            'id': 'cat_new',
            'label': 'Lending',
            'type': 'expense',
            'icon': 'cash',
            'color': 0xFF445566,
            'transfer': true,
          },
        ],
      }, replace: false);

      expect(customCategories.length, 2);
      expect(categoryById(keptId).label, 'Chit (mine)');
      expect(categoryById('cat_new').label, 'Lending');
      expect(isTransferCategory('cat_new'), isTrue);
    },
  );
}
