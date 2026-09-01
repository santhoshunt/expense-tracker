import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/category_group.dart';
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

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  final july = DateTime(2026, 7);

  Future<void> spend(
    FinanceProvider p,
    String categoryId,
    double amount, {
    TxType? type,
  }) => p.addTransaction(
    type: type ?? categoryById(categoryId).type,
    categoryId: categoryId,
    amount: amount,
    note: '',
    date: DateTime(2026, 7, 10 + p.transactions.length),
  );

  group('seeding', () {
    test('fresh load seeds Needs/Wants with default assignments', () async {
      final p = await loaded();
      expect(p.groups.map((g) => g.label), containsAll(['Needs', 'Wants']));
      expect(p.groupIdOf('food'), 'grp_needs');
      expect(p.groupIdOf('transport'), 'grp_needs');
      expect(p.groupIdOf('shopping'), 'grp_wants');
      expect(p.groupIdOf('entertainment'), 'grp_wants');
      // Transfers and the catch-all start unassigned.
      expect(p.groupIdOf('savings_out'), isNull);
      expect(p.groupIdOf('other_expense'), isNull);
    });

    test('deleting a seeded group sticks across reloads', () async {
      final p = await loaded();
      await p.deleteGroup('grp_needs');

      final p2 = await loaded();
      expect(p2.groups.map((g) => g.id), isNot(contains('grp_needs')));
      expect(p2.groupIdOf('food'), isNull); // members unassigned, and stays so
      expect(p2.groups.map((g) => g.id), contains('grp_wants'));
    });
  });

  group('CRUD', () {
    test('add/rename/assign survive a reload', () async {
      final p = await loaded();
      final id = await p.addGroup(label: 'Leisure', color: Colors.teal);
      await p.assignCategoryToGroup('entertainment', id); // moves off Wants
      await p.updateGroup(
        CategoryGroup(id: id, label: 'Fun', color: Colors.teal),
      );

      final p2 = await loaded();
      expect(p2.groups.firstWhere((g) => g.id == id).label, 'Fun');
      expect(p2.groupIdOf('entertainment'), id);
    });

    test('deleteGroup unassigns its members', () async {
      final p = await loaded();
      final id = await p.addGroup(label: 'Leisure', color: Colors.teal);
      await p.assignCategoryToGroup('entertainment', id);
      await p.deleteGroup(id);
      expect(p.groupIdOf('entertainment'), isNull);
    });

    test('deleteCategory removes its group assignment', () async {
      final p = await loaded();
      final catId = await p.addCategory(
        label: 'Chit',
        type: TxType.expense,
        icon: Icons.payments,
        color: Colors.teal,
        isTransfer: true,
      );
      await p.assignCategoryToGroup(catId, 'grp_wants');
      await p.deleteCategory(catId);
      expect(p.groupIdOf(catId), isNull);
    });

    test('editing a category into plain income drops its assignment', () async {
      final p = await loaded();
      final catId = await p.addCategory(
        label: 'Family',
        type: TxType.expense,
        icon: Icons.payments,
        color: Colors.teal,
      );
      await p.assignCategoryToGroup(catId, 'grp_needs');
      await p.updateCategory(
        TxCategory(
          id: catId,
          label: 'Family',
          type: TxType.income,
          icon: Icons.payments,
          color: Colors.teal,
        ),
      );
      expect(p.groupIdOf(catId), isNull);
    });
  });

  group('groupSpendInMonth', () {
    test(
      'sums expenses per group; unassigned land in the null bucket',
      () async {
        final p = await loaded();
        await spend(p, 'food', 100); // Needs
        await spend(p, 'transport', 40); // Needs
        await spend(p, 'shopping', 50); // Wants
        await spend(p, 'other_expense', 30); // unassigned
        await spend(p, 'salary', 1000); // plain income — never appears

        final sums = {for (final (g, v) in p.groupSpendInMonth(july)) g?.id: v};
        expect(sums['grp_needs'], 140);
        expect(sums['grp_wants'], 50);
        expect(sums[null], 30);
        expect(sums.values.fold(0.0, (a, b) => a + b), 220);
      },
    );

    test(
      'grouped money-out transfer adds; money-in transfer does not',
      () async {
        final p = await loaded();
        await p.assignCategoryToGroup('savings_out', 'grp_needs');
        await p.assignCategoryToGroup('transfer_in', 'grp_needs');
        await spend(p, 'food', 100);
        await spend(p, 'savings_out', 200); // expense-typed transfer → counts
        await spend(p, 'transfer_in', 500); // income-typed transfer → ignored

        final sums = {for (final (g, v) in p.groupSpendInMonth(july)) g?.id: v};
        expect(sums['grp_needs'], 300);
        // Income/expense aggregates stay transfer-free.
        expect(p.expenseInMonth(july), 100);
        expect(p.incomeInMonth(july), 0);
      },
    );

    test('dangling assignment after group deletion falls into Other', () async {
      final p = await loaded();
      await spend(p, 'food', 100);
      await p.deleteGroup('grp_needs');
      final sums = {for (final (g, v) in p.groupSpendInMonth(july)) g?.id: v};
      expect(sums[null], 100);
    });
  });

  group('transfer month aggregates', () {
    test('in/out totals and per-category breakdown', () async {
      final p = await loaded();
      await spend(p, 'transfer_out', 100);
      await spend(p, 'savings_out', 60);
      await spend(p, 'transfer_in', 40);
      await spend(p, 'food', 25); // not a transfer

      expect(p.transferOutInMonth(july), 160);
      expect(p.transferInInMonth(july), 40);
      final by = {
        for (final e in p.transfersByCategoryInMonth(july)) e.key.id: e.value,
      };
      expect(by, {'transfer_out': 100, 'savings_out': 60, 'transfer_in': 40});
      // Sorted largest first.
      expect(p.transfersByCategoryInMonth(july).first.key.id, 'transfer_out');
    });
  });

  group('backup v6', () {
    test(
      'export carries groups/assignments/budgets; replace restores them',
      () async {
        final p = await loaded();
        final gid = await p.addGroup(label: 'Leisure', color: Colors.teal);
        await p.assignCategoryToGroup('entertainment', gid);
        await p.addBudget(
          name: 'Personal',
          limit: 5000,
          mode: BudgetMode.exclude,
          categoryIds: {'shopping'},
        );
        final data = p.exportData();
        expect(data['version'], greaterThanOrEqualTo(6));
        expect(data['groups'], isA<List>());
        expect(data['groupAssignments'], isA<Map>());
        expect(data['budgets'], isA<List>());

        SharedPreferences.setMockInitialValues({});
        setCustomCategories(const []);
        final p2 = await loaded(); // freshly seeded device
        await p2.importData(data, replace: true);
        expect(p2.groups.map((g) => g.id), contains(gid));
        expect(p2.groupIdOf('entertainment'), gid);
        expect(p2.budgets.single.name, 'Personal');
        expect(p2.budgets.single.categoryIds, {'shopping'});
      },
    );

    test('v5-shaped backup leaves device groups and budgets alone', () async {
      final p = await loaded();
      final gid = await p.addGroup(label: 'Leisure', color: Colors.teal);
      await p.addBudget(
        name: 'Personal',
        limit: 5000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );
      await p.importData({
        'app': 'expense_tracker',
        'version': 5,
        'transactions': const [],
      }, replace: true);
      expect(p.groups.map((g) => g.id), contains(gid));
      expect(p.budgets, hasLength(1));
    });

    test(
      'merge keeps existing definitions and drops dangling assignments',
      () async {
        final p = await loaded();
        await p.assignCategoryToGroup('other_expense', 'grp_wants');
        await p.importData({
          'app': 'expense_tracker',
          'version': 6,
          'transactions': const [],
          'groups': [
            // Same id as the seeded group, different label — existing wins.
            {'id': 'grp_needs', 'label': 'Imported', 'color': 0xFF000000},
          ],
          'groupAssignments': {
            'other_expense': 'grp_needs', // device already assigned — kept
            'savings_out': 'grp_gone', // dangling group id — dropped
          },
          'budgets': const [],
        }, replace: false);
        expect(p.groups.firstWhere((g) => g.id == 'grp_needs').label, 'Needs');
        expect(p.groupIdOf('other_expense'), 'grp_wants');
        expect(p.groupIdOf('savings_out'), isNull);
      },
    );
  });
}
