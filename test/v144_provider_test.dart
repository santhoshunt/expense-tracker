import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/budget_monitor.dart';
import 'package:expense_tracker/services/card_rewards.dart';
import 'package:expense_tracker/services/category_guess.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/refund_matching.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/transfer_pairing.dart';
import 'package:expense_tracker/services/unusual_spend.dart';

class _Notifications implements NotificationService {
  final shown = <String>[];

  @override
  Future<void> init() async {}

  @override
  Future<bool> get areEnabled async => true;

  @override
  Future<NotificationStatus> get status async => NotificationStatus.enabled;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async => shown.add(title);

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<void> scheduleRecap(DateTime when, String monthName) async {}

  @override
  Future<void> cancelRecap() async {}

  @override
  Future<void> scheduleWeeklyDigest(
    DateTime when,
    DateTime week,
    String weekLabel,
  ) async {}

  @override
  Future<void> cancelWeeklyDigest() async {}

  @override
  Future<void> showReview(int count) async {}

  @override
  Future<void> cancelReview() async {}

  @override
  Future<void> showImportCheck({
    required int id,
    required String title,
    required String body,
    required String payload,
    String? keepLabel,
  }) async {}

  @override
  Future<void> showImportCheckSummary(int count) async {}

  @override
  Future<List<int>> activeImportChecks() async => const [];

  @override
  Future<void> cancelId(int id) async {}
}

