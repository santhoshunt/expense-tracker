import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/import_rule.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// Behaviour pinned by the performance rework: the indexed SMS dedup must
/// decide exactly like the old whole-ledger scan, the month-bucketed totals
/// must match hand-computed figures, and the undo restore methods must
/// round-trip deletions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  ParsedTxn parsed({
    required TxType type,
    required double amount,
    required DateTime date,
    String? ref,
    String sender = 'XX-TEST-S',
  }) => ParsedTxn(
    type: type,
    amount: amount,
    // 'zzqq' matches no seeded classifier/spam rule.
    merchant: 'zzqq',
    date: date,
    ref: ref,
    categoryId: type == TxType.income ? 'other_income' : 'other_expense',
    sender: sender,
  );

  group('addImported dedup (indexed) decides like the old linear scan', () {
    final t0 = DateTime(2026, 7, 10, 12, 0);

    test('ref matches block same ref+direction only', () async {
      final p = FinanceProvider();
      await p.load();
      final (seeded, _) = await p.addImported([
        parsed(type: TxType.income, amount: 100, date: t0, ref: 'R1'),
      ]);
      expect(seeded, 1);

      // Same ref + same direction → duplicate; same ref + other direction is
      // the other leg of a bill payment and must import.
      final (added, _) = await p.addImported([
        parsed(type: TxType.income, amount: 100, date: t0, ref: 'R1'),
        parsed(type: TxType.expense, amount: 100, date: t0, ref: 'R1'),
      ]);
      expect(added, 1);
      expect(p.transactionCount, 2);
    });

    test('ref-less fuzzy: type + amount + sender within 3 minutes', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        parsed(type: TxType.expense, amount: 500, date: t0, sender: 'INDBNK'),
      ]);

      final (added, _) = await p.addImported([
        // 2 min away, same everything → duplicate.
        parsed(
          type: TxType.expense,
          amount: 500,
          date: t0.add(const Duration(minutes: 2)),
          sender: 'INDBNK',
        ),
        // Exactly 3 min away → still a duplicate (inclusive window).
        parsed(
          type: TxType.expense,
          amount: 500,
          date: t0.add(const Duration(minutes: 3)),
          sender: 'INDBNK',
        ),
        // 10 min away → new.
        parsed(
          type: TxType.expense,
          amount: 500,
          date: t0.add(const Duration(minutes: 10)),
          sender: 'INDBNK',
        ),
        // Same time, different bank → new (no cross-bank collisions).
        parsed(
          type: TxType.expense,
          amount: 500,
          date: t0.add(const Duration(minutes: 1)),
          sender: 'HDFCBK',
        ),
      ]);
      expect(added, 2);
    });

    test('a row carrying a ref still fuzzy-blocks a ref-less copy', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        parsed(type: TxType.income, amount: 100, date: t0, ref: 'R9'),
      ]);
      final (added, _) = await p.addImported([
        parsed(
          type: TxType.income,
          amount: 100,
          date: t0.add(const Duration(minutes: 1)),
        ),
      ]);
      expect(added, 0);
    });

    test('rows added earlier in the same batch block later ones', () async {
      final p = FinanceProvider();
      await p.load();
      final (added, _) = await p.addImported([
        parsed(type: TxType.expense, amount: 777, date: t0),
        parsed(type: TxType.expense, amount: 777, date: t0),
        parsed(type: TxType.income, amount: 5, date: t0, ref: 'B1'),
        parsed(type: TxType.income, amount: 5, date: t0, ref: 'B1'),
      ]);
      expect(added, 2);
    });
  });

  group('month-bucketed totals', () {
    test('per-month and all-time figures match hand computation', () async {
      final p = FinanceProvider();
      await p.load();
      Future<void> add(TxType type, String cat, double amt, DateTime d) =>
          p.addTransaction(
            type: type,
            categoryId: cat,
            amount: amt,
            note: '',
            date: d,
          );

      final jul = DateTime(2026, 7);
      final aug = DateTime(2026, 8);
      await add(TxType.income, 'other_income', 1000, DateTime(2026, 7, 1));
      await add(TxType.expense, 'food', 250, DateTime(2026, 7, 10));
      await add(TxType.expense, 'transport', 100, DateTime(2026, 7, 20));
      // Transfer to savings: excluded from expense, tracked separately.
      await add(TxType.expense, 'savings_out', 500, DateTime(2026, 7, 15));
      await add(TxType.expense, 'food', 40, DateTime(2026, 8, 2));

      expect(p.incomeInMonth(jul), 1000);
      expect(p.expenseInMonth(jul), 350);
      expect(p.savingsTransfersInMonth(jul), 500);
      expect(p.transferOutInMonth(jul), 500);
      expect(p.incomeInMonth(aug), 0);
      expect(p.expenseInMonth(aug), 40);
      // Untouched months read zero, not garbage.
      expect(p.expenseInMonth(DateTime(2026, 6)), 0);

      final julByCat = p.expenseByCategory(jul);
      expect(julByCat.map((e) => e.key.id).toList(), ['food', 'transport']);
      expect(julByCat.first.value, 250);

      expect(p.totalIncome, 1000);
      expect(p.totalExpense, 390);
      // balance = income − expense − savings transfers.
      expect(p.balance, 110);
    });
  });

  group('undo restores', () {
    test('restoreTransaction round-trips a delete and persists', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'lunch',
        date: DateTime(2026, 7, 5),
      );
      final tx = p.transactions.single;
      await p.deleteTransaction(tx.id);
      expect(p.transactions, isEmpty);

      await p.restoreTransaction(tx);
      final back = p.transactions.single;
      expect(back.id, tx.id);
      expect(back.note, 'lunch');
      expect(back.amount, 120);

      // Restoring twice must not duplicate.
      await p.restoreTransaction(tx);
      expect(p.transactions.length, 1);

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.transactions.single.id, tx.id);
    });

    test('restoreRule puts the rule back at its old priority slot', () async {
      final p = FinanceProvider();
      await p.load();
      // insert(0) each time → order: ccc, bbb, aaa, …seeded.
      await p.addRule('aaa', 'food');
      await p.addRule('bbb', 'transport');
      await p.addRule('ccc', 'shopping');
      expect(p.rules[1].pattern, 'bbb');

      final rule = p.rules[1];
      await p.deleteRule(rule.id);
      expect(p.rules[1].pattern, 'aaa');

      await p.restoreRule(rule, 1);
      expect(p.rules[0].pattern, 'ccc');
      expect(p.rules[1].pattern, 'bbb');
      expect(p.rules[2].pattern, 'aaa');

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.rules[1].pattern, 'bbb');
    });

    test('restoreImportRule round-trips with position', () async {
      final p = FinanceProvider();
      await p.load();
      final before = p.importRules.length;
      await p.addImportRule('zz promo zz', ImportRuleKind.ignore);
      final rule = p.importRules.first;
      await p.deleteImportRule(rule.id);
      expect(p.importRules.length, before);
      await p.restoreImportRule(rule, 0);
      expect(p.importRules.first.pattern, 'zz promo zz');
    });
  });
}
