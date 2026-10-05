import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/upcoming_items.dart';
import 'package:expense_tracker/utils/dates.dart';

/// Add it for me reminders record their own expenses; plain ones are marked
/// paid by the SMS that pays them.
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

  Reminder cash({
    String since = '2026-09-01',
    String? accountId,
    String? paid,
    SubscriptionCycle cycle = SubscriptionCycle.monthly,
  }) => Reminder(
    id: 'rem_rent',
    name: 'Rent',
    dayOfMonth: 5,
    categoryId: 'other_expense',
    expectedAmount: 18000,
    autoAdd: true,
    accountId: accountId,
    autoSince: since,
    lastPaidMonth: paid,
    cycle: cycle,
    anchorMonth: 1,
  );

  List<Tx> rent(FinanceProvider p) => [
    for (final t in p.transactions)
      if (t.note == 'Rent') t,
  ];

  group('postDueReminders', () {
    test('adds one confirmed row on the due day, once', () async {
      final p = await fresh();
      final bank = await p.addAccount(name: 'Wallet', type: AccountType.bank);
      await p.restoreReminder(cash(accountId: bank));
      final ids = await p.postDueReminders(DateTime(2026, 9, 5, 9));
      expect(ids, hasLength(1));
      final row = rent(p).single;
      expect(row.date, DateTime(2026, 9, 5));
      expect(row.amount, 18000);
      expect(row.pending, isFalse);
      expect(p.transactionsForAccount(bank).map((t) => t.id), [row.id]);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
      // Later the same day, or tomorrow: nothing new.
      expect(await p.postDueReminders(DateTime(2026, 9, 5, 20)), isEmpty);
      expect(await p.postDueReminders(DateTime(2026, 9, 6)), isEmpty);
      // Survives a reload.
      final again = await fresh();
      expect(rent(again), hasLength(1));
      expect(again.reminders.single.autoAdd, isTrue);
    });

    test('nothing before the due day', () async {
      final p = await fresh();
      await p.restoreReminder(cash());
      expect(await p.postDueReminders(DateTime(2026, 9, 4)), isEmpty);
    });

    test('catches up months missed while the app was shut', () async {
      final p = await fresh();
      await p.restoreReminder(cash(since: '2026-07-01'));
      final ids = await p.postDueReminders(DateTime(2026, 9, 10));
      expect(ids, hasLength(3));
      expect(rent(p).map((t) => t.date).toList()..sort(), [
        DateTime(2026, 7, 5),
        DateTime(2026, 8, 5),
        DateTime(2026, 9, 5),
      ]);
    });

    test('never before it was switched on', () async {
      final p = await fresh();
      await p.restoreReminder(cash(since: '2026-09-06'));
      expect(await p.postDueReminders(DateTime(2026, 9, 30)), isEmpty);
      expect(await p.postDueReminders(DateTime(2026, 10, 5)), hasLength(1));
    });

    test('continues after the last recorded one', () async {
      final p = await fresh();
      await p.restoreReminder(cash(since: '2026-01-01', paid: '2026-08'));
      final ids = await p.postDueReminders(DateTime(2026, 9, 5));
      expect(ids, hasLength(1));
      expect(rent(p).single.date, DateTime(2026, 9, 5));
    });

    test('quarterly adds only its months', () async {
      final p = await fresh();
      await p.restoreReminder(
        cash(since: '2026-01-01', cycle: SubscriptionCycle.quarterly),
      );
      await p.postDueReminders(DateTime(2026, 9, 30));
      expect(rent(p).map((t) => t.date.month).toList()..sort(), [1, 4, 7]);
    });

    test('Remove deletes the rows and they stay done', () async {
      final p = await fresh();
      await p.restoreReminder(cash());
      final ids = await p.postDueReminders(DateTime(2026, 9, 5));
      await p.deleteTransactions(ids);
      expect(rent(p), isEmpty);
      expect(await p.postDueReminders(DateTime(2026, 9, 6)), isEmpty);
    });

    test('switching it on through an edit starts from today', () async {
      final p = await fresh();
      final id = await p.addReminder(
        name: 'EB',
        dayOfMonth: 1,
        expectedAmount: 900,
        categoryId: 'other_expense',
      );
      final r = p.reminders.single;
      expect(r.autoSince, isNull);
      await p.updateReminder(r.copyWith(autoAdd: true));
      final on = p.reminders.firstWhere((x) => x.id == id);
      final today = DateTime.now();
      expect(
        DateTime.parse(on.autoSince!),
        DateTime(today.year, today.month, today.day),
      );
    });

    test('changing the schedule never adds past periods again', () async {
      final p = await fresh();
      await p.restoreReminder(cash(since: '2026-01-10', paid: '2026-09'));
      final r = p.reminders.single;
      // Monthly on the 5th, recorded through September, now quarterly.
      await p.updateReminder(
        r.copyWith(cycle: SubscriptionCycle.quarterly, anchorMonth: 1),
      );
      expect(await p.postDueReminders(DateTime(2026, 9, 30)), isEmpty);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
      final ids = await p.postDueReminders(DateTime(2026, 10, 5));
      expect(ids, hasLength(1));
      expect(rent(p).single.date, DateTime(2026, 10, 5));
    });

    test('a deleted account leaves the reminder on no account', () async {
      final p = await fresh();
      final bank = await p.addAccount(name: 'Wallet', type: AccountType.bank);
      await p.restoreReminder(cash(accountId: bank));
      await p.deleteAccount(bank);
      expect(p.reminders.single.accountId, isNull);
    });
  });

  group('an SMS marks a plain reminder paid', () {
    Reminder plain({double amount = 499, bool autoAdd = false}) => Reminder(
      id: 'rem_net',
      name: 'Broadband',
      dayOfMonth: 10,
      categoryId: 'other_expense',
      expectedAmount: amount,
      autoAdd: autoAdd,
      autoSince: autoAdd ? '2026-09-01' : null,
    );

    ParsedTxn debit(double amount, DateTime date) => ParsedTxn(
      type: TxType.expense,
      amount: amount,
      merchant: 'zzqq',
      date: date,
      ref: null,
      categoryId: 'other_expense',
      sender: 'VM-HDFCBK',
    );

    test('the same amount two days after the due day', () async {
      final p = await fresh();
      await p.restoreReminder(plain());
      await p.addImported([debit(499, DateTime(2026, 9, 12, 10))]);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
      final again = await fresh();
      expect(again.reminders.single.lastPaidMonth, '2026-09');
    });

    test('fifteen days early counts, sixteen days early does not', () async {
      final p = await fresh();
      await p.restoreReminder(plain());
      await p.addImported([debit(499, DateTime(2026, 8, 25, 10))]);
      expect(p.reminders.single.lastPaidMonth, isNull);
      await p.addImported([debit(499, DateTime(2026, 8, 26, 10))]);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
    });

    test('paid 16 days late, it never pays next month early', () async {
      final p = await fresh();
      // Paid through August; September's bill (the 10th) is paid on the
      // 26th, 14 days before October's.
      await p.restoreReminder(plain().copyWith(lastPaidMonth: '2026-08'));
      await p.addImported([debit(499, DateTime(2026, 9, 26, 10))]);
      expect(p.reminders.single.lastPaidMonth, '2026-08');
    });

    test(
      'a reminder made earlier, never marked, checks the bill before',
      () async {
        final p = await fresh();
        await p.restoreReminder(plain().copyWith(createdOn: '2026-08-20'));
        await p.addImported([debit(499, DateTime(2026, 9, 26, 10))]);
        expect(p.reminders.single.lastPaidMonth, isNull);
      },
    );

    test('a bill paid a few days late beats another paid early', () async {
      final p = await fresh();
      // Broadband due the 10th, Phone the 22nd, both paid through September.
      await p.restoreReminder(plain().copyWith(lastPaidMonth: '2026-09'));
      await p.restoreReminder(
        const Reminder(
          id: 'rem_phone',
          name: 'Phone',
          dayOfMonth: 22,
          categoryId: 'other_expense',
          expectedAmount: 499,
          lastPaidMonth: '2026-09',
        ),
      );
      // 7 days after Broadband, 5 before Phone.
      await p.addImported([debit(499, DateTime(2026, 10, 17, 10))]);
      final byId = {for (final r in p.reminders) r.id: r.lastPaidMonth};
      expect(byId['rem_net'], '2026-10');
      expect(byId['rem_phone'], '2026-09');
    });

    test('a scan reading newest first still marks both months', () async {
      final p = await fresh();
      await p.restoreReminder(plain().copyWith(lastPaidMonth: '2026-08'));
      // October's bill paid 9 days early, listed before September's.
      await p.addImported([
        debit(499, DateTime(2026, 10, 1, 10)),
        debit(499, DateTime(2026, 9, 10, 10)),
      ]);
      expect(p.reminders.single.lastPaidMonth, '2026-10');
    });

    test('the rescan never lets a paid row pay a second reminder', () async {
      // Dated against the real clock, like the rescan.
      final today = DateTime.now();
      final paid = DateTime(today.year, today.month, today.day - 3, 10);
      DateTime plus(int days) =>
          DateTime(paid.year, paid.month, paid.day + days);
      final p = await fresh();
      await p.restoreReminder(plain().copyWith(dayOfMonth: plus(1).day));
      await p.addImported([debit(499, paid)]);
      expect(p.reminders.single.lastPaidMonth, monthKey(plus(1)));
      // Another ₹499 bill, due 13 days after that payment.
      await p.restoreReminder(
        Reminder(
          id: 'rem_phone',
          name: 'Phone',
          dayOfMonth: plus(13).day,
          categoryId: 'other_expense',
          expectedAmount: 499,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('reminders_early_rescan_v1');
      final again = await fresh();
      final byId = {for (final r in again.reminders) r.id: r.lastPaidMonth};
      expect(byId['rem_net'], monthKey(plus(1)));
      expect(byId['rem_phone'], isNull);
    });

    test('a bill paid 12 days early leaves the bills due', () async {
      final p = await fresh();
      await p.restoreReminder(plain());
      final now = DateTime(2026, 9, 1, 12);
      List<String> due() => [
        for (final b in billsDue(
          p,
          patterns: const [],
          hidden: const {},
          from: DateTime(2026, 8, 25),
          to: DateTime(2026, 9, 30),
          now: now,
        ))
          b.label,
      ];
      expect(due(), ['Broadband']);
      await p.addImported([debit(499, DateTime(2026, 8, 29, 10))]);
      expect(due(), isEmpty);
    });

    test(
      'a typed-in payment 10 days early in another category does not',
      () async {
        final p = await fresh();
        await p.restoreReminder(plain());
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 499,
          note: 'groceries',
          date: DateTime(2026, 8, 31, 12),
        );
        expect(p.reminders.single.lastPaidMonth, isNull);
      },
    );

    test(
      'the first load after the update marks an early payment once',
      () async {
        // An early alert already in the ledger, from a build whose window
        // missed it. Dated against the real clock: the rescan looks back 31
        // days from now.
        final today = DateTime.now();
        final paid = DateTime(today.year, today.month, today.day - 3, 10);
        final dueDay = DateTime(paid.year, paid.month, paid.day + 10);
        final reminder = plain().copyWith(dayOfMonth: dueDay.day);
        final old = await fresh();
        await old.restoreReminder(reminder);
        await old.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 499,
          note: 'typed before the update',
          date: paid,
        );
        expect(old.reminders.single.lastPaidMonth, isNull);
        // A bulk category change marks nothing: the row now pays the reminder
        // but sits unmarked, as an older build's narrower window left it.
        await old.setCategoryForMany({
          old.transactions.single.id,
        }, 'other_expense');
        expect(old.reminders.single.lastPaidMonth, isNull);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('reminders_early_rescan_v1');
        final p = await fresh();
        expect(p.reminders.single.lastPaidMonth, monthKey(dueDay));
        expect(prefs.getBool('reminders_early_rescan_v1'), isTrue);
        // Once only: a mark cleared afterwards stays cleared on the next load.
        await p.clearReminderPaid('rem_net');
        final again = await fresh();
        expect(again.reminders.single.lastPaidMonth, isNull);
      },
    );

    test('a different amount does not', () async {
      final p = await fresh();
      await p.restoreReminder(plain());
      await p.addImported([debit(520, DateTime(2026, 9, 10, 10))]);
      expect(p.reminders.single.lastPaidMonth, isNull);
    });

    test('an Add it for me reminder is never marked by SMS', () async {
      final p = await fresh();
      await p.restoreReminder(plain(autoAdd: true));
      await p.addImported([debit(499, DateTime(2026, 9, 10, 10))]);
      expect(p.reminders.single.lastPaidMonth, isNull);
    });

    test('a typed-in payment in its category marks it too', () async {
      final p = await fresh();
      await p.restoreReminder(plain());
      // A ₹499 grocery bill is not the broadband.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 499,
        note: 'groceries',
        date: DateTime(2026, 9, 10, 12),
      );
      expect(p.reminders.single.lastPaidMonth, isNull);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 499,
        note: 'paid in cash',
        date: DateTime(2026, 9, 10, 18),
      );
      expect(p.reminders.single.lastPaidMonth, '2026-09');
    });

    test('a day-31 bill paid on the 1st of the next month', () async {
      final p = await fresh();
      await p.restoreReminder(plain().copyWith(dayOfMonth: 31));
      await p.addImported([debit(499, DateTime(2026, 11, 1, 10))]);
      expect(p.reminders.single.lastPaidMonth, '2026-10');
    });

    test('an old alert never moves the mark back', () async {
      final p = await fresh();
      await p.restoreReminder(plain().copyWith(lastPaidMonth: '2026-09'));
      await p.addImported([debit(499, DateTime(2026, 8, 10, 10))]);
      expect(p.reminders.single.lastPaidMonth, '2026-09');
    });

    test('one payment marks one of two same-amount reminders', () async {
      final p = await fresh();
      await p.restoreReminder(plain());
      await p.restoreReminder(
        Reminder(
          id: 'rem_other',
          name: 'Phone',
          // Also within reach (2 days early), but further than Broadband.
          dayOfMonth: 13,
          categoryId: 'other_expense',
          expectedAmount: 499,
        ),
      );
      await p.addImported([debit(499, DateTime(2026, 9, 11, 10))]);
      final byId = {for (final r in p.reminders) r.id: r.lastPaidMonth};
      expect(byId['rem_net'], '2026-09');
      expect(byId['rem_other'], isNull);
    });
  });

  test(
    'a reminder and the payment it stands for make one Upcoming row',
    () async {
      final p = await fresh();
      await p.restoreReminder(
        const Reminder(
          id: 'rem_netflix',
          name: 'Netflix',
          dayOfMonth: 28,
          categoryId: 'other_expense',
          expectedAmount: 499,
        ),
      );
      final now = DateTime(2026, 9, 24);
      RecurringHit hit(String key, double amount, DateTime due) => RecurringHit(
        key: key,
        label: 'x',
        categoryId: 'other_expense',
        type: TxType.expense,
        expectedAmount: amount,
        lastDate: due.subtract(const Duration(days: 30)),
        intervalDays: 30,
        nextDue: due,
      );
      final rows = buildUpcomingItems(
        p,
        hits: [
          // By name: the reminder's own rows grouped into a pattern.
          hit('expense|netflix', 499, DateTime(2026, 9, 28)),
          // By amount and date.
          hit('expense|nflx', 499, DateTime(2026, 9, 27)),
          // A different payment stays.
          hit('expense|gym', 1200, DateTime(2026, 9, 27)),
        ],
        hidden: const {},
        now: now,
      );
      expect(rows.map((u) => u.kind.name).toList()..sort(), [
        'recurring',
        'reminder',
      ]);
    },
  );

  test('Add it now records the expense and the due day adds nothing', () async {
    final p = await fresh();
    await p.restoreReminder(cash());
    final id = await p.addReminderPaymentNow(
      'rem_rent',
      DateTime(2026, 9, 5),
      DateTime(2026, 9, 2, 10),
    );
    expect(id, isNotNull);
    expect(rent(p).single.date, DateTime(2026, 9, 2, 10));
    expect(await p.postDueReminders(DateTime(2026, 9, 5)), isEmpty);
    expect(rent(p), hasLength(1));
  });

  test('a backup merge keeps the later paid month', () async {
    final p = await fresh();
    await p.restoreReminder(cash(paid: '2026-10'));
    await p.postDueReminders(DateTime(2026, 11, 5));
    final backup = p.exportData();
    SharedPreferences.setMockInitialValues({});
    final other = await fresh();
    await other.restoreReminder(cash(paid: '2026-10'));
    await other.importData(
      jsonDecode(jsonEncode(backup)) as Map<String, dynamic>,
      replace: false,
    );
    expect(other.reminders.single.lastPaidMonth, '2026-11');
    // November arrived with the backup; it is not added a second time.
    expect(await other.postDueReminders(DateTime(2026, 11, 6)), isEmpty);
    expect(rent(other), hasLength(1));
  });

  test('only an Add it for me reminder covers a hit by name', () {
    final now = DateTime(2026, 9, 24);
    final hit = RecurringHit(
      key: 'expense|airtel',
      label: 'Airtel',
      categoryId: 'other_expense',
      type: TxType.expense,
      expectedAmount: 299,
      lastDate: DateTime(2026, 8, 26),
      intervalDays: 30,
      nextDue: DateTime(2026, 9, 26),
    );
    const plain = Reminder(
      id: 'r',
      name: 'Airtel',
      dayOfMonth: 10,
      categoryId: 'other_expense',
      expectedAmount: 999,
    );
    expect(reminderCoversHit(plain, hit, now), isFalse);
    expect(
      reminderCoversHit(
        plain.copyWith(autoAdd: true, autoSince: '2026-01-01'),
        hit,
        now,
      ),
      isTrue,
    );
    // Same amount and date, but another category: a different bill.
    final gym = plain.copyWith(
      name: 'Gym',
      expectedAmount: 299,
      dayOfMonth: 26,
      categoryId: 'food',
    );
    expect(reminderCoversHit(gym, hit, now), isFalse);
    expect(
      reminderCoversHit(gym.copyWith(categoryId: 'other_expense'), hit, now),
      isTrue,
    );
  });
}