/// Count-first imports, category guesses and category splits in the
/// provider. Every name, number and text is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  const bank = 'HDFC:1234';

  ParsedTxn alert({
    TxType type = TxType.expense,
    double amount = 250,
    required DateTime date,
    String? ref,
    String categoryId = 'other_expense',
    required String rawBody,
    String sender = 'VM-HDFCBK',
    String? acctKey = bank,
    double? balance,
    bool spamSuspect = false,
  }) => ParsedTxn(
    type: type,
    amount: amount,
    merchant: '',
    date: date,
    ref: ref,
    categoryId: categoryId,
    sender: sender,
    rawBody: rawBody,
    acctKey: acctKey,
    balanceAfter: balance,
    spamSuspect: spamSuspect,
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  /// [bank] with one confirmed Food row from Kettle Nook.
  Future<FinanceProvider> withHistory() async {
    final p = await loaded();
    await p.addImported([
      alert(
        amount: 450,
        date: DateTime(2026, 7, 1, 9),
        ref: 'SEED',
        categoryId: 'food',
        rawBody: 'Rs.450 debited at KETTLE NOOK',
      ),
    ]);
    await p.confirmAllPending();
    return p;
  }

  Tx byRef(FinanceProvider p, String ref) => [
    ...p.transactions,
    ...p.pendingTransactions,
  ].firstWhere((t) => t.externalRef == ref);

  Tx byId(FinanceProvider p, String id) =>
      p.transactions.firstWhere((t) => t.id == id);

  group('CategoryGuesser', () {
    Tx row(
      String id,
      String payee,
      String categoryId, {
      bool unseen = false,
      bool guessed = false,
      bool pending = false,
    }) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: categoryId,
      amount: 100,
      note: '',
      date: DateTime(2026, 7, 1),
      payee: payee,
      unseen: unseen,
      categoryGuessed: guessed,
      pending: pending,
    );

    Tx probe(String payee) => row('probe', payee, 'other_expense');

    test('a merchant always filed one way gives that category', () {
      final g = CategoryGuesser.from([
        row('a', 'Kettle Nook', 'food'),
        row('b', 'Kettle Nook', 'food'),
      ]);
      expect(g.guess(probe('Kettle Nook')), 'food');
    });

    test('words vote, and a clear winner is the guess', () {
      final g = CategoryGuesser.from([
        row('a', 'Blue Leaf Cafe', 'food'),
        row('b', 'Blue Leaf Diner', 'food'),
        row('c', 'Copper Lane Store', 'shopping'),
      ]);
      expect(g.guess(probe('Blue Leaf Bakery')), 'food');
    });

    test('one vote, or a split vote, is no guess', () {
      final thin = CategoryGuesser.from([row('a', 'Green Mart', 'shopping')]);
      expect(thin.guess(probe('Green Tower')), isNull);
      final split = CategoryGuesser.from([
        row('a', 'Ridge Plaza', 'food'),
        row('b', 'Ridge Plaza Two', 'shopping'),
        row('c', 'Ridge Hall', 'food'),
        row('d', 'Ridge Court', 'shopping'),
      ]);
      expect(split.guess(probe('Ridge Arcade')), isNull);
    });

    test('guessed, new, pending, Other and To sort rows teach nothing', () {
      final g = CategoryGuesser.from([
        row('a', 'Kettle Nook', 'food', guessed: true),
        row('b', 'Kettle Nook', 'food', unseen: true),
        row('c', 'Kettle Nook', 'food', pending: true),
        row('d', 'Kettle Nook', 'other_expense'),
        row('e', 'Kettle Nook', kToSortExpenseId),
      ]);
      expect(g.guess(probe('Kettle Nook')), isNull);
    });

    test('stop words and numbers cast no vote', () {
      expect(
        CategoryGuesser.wordsOf(probe('UPI Payment 4411 Lotus Bank Dhaba')),
        {'lotus', 'dhaba'},
      );
    });
  });

  group('count-first import', () {
    test('a guess counts, marked guessed, and stays out of alerts until '
        'kept', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.300 debited at KETTLE NOOK',
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isFalse);
      expect(t.categoryId, 'food');
      expect(t.categoryGuessed, isTrue);
      final july = DateTime(2026, 7);
      expect(p.expenseInMonth(july), 750);
      expect(p.guessedSpendInMonth(july), 300);
      expect(p.guessedSpendIn(july, 'food'), 300);
      expect(p.guessedSpendIn(july, 'shopping'), 0);
      const budget = SpendBudget(
        id: 'b1',
        name: 'Eating',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      expect(p.guessedSpendFor(budget, july), 300);

      await p.confirmGuess(t.id);
      final kept = byRef(p, 'A');
      expect(kept.categoryGuessed, isFalse);
      expect(kept.userCategorized, isTrue);
      expect(p.guessedSpendInMonth(july), 0);
    });

    test('changing a guessed category clears the guess', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.300 debited at KETTLE NOOK',
        ),
      ]);
      await p.updateTransaction(byRef(p, 'A').copyWith(categoryId: 'shopping'));
      expect(byRef(p, 'A').categoryGuessed, isFalse);
    });

    test('an unknown account waits, placed; pendingAmount leaves spam '
        'out', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 700,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.700 debited at PEBBLE MART',
          acctKey: 'ICICI:9999',
        ),
        alert(
          amount: 90,
          date: DateTime(2026, 7, 6, 13),
          ref: 'B',
          rawBody: 'Rs.90 debited at WIN A PRIZE',
          spamSuspect: true,
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isTrue);
      expect(t.categoryId, kToSortExpenseId);
      expect(p.pendingAmount, 700);
    });

    test('an unplaced credit counts as To sort income', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          type: TxType.income,
          amount: 800,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          categoryId: 'other_income',
          rawBody: 'Rs.800 credited from QUILL WORKS',
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isFalse);
      expect(t.categoryId, kToSortIncomeId);
    });

    test('a later rule fills To sort and guessed rows', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.300 debited at KETTLE NOOK',
        ),
        alert(
          amount: 200,
          date: DateTime(2026, 7, 6, 13),
          ref: 'B',
          rawBody: 'Rs.200 debited at PEBBLE MART',
        ),
      ]);
      await p.addRule('kettle nook', 'food');
      await p.addRule('pebble mart', 'shopping');
      expect(byRef(p, 'A').categoryGuessed, isFalse);
      expect(byRef(p, 'A').categoryId, 'food');
      expect(byRef(p, 'B').categoryId, 'shopping');
    });

    test('a spam rule drops a new To sort row, not a seen one', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 200,
          date: DateTime(2026, 7, 6, 13),
          ref: 'B',
          rawBody: 'Rs.200 debited at PEBBLE MART',
        ),
      ]);
      expect(p.pendingSpamDropsFor('pebble mart', kSpamCategoryId), 1);
      await p.markAllSeen();
      // Seen: To sort alone does not make it unreviewed.
      expect(p.pendingSpamDropsFor('pebble mart', kSpamCategoryId), 0);
      final r = await p.addRule('pebble mart', kSpamCategoryId);
      expect(r.droppedPending, 0);
      expect(p.transactions.any((t) => t.externalRef == 'B'), isTrue);
    });

    test('confirming a guessed row in review keeps the guess', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.300 debited at KETTLE NOOK',
          acctKey: 'ICICI:9999',
        ),
        alert(
          amount: 310,
          date: DateTime(2026, 7, 6, 13),
          ref: 'B',
          rawBody: 'Rs.310 debited at KETTLE NOOK',
          acctKey: 'ICICI:9999',
        ),
      ]);
      expect(byRef(p, 'A').pending, isTrue);
      expect(byRef(p, 'A').categoryGuessed, isTrue);
      await p.confirmTransaction(byRef(p, 'A').id);
      expect(byRef(p, 'A').categoryGuessed, isFalse);
      expect(byRef(p, 'A').userCategorized, isTrue);
      final before = await p.confirmAllPending();
      expect(byRef(p, 'B').categoryGuessed, isFalse);
      expect(byRef(p, 'B').userCategorized, isTrue);
      // Undo puts the guess back with the row.
      await p.restoreEditedTransactions(before);
      expect(byRef(p, 'B').categoryGuessed, isTrue);
    });

    test('budget alerts wait for a guess to be kept', () async {
      final notifications = _Notifications();
      final monitor = BudgetMonitor(notifications: notifications);
      final p = await loaded();
      final settings = SettingsProvider();
      await settings.load();
      await settings.setMonthlyBudget(1000);
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 950,
        note: 'test lunch',
        date: DateTime.now().add(const Duration(milliseconds: 200)),
      );
      await p.updateTransaction(byId(p, id).copyWith(categoryGuessed: true));
      expect(byId(p, id).categoryGuessed, isTrue);
      await monitor.check(p, settings);
      expect(notifications.shown, isEmpty);

      await p.confirmGuess(id);
      await monitor.check(p, settings);
      expect(notifications.shown, isNotEmpty);
    });

    test(
      'unusual spending waits for a guess and never names To sort',
      () async {
        final now = DateTime(2025, 12, 20, 10);
        final p = await loaded();
        Future<String> add(String category, double amount, DateTime date) =>
            p.addTransaction(
              type: TxType.expense,
              categoryId: category,
              amount: amount,
              note: 'test $category',
              date: date,
            );
        for (var m = 7; m <= 11; m++) {
          await add('food', 4000, DateTime(2025, m, 5));
          await add(kToSortExpenseId, 100, DateTime(2025, m, 6));
        }
        final dec = await add('food', 6000, DateTime(2025, 12, 3));
        await add(kToSortExpenseId, 5000, DateTime(2025, 12, 4));
        await p.updateTransaction(byId(p, dec).copyWith(categoryGuessed: true));
        expect(unusualCategories(p, now: now), isEmpty);

        await p.confirmGuess(dec);
        expect(
          [for (final c in unusualCategories(p, now: now)) c.id],
          ['food'],
        );
      },
    );

    test('the load pass runs once under its own key', () async {
      final rows = [
        Tx(
          id: 'seed',
          type: TxType.expense,
          categoryId: 'food',
          amount: 450,
          note: '',
          smsBody: 'Rs.450 debited at KETTLE NOOK',
          date: DateTime(2026, 7, 1, 9),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: bank,
        ),
        Tx(
          id: 'old',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 120,
          note: '',
          smsBody: 'Rs.120 debited at KETTLE NOOK',
          date: DateTime(2026, 7, 4, 9),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: bank,
          pending: true,
        ),
      ];
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
        'accounts_v1': jsonEncode([
          Account(
            id: 'acc1',
            name: 'Bank',
            type: AccountType.bank,
            keys: {bank},
          ).toJson(),
        ]),
        'imports_auto_counted_v1': true,
        'reminders_v1': jsonEncode([
          const Reminder(
            id: 'snack',
            name: 'Snack box',
            dayOfMonth: 4,
            categoryId: 'food',
            expectedAmount: 120,
          ).toJson(),
        ]),
      });
      final p = await loaded();
      final old = byId(p, 'old');
      expect(old.pending, isFalse);
      expect(old.unseen, isTrue);
      expect(old.categoryId, 'food');
      expect(old.categoryGuessed, isTrue);
      // A row the pass counts pays its reminder, and that is saved.
      expect(p.reminders.single.lastPaidMonth, '2026-07');
      expect((await loaded()).reminders.single.lastPaidMonth, '2026-07');
    });
  });

  group('category splits', () {
    /// A counted ₹5,000 alert stating a ₹20,000 balance after it.
    Future<(FinanceProvider, Tx)> payment() async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 5000,
          date: DateTime(2026, 7, 5, 13),
          ref: 'PAY',
          rawBody: 'Rs.5000 debited at PEBBLE MART',
          balance: 20000,
        ),
      ]);
      return (p, byRef(p, 'PAY'));
    }

    const three = [
      (categoryId: 'food', amount: 1000.0),
      (categoryId: 'shopping', amount: 2000.0),
      (categoryId: kPaidForOthersCategoryId, amount: 2000.0),
    ];

    test(
      'splits into linked rows; totals, balance and the alert hold',
      () async {
        final (p, row) = await payment();
        final acc = p.accountForKey(bank)!;
        expect(p.accountBalance(acc), 20000);
        expect(p.canSplit(row), isTrue);

        final change = await p.splitTransaction(row.id, three);
        expect(change.before.single.id, row.id);
        expect(change.afterIds.first, row.id);
        expect(change.afterIds.length, 3);

        final anchor = byId(p, row.id);
        expect(anchor.categoryId, 'food');
        expect(anchor.amount, 1000);
        expect(anchor.smsBody, row.smsBody);
        expect(anchor.externalRef, 'PAY');
        expect(anchor.balanceAfter, 20000);
        expect(anchor.userCategorized, isTrue);
        final parts = p.splitPartsOf(anchor);
        expect([for (final t in parts) t.id], change.afterIds);
        for (final t in parts.skip(1)) {
          expect(t.splitId, anchor.splitId);
          expect(t.source, TxSource.manual);
          expect(t.sender, isEmpty);
          expect(t.smsBody, isEmpty);
          expect(t.acctKey, bank);
          expect(t.date, anchor.date);
          expect(t.payee, 'Pebble Mart');
          expect(p.isSplitPart(t), isTrue);
          expect(p.splitTotalOf(t), 5000);
        }

        final july = DateTime(2026, 7);
        expect(p.expenseInMonth(july), 450 + 1000 + 2000);
        expect(p.transferOutInMonth(july), 2000);
        // The alert's balance already holds the whole payment.
        expect(p.accountBalance(p.accountForKey(bank)!), 20000);
      },
    );

    test('refuses parts that do not add up or are not money out', () async {
      final (p, row) = await payment();
      Future<SplitChange> split(List<({String categoryId, double amount})> x) =>
          p.splitTransaction(row.id, x);
      expect(
        () => split(const [
          (categoryId: 'food', amount: 1000),
          (categoryId: 'shopping', amount: 3999.99),
        ]),
        throwsArgumentError,
      );
      expect(
        () => split(const [(categoryId: 'food', amount: 5000)]),
        throwsArgumentError,
      );
      expect(
        () => split(const [
          (categoryId: 'food', amount: 1000),
          (categoryId: kToSortExpenseId, amount: 4000),
        ]),
        throwsArgumentError,
      );
      expect(
        () => split(const [
          (categoryId: 'food', amount: 1000),
          (categoryId: 'salary', amount: 4000),
        ]),
        throwsArgumentError,
      );
      expect(
        () => split(const [
          (categoryId: 'food', amount: 5000),
          (categoryId: 'shopping', amount: 0),
        ]),
        throwsArgumentError,
      );
      expect(byId(p, row.id).splitId, isNull);
    });

    test('canSplit says no to pending, paired and shared rows', () {
      final p = FinanceProvider();
      Tx t({
        TxType type = TxType.expense,
        bool pending = false,
        String? pairId,
        double? myShare,
      }) => Tx(
        id: 'x',
        type: type,
        categoryId: type == TxType.expense ? 'food' : 'salary',
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 1),
        pending: pending,
        pairId: pairId,
        myShare: myShare,
      );
      expect(p.canSplit(t()), isTrue);
      expect(p.canSplit(t(type: TxType.income)), isTrue);
      expect(p.canSplit(t(pending: true)), isFalse);
      expect(p.canSplit(t(pairId: 'pair_1')), isFalse);
      expect(p.canSplit(t(myShare: 40)), isFalse);
    });

    test(
      'a re-split reuses rows in order; Undo puts the old parts back',
      () async {
        final (p, row) = await payment();
        final first = await p.splitTransaction(row.id, three);
        final change = await p.splitTransaction(first.afterIds[2], const [
          (categoryId: 'health', amount: 4500),
          (categoryId: 'food', amount: 500),
        ]);
        expect(change.afterIds, first.afterIds.take(2).toList());
        expect(p.transactions.any((t) => t.id == first.afterIds[2]), isFalse);
        expect(byId(p, row.id).categoryId, 'health');

        await p.undoSplitChange(change);
        final back = p.splitPartsOf(byId(p, row.id));
        expect([for (final t in back) t.id], first.afterIds);
        expect([for (final t in back) t.amount], [1000, 2000, 2000]);
      },
    );

    test('Undo of a first split leaves one row as it was', () async {
      final (p, row) = await payment();
      final change = await p.splitTransaction(row.id, three);
      await p.undoSplitChange(change);
      final again = byId(p, row.id);
      expect(again.splitId, isNull);
      expect(again.amount, 5000);
      expect(again.categoryId, row.categoryId);
      expect(p.transactions.length, 2);
    });

    test('merging gives the anchor the total; Undo splits again', () async {
      final (p, row) = await payment();
      final split = await p.splitTransaction(row.id, three);
      final sid = byId(p, row.id).splitId!;
      final merge = await p.mergeSplit(sid);
      expect(merge.afterIds, [row.id]);
      final merged = byId(p, row.id);
      expect(merged.amount, 5000);
      expect(merged.categoryId, 'food');
      expect(merged.splitId, isNull);
      expect(p.transactions.length, 2);

      await p.undoSplitChange(merge);
      expect([
        for (final t in p.splitPartsOf(byId(p, row.id))) t.id,
      ], split.afterIds);
    });

    test('deleting one part deletes the payment; restore brings it all '
        'back', () async {
      final (p, row) = await payment();
      final split = await p.splitTransaction(row.id, three);
      final part = byId(p, split.afterIds[1]);
      expect(await p.deleteTransaction(part.id), isNull);
      expect(p.transactions.length, 1);

      // A rescan of the alert does not bring the payment back.
      final (added, _, _) = await p.addImported([
        alert(
          amount: 5000,
          date: DateTime(2026, 7, 5, 13),
          ref: 'PAY',
          rawBody: 'Rs.5000 debited at PEBBLE MART',
          balance: 20000,
        ),
      ]);
      expect(added, 0);
    });

    test(
      'bulk delete of a part takes the group; restore re-links it',
      () async {
        final (p, row) = await payment();
        final split = await p.splitTransaction(row.id, three);
        final removed = await p.deleteTransactions([split.afterIds[2]]);
        expect(removed.length, 3);
        await p.restoreTransactions(removed);
        final parts = p.splitPartsOf(byId(p, row.id));
        expect([for (final t in parts) t.id], split.afterIds);
      },
    );

    test(
      'a deleted notification copy stays gone at the payment total',
      () async {
        final p = await withHistory();
        final at = DateTime(2026, 7, 5, 13);
        await p.addImported([
          alert(
            amount: 5000,
            date: at,
            rawBody: 'Rs.5000 spent at PEBBLE MART',
            sender: 'HDFC Bank',
          ),
        ]);
        final row = p.transactions.firstWhere((t) => t.amount == 5000);
        final split = await p.splitTransaction(row.id, three);
        await p.deleteTransactions([split.afterIds[1]]);
        // Another copy of the same alert, worded differently.
        final (added, _, _) = await p.addImported([
          alert(
            amount: 5000,
            date: at.add(const Duration(seconds: 20)),
            rawBody: 'Rs.5000 spent on card at PEBBLE MART',
            sender: 'HDFC Bank',
          ),
        ]);
        expect(added, 0);
      },
    );

    test('a rescan copy after a split is a duplicate at the total', () async {
      final (p, row) = await payment();
      await p.splitTransaction(row.id, three);
      final (added, _, _) = await p.addImported([
        alert(
          amount: 5000,
          date: DateTime(2026, 7, 5, 13, 1),
          rawBody: 'Rs.5000 debited at PEBBLE MART again',
        ),
      ]);
      expect(added, 0);
    });

    test('a lone split id is cleared on load', () async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          Tx(
            id: 'lone',
            type: TxType.expense,
            categoryId: 'food',
            amount: 100,
            note: '',
            date: DateTime(2026, 7, 1),
            splitId: 'split_gone',
          ).toJson(),
        ]),
      });
      final p = await loaded();
      expect(byId(p, 'lone').splitId, isNull);
    });

    test('bulk date, Count in and account changes move the whole '
        'payment', () async {
      final (p, row) = await payment();
      final split = await p.splitTransaction(row.id, three);
      final one = {split.afterIds[1]};

      await p.setDateTimeForMany(one, DateTime(2026, 7, 6, 10));
      for (final id in split.afterIds) {
        expect(byId(p, id).date, DateTime(2026, 7, 6, 10));
      }

      await p.setCountInForMany(one, DateTime(2026, 8, 1));
      for (final id in split.afterIds) {
        expect(byId(p, id).countIn, isNotNull);
      }

      final other = await p.addAccount(name: 'Second', type: AccountType.bank);
      await p.assignAccountToMany(one, other);
      for (final id in split.afterIds) {
        expect(p.accountForKey(byId(p, id).acctKey)!.id, other);
      }

      final third = await p.addAccount(name: 'Third', type: AccountType.bank);
      await p.assignAccount(split.afterIds[2], third);
      for (final id in split.afterIds) {
        expect(p.accountForKey(byId(p, id).acctKey)!.id, third);
      }
    });

    test('split parts are never transfer legs or sure refund purchases', () {
      final part = Tx(
        id: 'part',
        type: TxType.expense,
        categoryId: 'food',
        amount: 500,
        note: '',
        date: DateTime(2026, 7, 5),
        acctKey: bank,
        pending: true,
        splitId: 'split_1',
      );
      final inn = Tx(
        id: 'in',
        type: TxType.income,
        categoryId: 'salary',
        amount: 500,
        note: '',
        date: DateTime(2026, 7, 5),
        acctKey: 'ICICI:9999',
        pending: true,
      );
      final a = Account(
        id: 'a',
        name: 'A',
        type: AccountType.bank,
        keys: {bank},
      );
      final b = Account(
        id: 'b',
        name: 'B',
        type: AccountType.bank,
        keys: {'ICICI:9999'},
      );
      Account? accountFor(String? k) => k == bank ? a : (k == null ? null : b);
      expect(
        suggestTransferPairs(
          [part, inn],
          dismissed: const {},
          accountFor: accountFor,
        ),
        isEmpty,
      );
      expect(
        suggestTransferPairs(
          [part.copyWith(clearSplitId: true), inn],
          dismissed: const {},
          accountFor: accountFor,
        ),
        hasLength(1),
      );

      final refund = Tx(
        id: 'r',
        type: TxType.income,
        categoryId: 'other_income',
        amount: 500,
        note: '',
        smsBody: 'Refund of Rs.500 from Pebble Mart',
        date: DateTime(2026, 7, 8),
        source: TxSource.sms,
        sender: 'VM-HDFCBK',
      );
      RefundCandidate c(Tx t) =>
          RefundCandidate(purchase: t, sameMerchant: true, exactAmount: true);
      expect(sureRefundPurchase(refund, [c(part)]), isNull);
      expect(
        sureRefundPurchase(refund, [c(part.copyWith(clearSplitId: true))]),
        isNotNull,
      );
    });

    test('recurring detection sees one payment per split', () {
      final rows = <Tx>[
        for (var m = 4; m <= 7; m++) ...[
          Tx(
            id: 'a$m',
            type: TxType.expense,
            categoryId: 'health',
            amount: 300,
            note: '',
            date: DateTime(2026, m, 3, 9),
            payee: 'Iron Gym',
            splitId: 'split_$m',
          ),
          Tx(
            id: 'b$m',
            type: TxType.expense,
            categoryId: 'food',
            amount: 200,
            note: '',
            date: DateTime(2026, m, 3, 9),
            payee: 'Iron Gym',
            splitId: 'split_$m',
          ),
        ],
      ];
      final hits = detectRecurringPatterns(rows, now: DateTime(2026, 7, 20));
      expect(hits, hasLength(1));
      expect(hits.single.expectedAmount, 500);
      expect(hits.single.categoryId, 'health');
    });

    test('addTransaction writes cashbackOff', () async {
      final p = await loaded();
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'test',
        date: DateTime(2026, 7, 1),
        cashbackOff: true,
      );
      expect(byId(p, id).cashbackOff, isTrue);
    });

    test('addTransaction writes rewardGroup and JSON keeps it', () async {
      final p = await loaded();
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'test',
        date: DateTime(2026, 7, 1),
        rewardGroup: 'gX',
      );
      final t = byId(p, id);
      expect(t.rewardGroup, 'gX');
      expect(Tx.fromJson(jsonDecode(jsonEncode(t.toJson()))).rewardGroup, 'gX');
      expect(t.copyWith(clearRewardGroup: true).rewardGroup, isNull);
    });

    test('a bulk move to another account drops its reward pick, a single '
        'assign keeps it', () async {
      final p = await loaded();
      final a = await p.addAccount(name: 'First', type: AccountType.creditCard);
      final b = await p.addAccount(name: 'Second', type: AccountType.bank);
      final c = await p.addAccount(name: 'Third', type: AccountType.bank);
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'test',
        date: DateTime(2026, 7, 1),
        rewardGroup: 'gX',
      );
      await p.assignAccount(id, a);
      await p.assignAccount(id, c);
      expect(byId(p, id).rewardGroup, 'gX');
      await p.assignAccountToMany({id}, b);
      expect(byId(p, id).rewardGroup, isNull);
    });

    test(
      'the anchor is the alert row whatever order rows are stored in',
      () async {
        final (p, row) = await payment();
        final split = await p.splitTransaction(row.id, three);
        final rows = p.transactions;
        final parts = [for (final id in split.afterIds) byId(p, id)];
        // A CSV export writes the parts before the alert row.
        await p.importTransactions([
          ...parts.skip(1),
          parts.first,
          ...rows.where((t) => t.splitId == null),
        ], replace: true);
        final anchor = p.splitAnchorOf(byId(p, split.afterIds[2]));
        expect(anchor.id, row.id);
        expect(p.splitPartsOf(anchor).map((t) => t.id), split.afterIds);
        expect(p.isSplitPart(byId(p, row.id)), isFalse);
        // The alert row still stands for the payment against a rescan.
        final (added, _, _) = await p.addImported([
          alert(
            amount: 5000,
            date: DateTime(2026, 7, 5, 13, 1),
            rawBody: 'Rs.5000 debited at PEBBLE MART again',
          ),
        ]);
        expect(added, 0);
      },
    );

    test('withSplitSiblings gives a bulk edit Undo every part', () async {
      final (p, row) = await payment();
      final split = await p.splitTransaction(row.id, three);
      final snapshot = p.withSplitSiblings([split.afterIds[1]]);
      expect({for (final t in snapshot) t.id}, split.afterIds.toSet());
      await p.setDateTimeForMany({split.afterIds[1]}, DateTime(2026, 7, 9));
      await p.restoreEditedTransactions(snapshot);
      for (final id in split.afterIds) {
        expect(byId(p, id).date, DateTime(2026, 7, 5, 13));
      }
    });

    test('a second alert for the whole payment waits as a duplicate', () async {
      final (p, row) = await payment();
      await p.splitTransaction(row.id, three);
      final (added, _, _) = await p.addImported([
        alert(
          amount: 5000,
          date: DateTime(2026, 7, 5, 18),
          ref: 'PAY2',
          rawBody: 'Rs.5000 debited at PEBBLE MART counter 2',
        ),
      ]);
      expect(added, 1);
      expect(byRef(p, 'PAY2').pending, isTrue);
    });

    test('a merge moves a part\'s refund to the anchor; Undo moves it '
        'back', () async {
      final (p, row) = await payment();
      final split = await p.splitTransaction(row.id, three);
      final refundId = await p.addTransaction(
        type: TxType.income,
        categoryId: 'other_income',
        amount: 500,
        note: 'test refund',
        date: DateTime(2026, 7, 8),
      );
      expect(await p.linkRefund(refundId, split.afterIds[1]), isTrue);
      final merge = await p.mergeSplit(byId(p, row.id).splitId!);
      expect(byId(p, refundId).refundOf, row.id);
      expect(p.refundedFor(byId(p, row.id)), 500);
      await p.undoSplitChange(merge);
      expect(byId(p, refundId).refundOf, split.afterIds[1]);
    });

    test('a part with a group split blocks a re-split and a merge', () async {
      final (p, row) = await payment();
      final split = await p.splitTransaction(row.id, three);
      final shop = byId(p, split.afterIds[1]);
      await p.updateTransaction(shop.copyWith(myShare: 1500));
      expect(p.canSplit(byId(p, row.id)), isFalse);
      expect(
        () => p.splitTransaction(row.id, const [
          (categoryId: 'food', amount: 2500),
          (categoryId: 'shopping', amount: 2500),
        ]),
        throwsArgumentError,
      );
      expect(() => p.mergeSplit(byId(p, row.id).splitId!), throwsArgumentError);
    });

    test('a split earns once, on its total, at the first part a group '
        'holds', () async {
      FinanceProvider.figuresClock = () => DateTime(2026, 7, 20, 12);
      addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
      final (p, row) = await payment();
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      await p.assignAccount(row.id, card);
      await p.setCardRewards(
        card,
        const CardRewards(
          groups: [
            RewardGroup(categoryIds: {'food'}, rate: 10),
          ],
          baseRate: 1,
        ),
      );
      await p.splitTransaction(row.id, const [
        (categoryId: 'transfer_out', amount: 1000),
        (categoryId: 'food', amount: 4000),
      ]);
      final account = p.accountById(card)!;
      expect(p.rewardMatchFor(account, byId(p, row.id)).group?.categoryIds, {
        'food',
      });
      // ₹5,000 at 10%: the food part's group.
      expect(p.cardRewardsFor(account)!.earned, 500);

      final sid = byId(p, row.id).splitId!;
      final again = p.transactions.firstWhere(
        (t) => t.splitId == sid && t.id != row.id,
      );
      await p.updateTransaction(again.copyWith(categoryId: 'savings_out'));
      expect(
        p.rewardMatchFor(account, byId(p, row.id)).reason,
        RewardReason.everythingElse,
      );
      expect(p.cardRewardsFor(account)!.earned, 50);
    });

    test('a transfer paired to another account earns nothing on the '
        'card', () async {
      FinanceProvider.figuresClock = () => DateTime(2026, 7, 20, 12);
      addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
      final p = await loaded();
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      final bank = await p.addAccount(name: 'Bank', type: AccountType.bank);
      await p.setCardRewards(card, const CardRewards(baseRate: 1));
      final out = await p.addTransaction(
        type: TxType.expense,
        categoryId: kTransferOutCategoryId,
        amount: 1000,
        note: 'test move',
        date: DateTime(2026, 7, 10),
      );
      await p.assignAccount(out, card);
      final inn = await p.addTransaction(
        type: TxType.income,
        categoryId: kTransferInCategoryId,
        amount: 1000,
        note: 'test move',
        date: DateTime(2026, 7, 10),
      );
      await p.assignAccount(inn, bank);
      final pairId = await p.pairTransactions(out, inn);
      expect(pairId, isNotNull);
      expect(p.cardRewardsFor(p.accountById(card)!)!.earned, 0);
      await p.unpair(pairId!);
      expect(p.cardRewardsFor(p.accountById(card)!)!.earned, 10);
    });

    const amazon = RewardGroup(
      id: 'gA',
      name: 'Amazon',
      categoryIds: {},
      merchantWords: {'amazon'},
      rate: 5,
    );
    const shopping = RewardGroup(
      id: 'gB',
      name: 'Shopping',
      categoryIds: {'shopping'},
      rate: 2,
    );

    /// A card with [rules] and a Shopping row on it for each payee and
    /// pick, a day apart from 10 July.
    Future<(FinanceProvider, String, List<String>)> cardWith(
      CardRewards rules,
      List<(String payee, double amount, String? pick)> rows,
    ) async {
      FinanceProvider.figuresClock = () => DateTime(2026, 7, 20, 12);
      addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
      final p = await loaded();
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      await p.setCardRewards(card, rules);
      final ids = <String>[];
      for (final (i, (payee, amount, pick)) in rows.indexed) {
        final id = await p.addTransaction(
          type: TxType.expense,
          categoryId: 'shopping',
          amount: amount,
          note: '',
          date: DateTime(2026, 7, 10 + i),
          payee: payee,
          rewardGroup: pick,
        );
        await p.assignAccount(id, card);
        ids.add(id);
      }
      return (p, card, ids);
    }

    test('a pick is remembered for the merchant on that card', () async {
      final (p, card, _) = await cardWith(
        const CardRewards(groups: [amazon, shopping], baseRate: 1),
        [
          ('Amazon', 1000, null),
          ('Demo Mart', 1000, kEverythingElseRewardGroupId),
          ('Demo Mart', 2000, null),
        ],
      );
      // Amazon 5%, Demo Mart picked at Everything else, then remembered.
      expect(p.cardRewardsFor(p.accountById(card)!)!.earned, 80);
    });

    test('a pick on a deleted group gives way to an older one', () async {
      final (p, card, ids) = await cardWith(
        const CardRewards(groups: [amazon, shopping], baseRate: 1),
        [
          ('Demo Mart', 1000, 'gA'),
          ('Demo Mart', 1000, 'gB'),
          ('Demo Mart', 1000, null),
        ],
      );
      expect(p.rememberedRewardPick(p.accountById(card)!, 'demo mart'), 'gB');
      await p.setCardRewards(
        card,
        const CardRewards(groups: [amazon], baseRate: 1),
      );
      final account = p.accountById(card)!;
      expect(p.rememberedRewardPick(account, 'demo mart'), 'gA');
      final third = p.rewardMatchFor(account, byId(p, ids[2]));
      expect(third.group?.id, 'gA');
      expect(third.reason, RewardReason.remembered);
    });

    test('the last pick made wins, whatever the row dates', () async {
      final (p, card, ids) = await cardWith(
        const CardRewards(groups: [amazon, shopping], baseRate: 1),
        [
          ('Demo Mart', 1000, 'gA'),
          ('Demo Mart', 1000, 'gB'),
          ('Demo Mart', 1000, kEverythingElseRewardGroupId),
        ],
      );
      final account = p.accountById(card)!;
      // No pick times (picks from before they were kept): the latest row.
      expect(
        p.rememberedRewardPick(account, 'demo mart'),
        kEverythingElseRewardGroupId,
      );

      // A timed pick on the oldest row beats untimed picks on newer rows.
      Tx timed(String id, DateTime at) =>
          byId(p, id).copyWith(rewardPickedAt: at);
      await p.restoreEditedTransactions([
        timed(ids[0], DateTime(2026, 7, 15, 9)),
      ]);
      expect(p.rememberedRewardPick(account, 'demo mart'), 'gA');
      expect(
        p.rememberedRewardPick(account, 'demo mart', excludeId: ids[2]),
        'gA',
      );

      // Between timed picks the newer time wins, on an older row too.
      await p.restoreEditedTransactions([
        timed(ids[1], DateTime(2026, 7, 18, 9)),
        timed(ids[2], DateTime(2026, 7, 16, 9)),
      ]);
      expect(p.rememberedRewardPick(account, 'demo mart'), 'gB');
      expect(
        p.rememberedRewardPick(account, 'demo mart', excludeId: ids[1]),
        kEverythingElseRewardGroupId,
      );
    });

    test('a pick time is saved with its pick and cleared with it', () {
      final t = Tx(
        id: 't',
        type: TxType.expense,
        categoryId: 'shopping',
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 10),
      );
      expect(t.toJson().containsKey('rewardPickedAt'), isFalse);
      final at = DateTime(2026, 7, 11, 8, 30);
      final picked = t.copyWith(rewardGroup: 'gA', rewardPickedAt: at);
      final back = Tx.fromJson(picked.toJson());
      expect(back.rewardGroup, 'gA');
      expect(back.rewardPickedAt, at);
      final cleared = back.copyWith(clearRewardGroup: true);
      expect(cleared.rewardPickedAt, isNull);
      expect(cleared.toJson().containsKey('rewardPickedAt'), isFalse);
    });

    test('Undo of a deleted transfer leg brings the pair back', () async {
      final p = await loaded();
      final a = await p.addAccount(name: 'First', type: AccountType.bank);
      final b = await p.addAccount(name: 'Second', type: AccountType.bank);
      final out = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 900,
        note: 'test move',
        date: DateTime(2026, 7, 2),
      );
      final inn = await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 900,
        note: 'test move',
        date: DateTime(2026, 7, 2),
      );
      await p.assignAccount(out, a);
      await p.assignAccount(inn, b);
      final pairId = await p.pairTransactions(out, inn);
      expect(pairId, isNotNull);
      final victim = byId(p, out);
      final partner = await p.deleteTransaction(out);
      expect(partner, isNotNull);
      await p.restoreTransaction(victim);
      await p.restoreEditedTransactions([partner!]);
      expect(byId(p, out).pairId, pairId);
      expect(byId(p, inn).pairId, pairId);
    });
  });
}
