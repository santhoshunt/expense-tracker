import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/utils/format.dart';

/// Who owes you: people on split bills, the rules that keep them honest on
/// every write, the running balances, the settle and link actions, and the
/// backups that carry them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const arun = SplitShare(name: 'Arun', amount: 1000);
  const priya = SplitShare(name: 'Priya', amount: 1000);
  final sep = DateTime(2026, 9);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Tx row(FinanceProvider p, String id) => [
    ...p.transactions,
    ...p.pendingTransactions,
  ].firstWhere((t) => t.id == id);

  /// A ₹3,000 dinner split with Arun and Priya, ₹1,000 each.
  Future<String> dinner(
    FinanceProvider p, {
    DateTime? date,
    List<SplitShare> people = const [arun, priya],
    String categoryId = 'food',
    double amount = 3000,
  }) => p.addTransaction(
    type: TxType.expense,
    categoryId: categoryId,
    amount: amount,
    note: 'Dinner',
    date: date ?? DateTime(2026, 9, 1),
    people: people,
  );

  Future<String> repaid(
    FinanceProvider p,
    String from,
    double amount, {
    DateTime? date,
  }) => p.addTransaction(
    type: TxType.income,
    categoryId: kRepaidToMeCategoryId,
    amount: amount,
    note: '',
    date: date ?? DateTime(2026, 9, 10),
    repaidBy: from,
  );

  group('model', () {
    final base = Tx(
      id: 'a',
      type: TxType.expense,
      categoryId: 'food',
      amount: 3000,
      note: '',
      date: DateTime(2026, 9, 1),
    );

    test('JSON writes people and payer only when present', () {
      expect(base.toJson().containsKey('people'), isFalse);
      expect(base.toJson().containsKey('repaidBy'), isFalse);
      final split = base.copyWith(
        myShare: 1000,
        people: const [
          arun,
          SplitShare(name: 'Priya', amount: 1000, settled: true),
        ],
      );
      final back = Tx.fromJson(split.toJson());
      expect(back.people, split.people);
      expect(back.people.last.settled, isTrue);
      expect(split.toJson()['people'][0], {'name': 'Arun', 'amount': 1000.0});
    });

    test('broken people entries read as nothing', () {
      final json = base.toJson()
        ..['people'] = [
          {'name': 'Arun', 'amount': 500},
          {'name': 7, 'amount': 1},
          'Priya',
          {'amount': 3},
        ];
      expect(Tx.fromJson(json).people, [
        const SplitShare(name: 'Arun', amount: 500),
      ]);
      expect(Tx.fromJson(base.toJson()..['people'] = 'x').people, isEmpty);
    });

    test('the SMS body migration and copyWith keep both fields', () {
      final legacy = Tx(
        id: 'b',
        type: TxType.income,
        categoryId: kRepaidToMeCategoryId,
        amount: 500,
        note: 'Rs 500 credited',
        date: DateTime(2026, 9, 1),
        source: TxSource.sms,
        repaidBy: 'Arun',
      );
      expect(legacy.migrateSmsBodyFromNote().repaidBy, 'Arun');
      final split = base.copyWith(people: const [arun]);
      expect(split.migrateSmsBodyFromNote().people, [arun]);
      expect(split.copyWith(note: 'x').people, [arun]);
      expect(legacy.copyWith(clearRepaidBy: true).repaidBy, isNull);
    });

    test('names lose the CSV separators and get capped', () {
      expect(normalizePersonName('  Arun   K '), 'Arun K');
      expect(normalizePersonName('A|r:un'), 'A r un');
      expect(
        normalizePersonName('x' * 40).characters.length,
        kMaxPersonNameLength,
      );
    });

    test('an amount field never takes NaN or Infinity', () {
      // Split rows round what they parse; NaN would throw mid-build.
      expect(parseAmount('NaN'), isNull);
      expect(parseAmount('Infinity'), isNull);
      expect(parseAmount('1,500.50'), 1500.5);
    });

    test('Repaid to me is a money-in transfer', () {
      final c = categoryById(kRepaidToMeCategoryId);
      expect(c.type, TxType.income);
      expect(isTransferCategory(kRepaidToMeCategoryId), isTrue);
      expect(
        kCategories.last.id,
        'other_income',
        reason: 'fallback stays last',
      );
    });
  });

  group('the split rules on every write', () {
    test('people are the record: the share is what they leave', () async {
      final p = await loaded();
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 3000,
        note: '',
        date: DateTime(2026, 9, 1),
        myShare: 2500,
        people: const [arun, priya],
      );
      expect(row(p, id).myShare, 1000);
    });

    test('duplicates merge, blanks and non-positive amounts drop, 10 at '
        'most', () async {
      final p = await loaded();
      final id = await dinner(
        p,
        amount: 20000,
        people: [
          arun,
          const SplitShare(name: ' arun ', amount: 200),
          const SplitShare(name: '', amount: 300),
          const SplitShare(name: 'Zero', amount: 0),
          for (var i = 0; i < 12; i++) SplitShare(name: 'P$i', amount: 10),
        ],
      );
      final people = row(p, id).people;
      expect(people.first, const SplitShare(name: 'Arun', amount: 1200));
      expect(people, hasLength(kMaxSplitPeople));
      expect(people.any((s) => s.name == 'Zero' || s.name.isEmpty), isFalse);
    });

    test('an amount edited below what people owe drops them', () async {
      final p = await loaded();
      final id = await dinner(p);
      await p.updateTransaction(row(p, id).copyWith(amount: 1500));
      expect(row(p, id).people, isEmpty);
      expect(row(p, id).myShare, 1000, reason: 'the old share, clamped');
    });

    test('moving to income or a transfer clears the split', () async {
      final p = await loaded();
      final a = await dinner(p);
      await p.updateTransaction(
        row(p, a).copyWith(type: TxType.income, categoryId: 'salary'),
      );
      expect(row(p, a).people, isEmpty);
      expect(row(p, a).myShare, isNull);

      final b = await dinner(p);
      await p.updateTransaction(row(p, b).copyWith(categoryId: 'transfer_out'));
      expect(row(p, b).people, isEmpty);
      expect(row(p, b).myShare, isNull);
    });

    test('a bulk category change into a transfer clears it', () async {
      final p = await loaded();
      final id = await dinner(p);
      await p.setCategoryForMany({id}, kSavingsTransferCategoryId);
      expect(row(p, id).people, isEmpty);
      expect(row(p, id).myShare, isNull);
    });

    test('deleting a category into a transfer clears it', () async {
      final p = await loaded();
      final cat = await p.addCategory(
        label: 'Trips',
        type: TxType.expense,
        icon: Icons.flight,
        color: kNoCategoryColor,
      );
      final id = await dinner(p, categoryId: cat);
      await p.deleteCategory(cat, moveTo: kTransferOutCategoryId);
      expect(row(p, id).categoryId, kTransferOutCategoryId);
      expect(row(p, id).people, isEmpty);
    });

    test('pairing clears it', () async {
      final p = await loaded();
      final a = await dinner(p);
      final b = await p.addTransaction(
        type: TxType.income,
        categoryId: 'other_income',
        amount: 3000,
        note: '',
        date: DateTime(2026, 9, 1),
      );
      expect(await p.pairTransactions(a, b), isNotNull);
      expect(row(p, a).people, isEmpty);
    });

    test('a rule moving an SMS row into a transfer clears it', () async {
      final p = await loaded();
      await p.importTransactions([
        Tx(
          id: 'sms1',
          type: TxType.expense,
          categoryId: 'food',
          amount: 3000,
          note: '',
          smsBody: 'Rs 3000 paid to QWERTYCORP',
          date: DateTime(2026, 9, 1),
          source: TxSource.sms,
          people: const [arun],
        ),
      ], replace: false);
      expect(row(p, 'sms1').people, [arun]);
      await p.addRule('qwertycorp', kTransferOutCategoryId);
      expect(row(p, 'sms1').categoryId, kTransferOutCategoryId);
      expect(row(p, 'sms1').people, isEmpty);
    });

    test('flipping a category to income or a transfer clears it', () async {
      final p = await loaded();
      final cat = await p.addCategory(
        label: 'Trips',
        type: TxType.expense,
        icon: Icons.flight,
        color: kNoCategoryColor,
      );
      final a = await dinner(p, categoryId: cat);
      final def = customCategories.single;
      await p.updateCategory(
        TxCategory(
          id: def.id,
          label: def.label,
          icon: def.icon,
          color: def.color,
          type: TxType.expense,
          isTransfer: true,
        ),
      );
      expect(row(p, a).people, isEmpty, reason: 'transfer toggle');

      final b = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'shopping',
        amount: 900,
        note: '',
        date: DateTime(2026, 9, 2),
        people: const [SplitShare(name: 'Arun', amount: 300)],
      );
      await p.overrideBuiltinCategory(
        id: 'shopping',
        label: 'Shopping',
        icon: Icons.shopping_bag,
        color: kNoCategoryColor,
        type: TxType.income,
      );
      expect(row(p, b).type, TxType.income);
      expect(row(p, b).people, isEmpty, reason: 'direction flip');
    });

    test('Repaid to me keeps its direction and transfer flag', () async {
      final p = await loaded();
      await p.overrideBuiltinCategory(
        id: kRepaidToMeCategoryId,
        label: 'Paid back',
        icon: Icons.group,
        color: kNoCategoryColor,
        type: TxType.expense,
        isTransfer: false,
      );
      final c = categoryById(kRepaidToMeCategoryId);
      expect(c.label, 'Paid back');
      expect(c.type, TxType.income);
      expect(c.isTransfer, isTrue);
    });

    test('load clears stale shares left by older builds, once', () async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          {
            'id': 'old',
            'type': 'income',
            'categoryId': 'salary',
            'amount': 5000.0,
            'note': '',
            'date': '2026-09-01T00:00:00.000',
            'myShare': 100.0,
            'people': [
              {'name': 'Arun', 'amount': 50.0},
            ],
          },
        ]),
      });
      final p = await loaded();
      expect(row(p, 'old').myShare, isNull);
      expect(row(p, 'old').people, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('transactions_v1'), isNot(contains('myShare')));
    });

    test('imports and restores go through the same rules', () async {
      final p = await loaded();
      final csv = [
        'id,date,type,category,amount,myShare,people',
        'c1,2026-09-01T00:00:00.000,expense,food,3000.00,,'
            '"Arun:1000.00 | Priya:1000.00:settled"',
      ].join('\r\n');
      await p.importTransactions(BackupService.txsFromCsv(csv), replace: false);
      expect(row(p, 'c1').myShare, 1000, reason: 'derived from the people');
      expect(row(p, 'c1').people.last.settled, isTrue);

      await p.restoreTransaction(
        Tx(
          id: 'r1',
          type: TxType.income,
          categoryId: 'salary',
          amount: 100,
          note: '',
          date: DateTime(2026, 9, 1),
          myShare: 10,
          people: const [arun],
          repaidBy: 'Arun',
        ),
      );
      expect(row(p, 'r1').people, isEmpty);
      expect(row(p, 'r1').myShare, isNull);
      expect(row(p, 'r1').repaidBy, isNull, reason: 'not a repayment');
    });
  });

  group('balances', () {
    test('repayments pay off the oldest bills first, partly too', () async {
      final p = await loaded();
      final first = await dinner(p, people: const [arun]);
      final second = await dinner(
        p,
        date: DateTime(2026, 9, 5),
        people: const [SplitShare(name: 'Arun', amount: 500)],
      );
      await repaid(p, 'Arun', 1200);
      final b = p.peopleBalances.single;
      expect(b.owed, 300);
      expect(b.credit, 0);
      expect(b.open.single.bill.id, second);
      expect(b.open.single.left, 300);
      expect(b.settled.single.bill.id, first);
      expect(p.billOwed(first), 0);
      expect(p.billOwed(second), 300);
      expect(p.totalOwed, 300);
    });

    test('paying more than owed is credit', () async {
      final p = await loaded();
      await dinner(p, people: const [arun]);
      await repaid(p, 'arun', 1500);
      final b = p.peopleBalances.single;
      expect(b.owed, 0);
      expect(b.credit, 500);
      expect(b.name, 'arun', reason: 'the newest spelling names them');
    });

    test(
      'names match ignoring case; the biggest balance comes first',
      () async {
        final p = await loaded();
        await dinner(
          p,
          people: const [
            SplitShare(name: 'arun', amount: 400),
            SplitShare(name: 'Priya', amount: 900),
          ],
        );
        await repaid(p, 'ARUN', 100);
        expect(
          [for (final b in p.peopleBalances) (b.name, b.owed)],
          [('Priya', 900.0), ('ARUN', 300.0)],
        );
        // Most recent first: Arun's repayment is the newest row.
        expect(p.knownPeople, ['ARUN', 'Priya']);
      },
    );

    test(
      'pending bills and splits without names count toward nobody',
      () async {
        final p = await loaded();
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 900,
          note: '',
          date: DateTime(2026, 9, 1),
          myShare: 300,
        );
        await p.importTransactions([
          Tx(
            id: 'pend',
            type: TxType.expense,
            categoryId: 'food',
            amount: 3000,
            note: '',
            date: DateTime(2026, 9, 2),
            source: TxSource.sms,
            pending: true,
            people: const [arun],
          ),
        ], replace: false);
        expect(p.peopleBalances, isEmpty);
        expect(p.totalOwed, 0);
        await p.confirmTransaction('pend');
        expect(p.totalOwed, 1000);
      },
    );

    test('a repayment is a transfer in: income and spend stay put', () async {
      final p = await loaded();
      await dinner(p);
      expect(p.expenseInMonth(sep), 1000);
      await repaid(p, 'Arun', 1000, date: DateTime(2026, 9, 3));
      expect(p.incomeInMonth(sep), 0);
      expect(p.expenseInMonth(sep), 1000);
      expect(p.transferInInMonth(sep), 1000);
    });
  });

  group('actions', () {
    test('settling a part-paid bill keeps its repayment spent on it', () async {
      final p = await loaded();
      final first = await dinner(p, people: const [arun]);
      await repaid(p, 'Arun', 400, date: DateTime(2026, 9, 2));
      await p.settleShares('Arun', billId: first);
      expect(row(p, first).people.single.paid, 400);
      expect(p.peopleBalances.single.credit, 0, reason: 'not freed');

      // So the next bill is owed in full.
      await dinner(
        p,
        date: DateTime(2026, 9, 5),
        people: const [SplitShare(name: 'Arun', amount: 500)],
      );
      expect(p.totalOwed, 500);

      // And the paid part survives a CSV round trip.
      final back = BackupService.txsFromCsv(BackupService.buildCsv(p));
      expect(
        back.firstWhere((t) => t.id == first).people.single,
        const SplitShare(name: 'Arun', amount: 1000, settled: true, paid: 400),
      );
    });

    test('linking refuses rows that cannot be a repayment', () async {
      final p = await loaded();
      final card = await p.addTransaction(
        type: TxType.income,
        categoryId: kCardPaymentCategoryId,
        amount: 500,
        note: '',
        date: DateTime(2026, 9, 3),
      );
      final already = await repaid(p, 'Priya', 500);
      expect(await p.linkRepayment(card, 'Arun'), isNull);
      expect(await p.linkRepayment(already, 'Arun'), isNull);
      expect(row(p, already).repaidBy, 'Priya');
    });

    test('mark settled, one bill or all, with Undo', () async {
      final p = await loaded();
      final first = await dinner(p, people: const [arun]);
      await dinner(
        p,
        date: DateTime(2026, 9, 5),
        people: const [SplitShare(name: 'Arun', amount: 500)],
      );
      final one = await p.settleShares('arun', billId: first);
      expect(one, hasLength(1));
      expect(p.totalOwed, 500);
      expect(row(p, first).people.single.settled, isTrue);

      final all = await p.settleShares('Arun');
      expect(p.totalOwed, 0);
      await p.restoreEditedTransactions(all);
      await p.restoreEditedTransactions(one);
      expect(p.totalOwed, 1500);
    });

    test('link a received payment, with Undo', () async {
      final p = await loaded();
      await dinner(p, people: const [arun]);
      final gift = await p.addTransaction(
        type: TxType.income,
        categoryId: 'gift',
        amount: 1000,
        note: 'UPI from Arun',
        date: DateTime(2026, 9, 4),
      );
      final before = await p.linkRepayment(gift, ' Arun ');
      expect(before!.categoryId, 'gift');
      expect(row(p, gift).categoryId, kRepaidToMeCategoryId);
      expect(row(p, gift).repaidBy, 'Arun');
      expect(p.totalOwed, 0);
      expect(p.incomeInMonth(sep), 0, reason: 'no longer income');

      await p.restoreEditedTransactions([before]);
      expect(row(p, gift).categoryId, 'gift');
      expect(row(p, gift).repaidBy, isNull);
      expect(p.totalOwed, 1000);
    });

    test('the link picker never offers a pair leg, a card payment or a '
        'repayment', () async {
      final p = await loaded();
      final now = DateTime(2026, 9, 26);
      Future<String> money(String cat, double amount, {DateTime? date}) =>
          p.addTransaction(
            type: TxType.income,
            categoryId: cat,
            amount: amount,
            note: '',
            date: date ?? DateTime(2026, 9, 20),
          );
      final gift = await money('gift', 900);
      final transferIn = await money(kTransferInCategoryId, 1000);
      await money(kCardPaymentCategoryId, 1000);
      await repaid(p, 'Arun', 1000);
      await money('gift', 1000, date: DateTime(2026, 5, 1));
      final pairedIn = await money(kTransferInCategoryId, 1000);
      final out = await p.addTransaction(
        type: TxType.expense,
        categoryId: kTransferOutCategoryId,
        amount: 1000,
        note: '',
        date: DateTime(2026, 9, 20),
      );
      await p.pairTransactions(out, pairedIn);

      final offered = p.repaymentCandidates(near: 1000, now: now);
      expect([for (final t in offered) t.id], [transferIn, gift]);
      expect(await p.linkRepayment(pairedIn, 'Arun'), isNull);
    });
  });

  group('backups', () {
    test('CSV round trip keeps people and payer', () async {
      final p = await loaded();
      final bill = await dinner(
        p,
        people: const [
          arun,
          SplitShare(name: 'Priya', amount: 1000, settled: true),
        ],
      );
      final back = await repaid(p, 'Arun', 400);
      final csv = BackupService.buildCsv(p);
      expect(csv.split('\r\n').first, endsWith(',tags,people,repaidBy'));
      final rows = {for (final t in BackupService.txsFromCsv(csv)) t.id: t};
      expect(rows[bill]!.people, row(p, bill).people);
      expect(rows[back]!.repaidBy, 'Arun');
    });

    test('JSON backup is v15 and restores people and payer', () async {
      final p = await loaded();
      final bill = await dinner(p);
      await repaid(p, 'Priya', 500);
      final data = p.exportData();
      expect(data['version'], 15);

      final fresh = await loaded();
      await fresh.importData(
        jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
        replace: true,
      );
      expect(row(fresh, bill).people, [arun, priya]);
      expect(fresh.totalOwed, 1500);
    });
  });
}
