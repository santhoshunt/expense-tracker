import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/budget.dart';
import 'package:expense_tracker/services/card_bill.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/dates.dart';

/// Data fixes in the provider, the model and the backup: restored rows keep
/// their merchant, reminder payments follow the row that made them, and
/// several caches and links stay in step with the rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> fresh() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  final now = DateTime.now();
  DateTime daysAgo(int days, [int hour = 10]) =>
      DateTime(now.year, now.month, now.day - days, hour);

  /// A backup holding [transactions] only.
  Map<String, dynamic> backupOf(List<Map<String, dynamic>> transactions) => {
    'app': 'expense_tracker',
    'version': 29,
    'transactions': transactions,
  };

  group('a restored import keeps its merchant', () {
    // Invented alert: no real bank, merchant or account.
    const body =
        'Rs.499.00 debited from A/c XX4321 on 10-09-26 to VPA '
        'zzflix.media@oktest. Avl Bal Rs.12000.00';

    test('export, restore and load keep the title and the mark', () async {
      expect(SmsTxnParser.merchantOf(body), isNotEmpty);
      final source = await fresh();
      await source.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 499,
          merchant: 'zzflix',
          date: daysAgo(20),
          ref: null,
          categoryId: 'entertainment',
          sender: 'VM-TESTBK',
          rawBody: body,
        ),
      ]);
      await source.confirmAllPending();
      final row = source.transactions.single;
      final key = recurringKeyOf(row)!;
      final title = source.rowTitleFor(row);
      expect(title, isNotNull);
      await source.setSubscriptionPins({key: SubscriptionCycle.monthly});

      final data = jsonDecode(jsonEncode(source.exportData())) as Map;
      expect(data['version'], 30);
      final exported = (data['transactions'] as List).single as Map;
      expect(exported.containsKey('smsBody'), isFalse);
      expect(exported['smsMerchant'], SmsTxnParser.merchantOf(body));

      SharedPreferences.setMockInitialValues({});
      final target = await fresh();
      await target.importData(Map<String, dynamic>.from(data), replace: true);
      // The next launch prunes marks no row produces.
      final reloaded = await fresh();
      final restored = reloaded.transactions.single;
      expect(restored.smsBody, isEmpty);
      expect(recurringKeyOf(restored), key);
      expect(reloaded.rowTitleFor(restored), title);
      expect(reloaded.subscriptionPins, {key: SubscriptionCycle.monthly});
    });
  });

  group('reminder payments follow the row that made them', () {
    const broadband = Reminder(
      id: 'rem_net',
      name: 'Broadband',
      dayOfMonth: 10,
      categoryId: 'other_expense',
      expectedAmount: 499,
    );

    ParsedTxn debit() => ParsedTxn(
      type: TxType.expense,
      amount: 499,
      merchant: 'zzqq',
      date: DateTime(2026, 9, 12, 10),
      ref: null,
      categoryId: 'other_expense',
      sender: 'VM-TESTBK',
    );

    test('Undo of an add takes the payment back, and Undo of that puts it '
        'back', () async {
      final p = await fresh();
      await p.restoreReminder(broadband);
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 499,
        note: 'paid in cash',
        date: DateTime(2026, 9, 10, 18),
      );
      expect(p.reminders.single.lastPaidMonth, '2026-09');
      final row = p.transactions.single;
      await p.deleteTransaction(id);
      expect(p.reminders.single.lastPaidMonth, isNull);
      expect(
        (await fresh()).reminders.single.lastPaidMonth,
        isNull,
        reason: 'saved',
      );
      await p.restoreEditedTransactions([row], reAddMissing: true);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
    });

    test('a discarded import never leaves a payment behind', () async {
      final p = await fresh();
      await p.restoreReminder(broadband);
      await p.addImported([debit()]);
      expect(p.pendingTransactions, hasLength(1));
      expect(p.reminders.single.lastPaidMonth, isNull);
      await p.discardAllPending();
      expect(p.pendingTransactions, isEmpty);
      expect(p.reminders.single.lastPaidMonth, isNull);
    });

    test('confirming pays it, Undo of the confirm and a delete take it '
        'back', () async {
      final p = await fresh();
      await p.restoreReminder(broadband);
      await p.addImported([debit()]);
      final pending = p.pendingTransactions.single;
      await p.confirmTransaction(pending.id);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
      await p.restoreEditedTransactions([pending]);
      expect(p.pendingTransactions.single.id, pending.id);
      expect(p.reminders.single.lastPaidMonth, isNull);
      await p.confirmAllPending();
      expect(p.reminders.single.lastPaidMonth, '2026-09');
      await p.deleteTransactions({pending.id});
      expect(p.reminders.single.lastPaidMonth, isNull);
    });

    test('a later mark is kept when the first payment goes', () async {
      final p = await fresh();
      await p.restoreReminder(broadband);
      final id = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 499,
        note: 'paid in cash',
        date: DateTime(2026, 9, 10, 18),
      );
      await p.markReminderPaid('rem_net', DateTime(2026, 10, 10));
      await p.deleteTransaction(id);
      expect(p.reminders.single.lastPaidMonth, '2026-10');
    });
  });

  group('the fuzzy duplicate check', () {
    ParsedTxn withdrawal(DateTime date, double balance) => ParsedTxn(
      type: TxType.expense,
      amount: 2000,
      merchant: 'zzqq',
      date: date,
      ref: null,
      categoryId: 'other_expense',
      sender: 'VM-TESTBK',
      acctKey: 'TESTBK:4321',
      balanceAfter: balance,
    );

    test('two alerts stating different balances are two payments', () async {
      final p = await fresh();
      final at = daysAgo(1);
      final (added, _, _) = await p.addImported([
        withdrawal(at, 9000),
        withdrawal(at.add(const Duration(minutes: 1)), 7000),
      ]);
      expect(added, 2);
    });

    test('the same balance twice is one alert sent twice', () async {
      final p = await fresh();
      final at = daysAgo(1);
      final (added, _, _) = await p.addImported([
        withdrawal(at, 9000),
        withdrawal(at.add(const Duration(minutes: 1)), 9000),
      ]);
      expect(added, 1);
    });
  });

  test('an import never sends a linked refund back to review', () async {
    final p = await fresh();
    await p.importData(
      backupOf([
        {
          'id': 'buy',
          'type': 'expense',
          'categoryId': 'shopping',
          'amount': 700.0,
          'note': 'lamp',
          'date': daysAgo(5).toIso8601String(),
          'source': 'manual',
          'acctKey': 'TESTBK:1111',
        },
        {
          'id': 'refund',
          'type': 'income',
          'categoryId': 'other_income',
          'amount': 700.0,
          'note': '',
          'date': daysAgo(3).toIso8601String(),
          'source': 'sms',
          'sender': 'VM-TESTBK',
          'acctKey': 'TESTBK:1111',
          'refundOf': 'buy',
          'unseen': true,
        },
      ]),
      replace: true,
    );
    Tx refund() => p.transactions.firstWhere((t) => t.id == 'refund');
    expect(p.isLinkedRefund(refund()), isTrue);
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 700,
        merchant: 'zzqq',
        date: daysAgo(3, 11),
        ref: 'ZZ700',
        categoryId: 'other_expense',
        sender: 'VM-TESTBK',
        acctKey: 'TESTBK:2222',
      ),
    ]);
    expect(refund().pending, isFalse);
    expect(p.isLinkedRefund(refund()), isTrue);
  });

  test(
    'a new budget name keeps the alert sent; a new limit re-arms it',
    () async {
      final p = await fresh();
      final id = await p.addBudget(
        name: 'Food',
        limit: 5000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      final prefs = await SharedPreferences.getInstance();
      final key = customBudgetAlertKey(id, DateTime.now());
      await prefs.setInt(key, 100);
      final b = p.budgets.single;
      await p.updateBudget(b.copyWith(name: 'Meals'));
      expect(prefs.getInt(key), 100);
      await p.updateBudget(p.budgets.single.copyWith(limit: 6000));
      expect(prefs.getInt(key), isNull);
    },
  );

  group('pair links', () {
    Future<(String, String)> pair(FinanceProvider p) async {
      final out = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 2000,
        note: 'to savings',
        date: daysAgo(2),
      );
      final inn = await p.addTransaction(
        type: TxType.income,
        categoryId: 'other_income',
        amount: 2000,
        note: 'from bank',
        date: daysAgo(2),
      );
      expect(await p.pairTransactions(out, inn), isNotNull);
      return (out, inn);
    }

    Tx row(FinanceProvider p, String id) =>
        p.transactions.firstWhere((t) => t.id == id);

    test(
      'deleting a transfer category unlinks the pair; Undo relinks it',
      () async {
        final p = await fresh();
        final cat = await p.addCategory(
          label: 'Sweep',
          type: TxType.expense,
          icon: Icons.category,
          color: kNoCategoryColor,
          isTransfer: true,
        );
        final (out, inn) = await pair(p);
        await p.updateTransaction(row(p, out).copyWith(categoryId: cat));
        expect(row(p, out).pairId, isNotNull);
        final deleted = await p.deleteCategory(cat);
        expect(row(p, out).pairId, isNull);
        expect(row(p, inn).pairId, isNull);
        await p.restoreCategory(deleted);
        expect(row(p, out).pairId, isNotNull);
        expect(row(p, inn).pairId, row(p, out).pairId);
      },
    );

    test(
      'a rule that moves a leg out of the transfers unlinks the pair',
      () async {
        final p = await fresh();
        await p.importData(
          backupOf([
            {
              'id': 'out',
              'type': 'expense',
              'categoryId': kTransferOutCategoryId,
              'amount': 2000.0,
              'note': '',
              'smsBody': 'Rs.2000 sent to zzqq sweep',
              'date': daysAgo(2).toIso8601String(),
              'source': 'sms',
              'pairId': 'pair_t',
            },
            {
              'id': 'in',
              'type': 'income',
              'categoryId': kTransferInCategoryId,
              'amount': 2000.0,
              'note': '',
              'date': daysAgo(2).toIso8601String(),
              'source': 'manual',
              'pairId': 'pair_t',
            },
          ]),
          replace: true,
        );
        expect(row(p, 'out').pairId, 'pair_t');
        await p.addRule('zzqq', 'shopping');
        expect(row(p, 'out').categoryId, 'shopping');
        expect(row(p, 'out').pairId, isNull);
        expect(row(p, 'in').pairId, isNull);
      },
    );

    test('bulk delete Undo brings a leg back unlinked', () async {
      final p = await fresh();
      final (out, inn) = await pair(p);
      final removed = await p.deleteTransactions({out});
      expect(row(p, inn).pairId, isNull);
      await p.restoreTransactions(removed);
      expect(row(p, out).pairId, isNull);
    });
  });

  test('rules never match a restored row by its note', () async {
    final p = await fresh();
    await p.importData(
      backupOf([
        {
          'id': 'old',
          'type': 'expense',
          'categoryId': 'other_expense',
          'amount': 120.0,
          'note': 'zzqq lunch',
          'date': daysAgo(4).toIso8601String(),
          'source': 'sms',
        },
        {
          'id': 'waiting',
          'type': 'expense',
          'categoryId': 'other_expense',
          'amount': 80.0,
          'note': 'zzqq snack',
          'date': daysAgo(4).toIso8601String(),
          'source': 'sms',
          'pending': true,
        },
      ]),
      replace: true,
    );
    expect(p.pendingSpamDropsFor('zzqq', kSpamCategoryId), 0);
    final applied = await p.addRule('zzqq', 'food');
    expect(applied.reclassified, 0);
    expect(
      p.transactions.firstWhere((t) => t.id == 'old').categoryId,
      'other_expense',
    );
  });

  test('a replace restore clears the warning of what it supplies', () async {
    SharedPreferences.setMockInitialValues({'tag_colors_v1': '{not json'});
    final p = await fresh();
    expect(p.loadWarnings, contains('tag colours'));
    await p.importData({
      ...backupOf(const []),
      'tagColors': {'trip': 0xFF2EC4B6},
    }, replace: true);
    expect(p.loadWarnings, isNot(contains('tag colours')));
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('tag_colors_v1')!), {'trip': 0xFF2EC4B6});
  });

  test('a replace restore saves the payment marks', () async {
    final p = await fresh();
    final day =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    await p.importData({
      ...backupOf(const []),
      'patternPaid': {'expense|zzflix media': day},
    }, replace: true);
    expect((await fresh()).patternPaidThrough('expense|zzflix media'), day);
  });

  test('account figures move on at midnight', () async {
    final today = DateTime(2026, 9, 14, 22);
    FinanceProvider.figuresClock = () => today;
    addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
    final p = await fresh();
    final acct = await p.addAccount(
      name: 'Wallet bank',
      type: AccountType.bank,
    );
    final id = await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 1000,
      note: 'salary',
      date: DateTime(2026, 9, 15, 9),
    );
    await p.assignAccount(id, acct);
    Account account() => p.accounts.firstWhere((a) => a.id == acct);
    expect(p.accountBalance(account()), 0);
    FinanceProvider.figuresClock = () => DateTime(2026, 9, 15, 10);
    expect(p.accountBalance(account()), 1000);
  });

  group('a card bill paid by transfer', () {
    final today = DateTime(now.year, now.month, now.day);
    // Due two days ago: unpaid, the cycle is still the current one.
    final due = today.subtract(const Duration(days: 2));
    const key = 'TESTCC:9876';

    ParsedTxn cardAlert(TxType type, String categoryId, DateTime date) =>
        ParsedTxn(
          type: type,
          amount: 3200,
          merchant: 'zzqq',
          date: date,
          ref: null,
          categoryId: categoryId,
          sender: 'VM-TESTCC',
          acctKey: key,
          isCard: true,
        );

    Future<(FinanceProvider, String)> cardWithSpend() async {
      final p = await fresh();
      await p.addImported([cardAlert(TxType.expense, 'shopping', daysAgo(20))]);
      await p.confirmAllPending();
      final card = p.accounts.singleWhere((a) => a.isCard);
      await p.setCardCycle(card.id, dueDay: due.day);
      return (p, card.id);
    }

    test('an SMS payment 3 days before the due date leaves it paid', () async {
      final (p, id) = await cardWithSpend();
      Account card() => p.accounts.firstWhere((a) => a.id == id);
      expect(cardBillStatus(card(), now)!.daysUntil, -2, reason: 'overdue');
      await p.addImported([
        cardAlert(
          TxType.income,
          kCardPaymentCategoryId,
          due.subtract(const Duration(days: 3)).add(const Duration(hours: 9)),
        ),
      ]);
      await p.confirmAllPending();
      expect(card().billPaidMonth, monthKey(due));
      final s = cardBillStatus(card(), now)!;
      expect(s.daysUntil, greaterThan(0));
      expect(s.cycleDue.isAfter(today), isTrue);
    });

    test('a payment already in the ledger marks the cycle on load', () async {
      final (p, id) = await cardWithSpend();
      final tx = await p.addTransaction(
        type: TxType.income,
        categoryId: kCardPaymentCategoryId,
        amount: 3200,
        note: 'card bill',
        date: due.subtract(const Duration(days: 3)),
      );
      await p.assignAccount(tx, id);
      expect(p.accounts.firstWhere((a) => a.id == id).billPaidMonth, isNull);
      final again = await fresh();
      expect(
        again.accounts.firstWhere((a) => a.id == id).billPaidMonth,
        monthKey(due),
      );
    });

    test('unpaid, it shows overdue for 7 days and then rolls on', () async {
      final p = await fresh();
      final id = await p.addAccount(
        name: 'Test card',
        type: AccountType.creditCard,
      );
      await p.setCardCycle(id, dueDay: 10);
      final card = p.accounts.firstWhere((a) => a.id == id);
      final late = cardBillStatus(card, DateTime(2026, 9, 17))!;
      expect(late.cycleDue, DateTime(2026, 9, 10));
      expect(late.daysUntil, -7);
      expect(late.urgent, isTrue);
      final next = cardBillStatus(card, DateTime(2026, 9, 18))!;
      expect(next.cycleDue, DateTime(2026, 10, 10));
      expect(next.daysUntil, greaterThan(0));
    });
  });

  test('the PDF net takes savings off once', () async {
    setBuiltinOverrides({
      kSavingsTransferCategoryId: const TxCategory(
        id: kSavingsTransferCategoryId,
        label: 'To savings',
        icon: Icons.savings,
        color: kNoCategoryColor,
        type: TxType.expense,
      ),
    });
    final p = await fresh();
    final month = DateTime(2026, 9);
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 50000,
      note: 'salary',
      date: DateTime(2026, 9, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1000,
      note: 'dinner',
      date: DateTime(2026, 9, 2),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: kSavingsTransferCategoryId,
      amount: 7500,
      note: 'deposit',
      date: DateTime(2026, 9, 3),
    );
    final rows = BackupService.rowsInMonth(p.transactions, month);
    final m = BackupService.summaryFigures(p, rows, month: month);
    // Not a transfer: the deposit is already in the expense.
    expect(m.expense, 8500);
    expect(m.savings, 7500);
    expect(m.net, 41500);
    final y = BackupService.summaryFigures(p, rows, year: 2026);
    expect(y.net, 41500);
    final r = BackupService.summaryFigures(
      p,
      rows,
      range: DateTimeRange(start: month, end: DateTime(2026, 9, 30)),
    );
    expect(r.net, 41500);
  });
}
