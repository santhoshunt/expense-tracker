import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// Refunds (1.42): a refund linked to its purchase leaves income and takes
/// the purchase's spend down in the purchase's own month, while the
/// all-time balance stays the same. Every merchant, number and amount here
/// is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  // In the past, so nothing depends on today's date.
  final sep = DateTime(2026, 9);
  final oct = DateTime(2026, 10);
  final sep25 = DateTime(2026, 9, 25, 18);
  final oct4 = DateTime(2026, 10, 4, 11);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Tx row(FinanceProvider p, String id) => [
    ...p.transactions,
    ...p.pendingTransactions,
  ].firstWhere((t) => t.id == id);

  /// Every row's money in less money out: what [FinanceProvider.balance]
  /// must stay equal to, linked or not, on a ledger without transfers.
  double naiveBalance(FinanceProvider p) => p.transactions
      .where(p.countsInTotals)
      .fold(
        0.0,
        (s, t) => t.type == TxType.income ? s + t.amount : s - t.amount,
      );

  Future<String> purchase(
    FinanceProvider p, {
    double amount = 1500,
    DateTime? date,
  }) => p.addTransaction(
    type: TxType.expense,
    categoryId: 'shopping',
    amount: amount,
    note: 'Kappa Store',
    date: date ?? sep25,
  );

  Future<String> refund(
    FinanceProvider p, {
    double amount = 500,
    DateTime? date,
    String categoryId = 'other_income',
  }) => p.addTransaction(
    type: TxType.income,
    categoryId: categoryId,
    amount: amount,
    note: 'Kappa Store',
    date: date ?? oct4,
  );

  group('figures', () {
    test('a linked refund leaves income, cuts the purchase month, keeps '
        'the balance', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 40000,
        note: 'pay',
        date: DateTime(2026, 9, 1, 9),
      );
      final buy = await purchase(p);
      final back = await refund(p);

      final balanceBefore = p.balance;
      expect(p.incomeInMonth(oct), 500);
      expect(p.expenseInMonth(sep), 1500);
      final wd = sep25.weekday - 1;
      final avgBefore = p.avgExpenseByWeekday()[wd];

      expect(await p.linkRefund(back, buy), isTrue);

      expect(p.balance, balanceBefore);
      expect(p.balance, naiveBalance(p));
      expect(p.incomeInMonth(oct), 0);
      expect(p.expenseInMonth(sep), 1000);
      expect(p.expenseInMonth(oct), 0);
      expect(p.expenseByCategory(sep).single.value, 1000);
      expect(p.expenseByCategory(sep).single.key.id, 'shopping');
      expect(p.expenseByDayInMonth(sep)[25], 1000);
      expect(p.spendOnDay(sep25).spent, 1000);
      expect(p.spendOnDay(sep25).count, 1);
      // Still listed on its day; its amount counts net.
      expect(p.expensesOnDay(sep25).single.id, buy);
      expect(p.avgExpenseByWeekday()[wd], lessThan(avgBefore));

      final b = row(p, buy);
      final r = row(p, back);
      expect(p.isLinkedRefund(r), isTrue);
      expect(p.refundLinkBroken(r), isFalse);
      expect(p.refundPurchaseOf(r)!.id, buy);
      expect(p.refundsOf(b).single.id, back);
      expect(p.refundedFor(b), 500);
      expect(p.netSpendOf(b), 1000);
      expect(p.netSpendOf(r), r.spendAmount);

      await p.unlinkRefund(back);
      expect(row(p, back).refundOf, isNull);
      expect(p.incomeInMonth(oct), 500);
      expect(p.expenseInMonth(sep), 1500);
      expect(p.balance, balanceBefore);
    });

    test('a full refund takes the purchase to zero', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final back = await refund(p, amount: 1500);
      expect(await p.linkRefund(back, buy), isTrue);
      expect(p.expenseInMonth(sep), 0);
      expect(p.incomeInMonth(oct), 0);
      expect(p.balance, 0);
      expect(p.netSpendOf(row(p, buy)), 0);
      // No ₹0 rows for the charts and category lists.
      expect(p.expenseByCategory(sep), isEmpty);
      expect(p.expenseByCategoryThrough(sep, 26), isEmpty);
      expect(p.expenseByDayInMonth(sep), isEmpty);
      // No payment on its day either, as in the heatmap; the day sheet
      // still lists the row.
      expect(p.spendOnDay(sep25), (spent: 0.0, count: 0));
      expect(p.expensesOnDay(sep25).single.id, buy);
      expect(p.refundableLeftOf(row(p, buy)), 0);
    });

    test(
      'spendOnDay keeps a part-refunded purchase beside a full one',
      () async {
        final p = await loaded();
        final full = await purchase(p, amount: 600);
        await purchase(p, amount: 900);
        final back = await refund(p, amount: 600);
        expect(await p.linkRefund(back, full), isTrue);
        expect(p.spendOnDay(sep25), (spent: 900.0, count: 1));
        expect(p.expenseByDayInMonth(sep)[25], 900);
      },
    );

    test('a purchase edited below its refunds: the older refund that no '
        'longer fits counts as income, and the figures agree', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final older = await refund(p, amount: 1000, date: DateTime(2026, 10, 1));
      final newer = await refund(p, amount: 400, date: DateTime(2026, 10, 3));
      expect(await p.linkRefund(older, buy), isTrue);
      expect(await p.linkRefund(newer, buy), isTrue);
      expect(p.refundableLeftOf(row(p, buy)), 100);
      final balanceBefore = p.balance;

      // 800 now: oldest first, the 1,000 refund does not fit and is skipped;
      // the 400 one still does.
      await p.updateTransaction(row(p, buy).copyWith(amount: 800));
      expect(p.isLinkedRefund(row(p, older)), isFalse);
      expect(p.refundLinkBroken(row(p, older)), isTrue);
      expect(p.isLinkedRefund(row(p, newer)), isTrue);
      expect(p.refundedFor(row(p, buy)), 400);
      expect(p.refundableLeftOf(row(p, buy)), 400);
      expect(p.expenseInMonth(sep), 400);
      expect(p.incomeInMonth(oct), 1000);
      // Whole refunds only: income and spend move together, so the
      // balance follows the purchase's own change and nothing else.
      expect(p.balance, balanceBefore + 700);
      expect(p.balance, naiveBalance(p));

      // The list headers fold the rows themselves (_listTotals in the
      // transactions screen, private there): the same fold here agrees with
      // the month figures.
      double listIncome(DateTime m) => p.transactions
          .where(
            (t) =>
                t.effectiveDate.month == m.month &&
                t.type == TxType.income &&
                !isTransferCategory(t.categoryId) &&
                p.countsInTotals(t) &&
                !p.isLinkedRefund(t),
          )
          .fold(0.0, (s, t) => s + t.amount);
      double listSpend(DateTime m) => p.transactions
          .where(
            (t) =>
                t.effectiveDate.month == m.month &&
                t.type == TxType.expense &&
                !isTransferCategory(t.categoryId) &&
                p.countsInTotals(t),
          )
          .fold(0.0, (s, t) => s + p.netSpendOf(t));
      expect(listIncome(oct), p.incomeInMonth(oct));
      expect(listSpend(sep), p.expenseInMonth(sep));
    });

    test(
      'partial refunds add up; one past the amount counts as income',
      () async {
        final p = await loaded();
        final buy = await purchase(p);
        final first = await refund(
          p,
          amount: 1000,
          date: DateTime(2026, 10, 1),
        );
        final second = await refund(
          p,
          amount: 800,
          date: DateTime(2026, 10, 3),
        );
        expect(await p.linkRefund(first, buy), isTrue);
        // Only 500 left of the purchase.
        expect(await p.linkRefund(second, buy), isFalse);
        expect(row(p, second).refundOf, isNull);

        // Forced past the cap, as an edit or a restore could: the later one
        // does not hold and counts as income again.
        await p.updateTransaction(row(p, second).copyWith(refundOf: buy));
        expect(p.isLinkedRefund(row(p, first)), isTrue);
        expect(p.isLinkedRefund(row(p, second)), isFalse);
        expect(p.refundLinkBroken(row(p, second)), isTrue);
        expect(p.expenseInMonth(sep), 500);
        expect(p.incomeInMonth(oct), 800);
        expect(p.balance, naiveBalance(p));

        // The purchase edited below the first refund: it no longer fits, and
        // the next one that does takes its place.
        await p.updateTransaction(row(p, buy).copyWith(amount: 900));
        expect(p.isLinkedRefund(row(p, first)), isFalse);
        expect(p.isLinkedRefund(row(p, second)), isTrue);
        expect(p.expenseInMonth(sep), 100);
        expect(p.incomeInMonth(oct), 1000);
        expect(p.balance, naiveBalance(p));
      },
    );

    test('a deleted purchase sends its refund back to income; Undo brings '
        'the link back', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final back = await refund(p);
      await p.linkRefund(back, buy);
      final victim = row(p, buy);

      await p.deleteTransaction(buy);
      expect(p.isLinkedRefund(row(p, back)), isFalse);
      expect(p.refundLinkBroken(row(p, back)), isTrue);
      expect(p.incomeInMonth(oct), 500);
      expect(p.balance, naiveBalance(p));

      await p.restoreTransaction(victim);
      expect(p.isLinkedRefund(row(p, back)), isTrue);
      expect(p.incomeInMonth(oct), 0);
      expect(p.expenseInMonth(sep), 1000);
    });

    test('a purchase turned into a split breaks the link; one filed as a '
        'transfer keeps it', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final back = await refund(p);
      await p.linkRefund(back, buy);

      await p.updateTransaction(row(p, buy).copyWith(myShare: 750));
      expect(p.isLinkedRefund(row(p, back)), isFalse);
      expect(p.balance, naiveBalance(p) + 750);

      await p.updateTransaction(row(p, buy).copyWith(clearMyShare: true));
      expect(p.isLinkedRefund(row(p, back)), isTrue);

      // v1.43.4: any money out can take a refund, transfers too. The
      // refund stays out of income and the transfer counts what is left.
      await p.updateTransaction(
        row(p, buy).copyWith(categoryId: 'transfer_out'),
      );
      expect(p.isLinkedRefund(row(p, back)), isTrue);
      expect(p.incomeInMonth(oct), 0);
      expect(p.expenseInMonth(sep), 0);
      expect(p.transferOutInMonth(sep), 1000);
    });
  });

  group('linkRefund', () {
    test('refuses a refund dated before the purchase day; allows the same '
        'day', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final early = await refund(p, date: DateTime(2026, 9, 24, 23));
      expect(await p.linkRefund(early, buy), isFalse);
      // Same day, earlier hour than the 18:00 purchase.
      final sameDay = await refund(p, date: DateTime(2026, 9, 25, 9));
      expect(await p.linkRefund(sameDay, buy), isTrue);
    });

    test('a refund filed as a transfer links; refuses splits, repayments '
        'and the wrong direction', () async {
      final p = await loaded();
      final buy = await purchase(p);
      // v1.43.4: the category never matters. A transfer refund leaves the
      // transfers and takes the purchase down.
      final moved = await refund(p, categoryId: 'transfer_in');
      expect(await p.linkRefund(moved, buy), isTrue);
      expect(p.transferInInMonth(oct), 0);
      expect(p.expenseInMonth(sep), 1000);
      // A friend's repayment settles a split, so it is never a refund.
      final repaid = await refund(p, categoryId: kRepaidToMeCategoryId);
      expect(await p.linkRefund(repaid, buy), isFalse);

      final split = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1200,
        note: 'dinner',
        date: sep25,
        myShare: 400,
      );
      final back = await refund(p);
      expect(await p.linkRefund(back, split), isFalse);
      // An expense is never a refund, and income is never a purchase.
      expect(await p.linkRefund(buy, back), isFalse);
      expect(await p.linkRefund('missing', buy), isFalse);
    });

    test('a refund on an uncounted wallet is counted when linked', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final back = await refund(p);
      final wallet = await p.addAccount(
        name: 'me',
        type: AccountType.wallet,
        service: 'Iota Pay',
      );
      await p.assignAccount(back, wallet);
      expect(row(p, back).walletCounted, isFalse);
      expect(p.incomeInMonth(oct), 0);
      final balanceBefore = p.balance;

      expect(await p.linkRefund(back, buy), isTrue);
      expect(row(p, back).walletCounted, isTrue);
      expect(p.isLinkedRefund(row(p, back)), isTrue);
      expect(p.incomeInMonth(oct), 0);
      expect(p.expenseInMonth(sep), 1000);
      // The wallet credit was outside every figure; now it cuts the spend.
      expect(p.balance, balanceBefore + 500);
    });

    test('a pending refund never reduces spend; linking confirms it', () async {
      final p = await loaded();
      final buy = await purchase(p);
      await p.addImported([
        ParsedTxn(
          type: TxType.income,
          amount: 500,
          merchant: 'Mu Traders',
          date: oct4,
          ref: null,
          categoryId: 'other_income',
          sender: 'VM-KAPBNK',
          rawBody:
              'Rs.500.00 credited to a/c XX4321 on 04-10-26 from Mu '
              'Traders.',
          acctKey: 'KAPBNK:4321',
        ),
      ]);
      final pending = p.pendingTransactions.single;
      // Linked by hand while still in review: no effect until confirmed.
      await p.updateTransaction(pending.copyWith(refundOf: buy));
      expect(row(p, pending.id).pending, isTrue);
      expect(p.isLinkedRefund(row(p, pending.id)), isFalse);
      // Not broken either: the purchase did not change.
      expect(p.refundLinkBroken(row(p, pending.id)), isFalse);
      expect(p.expenseInMonth(sep), 1500);

      expect(await p.linkRefund(pending.id, buy), isTrue);
      final linked = row(p, pending.id);
      expect(linked.pending, isFalse);
      expect(linked.unseen, isFalse);
      expect(p.expenseInMonth(sep), 1000);
      expect(p.incomeInMonth(oct), 0);
    });
  });

  group('refundLinkBroken', () {
    test('only a confirmed, counted row whose link fails', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final back = await refund(p);
      expect(await p.linkRefund(back, buy), isTrue);
      expect(p.refundLinkBroken(row(p, back)), isFalse);

      // A wallet row left out of the totals: the link does not hold, but
      // the purchase did not change, so it is not broken.
      final wallet = await p.addAccount(
        name: 'me',
        type: AccountType.wallet,
        service: 'Iota Pay',
      );
      await p.assignAccount(back, wallet);
      await p.updateTransaction(row(p, back).copyWith(walletCounted: false));
      expect(row(p, back).refundOf, buy);
      expect(p.countsInTotals(row(p, back)), isFalse);
      expect(p.isLinkedRefund(row(p, back)), isFalse);
      expect(p.refundLinkBroken(row(p, back)), isFalse);

      // Counted again, the link holds again.
      await p.updateTransaction(row(p, back).copyWith(walletCounted: true));
      expect(p.isLinkedRefund(row(p, back)), isTrue);

      // The purchase deleted: a counted, confirmed refund is broken.
      await p.deleteTransaction(buy);
      expect(p.refundLinkBroken(row(p, back)), isTrue);
      // A row with no link never is.
      final plain = await refund(p, amount: 70);
      expect(p.refundLinkBroken(row(p, plain)), isFalse);
    });
  });

  group('import', () {
    const sender = 'VM-KAPBNK';
    const key = 'KAPBNK:4321';
    const buyBody =
        'Rs.1500.00 debited from a/c XX4321 on 25-09-26 at Kappa Store.';
    const backBody =
        'Refund of Rs.1500.00 from Kappa Store on 04-10-26. Credited to '
        'a/c XX4321.';

    ParsedTxn alert(
      TxType type,
      DateTime date,
      String body, {
      double amount = 1500,
    }) => ParsedTxn(
      type: type,
      amount: amount,
      merchant: 'Kappa Store',
      date: date,
      ref: null,
      categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
      sender: sender,
      rawBody: body,
      acctKey: key,
    );

    test('a sure refund links and counts at once, marked new', () async {
      final p = await loaded();
      await p.addImported([alert(TxType.expense, sep25, buyBody)]);
      await p.confirmAllPending();
      final buy = p.transactions.single;

      final (added, _, _) = await p.addImported([
        alert(TxType.income, oct4, backBody),
      ]);
      expect(added, 1);
      expect(p.lastImportCounted, 1);
      expect(p.pendingCount, 0);
      final back = p.transactions.firstWhere((t) => t.type == TxType.income);
      expect(back.refundOf, buy.id);
      expect(back.unseen, isTrue);
      expect(p.isLinkedRefund(back), isTrue);
      expect(p.expenseInMonth(sep), 0);
      expect(p.incomeInMonth(oct), 0);
    });

    test('two equal purchases: not sure, the refund waits in review', () async {
      final p = await loaded();
      await p.addImported([
        alert(TxType.expense, DateTime(2026, 9, 20, 10), buyBody),
        alert(TxType.expense, sep25, buyBody),
      ]);
      await p.confirmAllPending();
      await p.addImported([alert(TxType.income, oct4, backBody)]);
      expect(p.lastImportCounted, 0);
      final back = p.pendingTransactions.single;
      expect(back.refundOf, isNull);
    });
  });

  group('one-time pass', () {
    test('links sure past refunds and lists likely ones for review', () async {
      final now = DateTime.now();
      DateTime daysAgo(int d) => now.subtract(Duration(days: d));
      Tx sms(
        String id,
        TxType type,
        double amount,
        DateTime date,
        String body,
      ) => Tx(
        id: id,
        type: type,
        categoryId: type == TxType.expense ? 'shopping' : 'other_income',
        amount: amount,
        note: '',
        smsBody: body,
        date: date,
        source: TxSource.sms,
        sender: 'VM-KAPBNK',
      );
      final rows = [
        sms(
          'p1',
          TxType.expense,
          1500,
          daysAgo(20),
          'Rs.1500.00 debited from a/c XX4321 at Kappa Store.',
        ),
        sms(
          'r1',
          TxType.income,
          1500,
          daysAgo(10),
          'Refund of Rs.1500.00 from Kappa Store. Credited to a/c XX4321.',
        ),
        sms(
          'p2',
          TxType.expense,
          800,
          daysAgo(30),
          'Rs.800.00 debited from a/c XX4321 at Lambda Books.',
        ),
        // Part of the purchase: likely, never sure.
        sms(
          'r2',
          TxType.income,
          300,
          daysAgo(5),
          'Refund of Rs.300.00 from Lambda Books. Credited to a/c XX4321.',
        ),
        Tx(
          id: 's1',
          type: TxType.income,
          categoryId: 'salary',
          amount: 40000,
          note: 'pay',
          date: daysAgo(15),
        ),
      ];
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
      });
      final p = await loaded();
      expect(row(p, 'r1').refundOf, 'p1');
      expect(row(p, 'r1').unseen, isFalse);
      expect(p.isLinkedRefund(row(p, 'r1')), isTrue);
      expect(row(p, 'r2').refundOf, isNull);
      expect(p.refundReviewIds, {'r2'});
      expect(p.balance, naiveBalance(p));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('refunds_linked_v1'), isTrue);
      expect(prefs.getStringList('refund_suggest_ids_v1'), ['r2']);

      // Survives a restart; the pass does not run again.
      final again = await loaded();
      expect(again.refundReviewIds, {'r2'});
      expect(row(again, 'r1').refundOf, 'p1');

      // Linking takes the row off the list.
      expect(await again.linkRefund('r2', 'p2'), isTrue);
      expect(again.refundReviewIds, isEmpty);
      expect(prefs.getStringList('refund_suggest_ids_v1'), isNull);
    });

    test('leaves an uncounted wallet refund alone', () async {
      final now = DateTime.now();
      Tx sms(String id, TxType type, int daysAgo, String body) => Tx(
        id: id,
        type: type,
        categoryId: type == TxType.expense ? 'shopping' : 'other_income',
        amount: 1500,
        note: '',
        smsBody: body,
        date: now.subtract(Duration(days: daysAgo)),
        source: TxSource.sms,
        sender: 'VM-KAPBNK',
      );
      final p = await loaded();
      await p.restoreTransactions([
        sms(
          'p1',
          TxType.expense,
          20,
          'Rs.1500.00 debited from a/c XX4321 at Kappa Store.',
        ),
        sms(
          'r1',
          TxType.income,
          10,
          'Refund of Rs.1500.00 from Kappa Store. Credited to a/c XX4321.',
        ),
        sms(
          'p2',
          TxType.expense,
          20,
          'Rs.1500.00 debited from a/c XX4321 at Lambda Books.',
        ),
        sms(
          'r2',
          TxType.income,
          10,
          'Refund of Rs.1500.00 from Lambda Books. Credited to a/c XX4321.',
        ),
      ]);
      final wallet = await p.addAccount(
        name: 'me',
        type: AccountType.wallet,
        service: 'Iota Pay',
      );
      await p.assignAccount('r1', wallet);
      expect(p.countsInTotals(row(p, 'r1')), isFalse);

      // As on the first launch of 1.42.0.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('refunds_linked_v1');
      final again = await loaded();
      // The counted one links, so the pass ran.
      expect(row(again, 'r2').refundOf, 'p2');
      // The uncounted wallet one is not linked, counted or offered.
      expect(row(again, 'r1').refundOf, isNull);
      expect(row(again, 'r1').walletCounted, isFalse);
      expect(again.refundReviewIds, isEmpty);
      expect(again.balance, naiveBalance(again));
    });

    test('Not a refund drops the id; clearAll empties the list', () async {
      SharedPreferences.setMockInitialValues({
        'refund_suggest_ids_v1': ['r2', 'gone'],
      });
      final p = await loaded();
      // No such rows: nothing to ask about.
      expect(p.refundReviewIds, isEmpty);
      await p.dropRefundReviewId('gone');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('refund_suggest_ids_v1'), ['r2']);
      await p.clearAll();
      expect(prefs.getStringList('refund_suggest_ids_v1'), isNull);
    });
  });

  group('backup', () {
    test('the backup carries refundOf, and a restore keeps the link', () async {
      final p = await loaded();
      final buy = await purchase(p);
      final back = await refund(p);
      await p.linkRefund(back, buy);
      final data = jsonDecode(jsonEncode(p.exportData()));
      expect(data['version'], 31);
      final rows = (data['transactions'] as List).cast<Map>();
      expect(rows.firstWhere((m) => m['id'] == back)['refundOf'], buy);
      expect(
        rows.firstWhere((m) => m['id'] == buy).containsKey('refundOf'),
        isFalse,
      );

      SharedPreferences.setMockInitialValues({});
      final fresh = await loaded();
      await fresh.importData(
        Map<String, dynamic>.from(data as Map),
        replace: true,
      );
      expect(fresh.isLinkedRefund(row(fresh, back)), isTrue);
      expect(fresh.expenseInMonth(sep), 1000);
      expect(fresh.incomeInMonth(oct), 0);
    });
  });
}
