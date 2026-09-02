import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('deleteTransactions / restoreTransactions', () {
    test('removes exactly the given ids; Undo restores and persists', () async {
      final p = FinanceProvider();
      await p.load();
      Future<String> add(String note, double amount) => p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: amount,
        note: note,
        date: DateTime(2026, 7, 1),
      );
      final a = await add('a', 100);
      final b = await add('b', 200);
      final c = await add('c', 300);

      final removed = await p.deleteTransactions({a, c});
      expect(removed.map((t) => t.id), unorderedEquals([a, c]));
      expect(p.transactions.single.id, b);

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.transactions, hasLength(1), reason: 'delete persisted');

      await p.restoreTransactions(removed);
      expect(p.transactions, hasLength(3));
      expect(p.totalExpense, 600);

      final p3 = FinanceProvider();
      await p3.load();
      expect(p3.transactions, hasLength(3), reason: 'restore persisted');
    });

    test('unknown ids are a quiet no-op', () async {
      final p = FinanceProvider();
      await p.load();
      expect(await p.deleteTransactions({'nope'}), isEmpty);
    });
  });

  group('discardAllPending', () {
    Tx row(String id, {bool pending = false, bool spam = false}) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 100,
      note: 'row $id',
      date: DateTime(2026, 7, 1),
      pending: pending,
      suspectedSpam: spam,
    );

    test('removes pending non-spam only; Undo returns them pending', () async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          row('confirmed').toJson(),
          row('p1', pending: true).toJson(),
          row('p2', pending: true).toJson(),
          row('s1', pending: true, spam: true).toJson(),
        ]),
      });
      final p = FinanceProvider();
      await p.load();

      final removed = await p.discardAllPending();
      expect(removed.map((t) => t.id), unorderedEquals(['p1', 'p2']));
      expect(removed.every((t) => t.pending), isTrue);
      // Spam stays queued, the confirmed row stays in the ledger.
      expect(p.pendingTransactions.single.id, 's1');
      expect(p.transactions.single.id, 'confirmed');

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.pendingTransactions.single.id, 's1', reason: 'persisted');

      await p.restoreTransactions(removed);
      expect(
        p.pendingTransactions.where((t) => !t.suspectedSpam),
        hasLength(2),
        reason: 'restored rows rejoin the review queue',
      );
    });

    test('empty queue returns empty without persisting', () async {
      final p = FinanceProvider();
      await p.load();
      expect(await p.discardAllPending(), isEmpty);
    });
  });

  group('collapsed sections', () {
    test('toggleSection flips and persists per section', () async {
      final s = SettingsProvider();
      await s.load();
      expect(s.isSectionCollapsed('upcoming'), isFalse);

      await s.toggleSection('upcoming');
      await s.toggleSection('pending_review');
      final s2 = SettingsProvider();
      await s2.load();
      expect(s2.isSectionCollapsed('upcoming'), isTrue);
      expect(s2.isSectionCollapsed('pending_review'), isTrue);
      expect(s2.isSectionCollapsed('spam_review'), isFalse);

      await s2.toggleSection('upcoming');
      expect(s2.isSectionCollapsed('upcoming'), isFalse);
    });

    test('legacy upcoming_collapsed_v1 migrates into the set', () async {
      SharedPreferences.setMockInitialValues({'upcoming_collapsed_v1': true});
      final s = SettingsProvider();
      await s.load();
      expect(s.isSectionCollapsed('upcoming'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('upcoming_collapsed_v1'), isNull);
      expect(
        prefs.getStringList('collapsed_sections_v1'),
        contains('upcoming'),
      );
    });
  });
}
