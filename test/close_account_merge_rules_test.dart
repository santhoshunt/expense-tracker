import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';

/// Closing accounts (savings leave the open lists but keep their history),
/// merging classifier rules (conditions OR-chained into the survivor), and
/// the account menu opening at a stable position near the bottom edge.
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

  group('close account', () {
    test('leaves openAccounts but stays resolvable with its history', () async {
      final p = await loaded();
      final id = await p.addAccount(name: 'RD', type: AccountType.savings);
      final txId = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 500,
        note: 'deposit',
        date: DateTime(2026, 8, 1),
      );
      await p.assignAccount(txId, id);
      expect(p.transactionsForAccount(id), hasLength(1));

      await p.closeAccount(id);
      expect(p.openAccounts.where((a) => a.id == id), isEmpty);
      expect(p.closedAccounts.single.id, id);
      // History untouched: the account and its transactions still resolve.
      expect(p.accountById(id)!.isClosed, isTrue);
      expect(p.transactionsForAccount(id), hasLength(1));

      await p.reopenAccount(id);
      expect(p.openAccounts.single.id, id);
      expect(p.closedAccounts, isEmpty);
    });

    test('closed savings value drops out of the savings total', () async {
      final p = await loaded();
      final id = await p.addAccount(name: 'FD', type: AccountType.savings);
      await p.setManualBalance(id, 50000);
      expect(p.savingsBalanceTotal, 50000);

      await p.closeAccount(id);
      expect(p.savingsBalanceTotal, 0);
    });

    test('closedAt survives a reload', () async {
      SharedPreferences.setMockInitialValues({
        'accounts_v1': jsonEncode([
          Account(
            id: 'acc_rd',
            name: 'RD',
            type: AccountType.savings,
            keys: {'manual:a'},
            closedAt: DateTime(2026, 8, 30),
          ).toJson(),
        ]),
        'accounts_migrated_v1': true,
        'accounts_migrated_v2': true,
        'accounts_migrated_v3': true,
        'accounts_migrated_v4': true,
      });
      final p = FinanceProvider();
      await p.load();
      expect(p.openAccounts, isEmpty);
      expect(p.closedAccounts.single.closedAt, DateTime(2026, 8, 30));
    });
  });

  group('merge classifier rules', () {
    test('conditions chain as OR into the highest-priority rule', () async {
      final p = await loaded();
      await p.addRule('chai', 'food'); // index 1 after next insert
      await p.addRule('dosa hut | idli spot', 'food'); // index 0
      final survivorId = p.rules[0].id;
      final absorbedId = p.rules[1].id;

      await p.mergeRules({survivorId, absorbedId});

      final merged = p.rules.singleWhere((r) => r.id == survivorId);
      expect(merged.patterns, ['dosa hut', 'idli spot', 'chai']);
      expect(p.rules.where((r) => r.id == absorbedId), isEmpty);
    });

    test('duplicate conditions collapse case-insensitively', () async {
      final p = await loaded();
      await p.addRule('Chai Kings', 'food');
      await p.addRule('chai kings | filter kaapi', 'food');
      final survivorId = p.rules[0].id;

      await p.mergeRules({survivorId, p.rules[1].id});
      expect(p.rules.singleWhere((r) => r.id == survivorId).patterns, [
        'chai kings',
        'filter kaapi',
      ]);
    });

    test('survivor keeps its priority slot, not the top of the list', () async {
      final p = await loaded();
      await p.addRule('c', 'shopping'); // ends at index 2
      await p.addRule('b', 'shopping'); // ends at index 1
      await p.addRule('a', 'food'); // index 0
      final ids = {p.rules[1].id, p.rules[2].id};

      await p.mergeRules(ids);
      // The unrelated food rule still out-ranks the merged shopping rule.
      expect(p.rules[0].pattern, 'a');
      expect(p.rules[1].patterns, ['b', 'c']);
    });

    test('mixed categories and single selections are no-ops', () async {
      final p = await loaded();
      await p.addRule('chai', 'food');
      await p.addRule('uber', 'transport');
      final before = [for (final r in p.rules) r.id];

      await p.mergeRules({p.rules[0].id, p.rules[1].id});
      expect([for (final r in p.rules) r.id], before);

      await p.mergeRules({p.rules[0].id});
      expect([for (final r in p.rules) r.id], before);
    });

    test('restoreRules puts back the exact pre-merge list', () async {
      final p = await loaded();
      await p.addRule('chai', 'food');
      await p.addRule('swiggy', 'food');
      final before = List.of(p.rules);

      await p.mergeRules({before[0].id, before[1].id});
      expect(p.rules.length, lessThan(before.length));

      await p.restoreRules(before);
      expect(
        [for (final r in p.rules) (r.id, r.pattern)],
        [for (final r in before) (r.id, r.pattern)],
      );
    });
  });

  group('account menu position', () {
    testWidgets('menu near the bottom edge does not move after opening', (
      tester,
    ) async {
      final p = await loaded();
      // Three cards put the last menu button in the bottom third of the
      // 600px test viewport, where the 8-item menu cannot fit below it.
      for (var i = 0; i < 3; i++) {
        await p.addAccount(name: 'Bank $i', type: AccountType.bank);
      }
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Account options').last);
      // One frame in: with the stock grow animation the menu used to render
      // below the button first, then get shoved upward as it grew. It must
      // now sit at its final position from the first frame.
      await tester.pump();
      final firstFrame = tester.getTopLeft(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Rename')), firstFrame);
    });

    testWidgets('closed accounts render under their own section header', (
      tester,
    ) async {
      final p = await loaded();
      await p.addAccount(name: 'HDFC', type: AccountType.bank);
      final rd = await p.addAccount(name: 'RD', type: AccountType.savings);
      await p.closeAccount(rd);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CLOSED ACCOUNTS'), findsOneWidget);
      expect(find.text('RD'), findsOneWidget);
      expect(find.text('HDFC'), findsOneWidget);
    });
  });
}
