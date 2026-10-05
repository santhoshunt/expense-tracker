import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/month_forecast.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// Month-end forecast: spent so far + bills due + everyday spend for the
/// days left, with bills kept out of the everyday figure. Every amount here
/// is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // 20 October: 11 days after today.
  final now = DateTime(2026, 10, 20, 14);

  Future<FinanceProvider> load() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> spend(
    FinanceProvider p,
    DateTime date,
    double amount, {
    String category = 'food',
  }) => p.addTransaction(
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: '',
    date: date,
  );

  const rent = Reminder(
    id: 'rent',
    name: 'Rent',
    dayOfMonth: 25,
    categoryId: 'other_expense',
    expectedAmount: 15000,
  );

  /// July to September on record from the 1st: everyday food after the
  /// 20th (₹1,100 a month), rent on the 25th, and something on the 1st so
  /// each month counts from its start.
  Future<FinanceProvider> withHistory() async {
    final p = await load();
    for (final m in [7, 8, 9]) {
      await spend(p, DateTime(2026, m, 1, 10), 400);
      await spend(p, DateTime(2026, m, 25, 10), 1100);
      await spend(
        p,
        DateTime(2026, m, 25, 11),
        15000,
        category: 'other_expense',
      );
    }
    return p;
  }

  MonthForecast forecast(FinanceProvider p, {DateTime? at, double cap = 0}) {
    final when = at ?? now;
    return computeMonthForecast(
      p,
      // As the dashboard asks: with the user's pins.
      patterns: detectRecurringPatterns(
        p.countedTransactions,
        now: when,
        pinned: p.subscriptionPins,
      ),
      hidden: const {},
      now: when,
      cap: cap,
    )!;
  }

  test('usual everyday spend leaves bills out, and the bill is due', () async {
    final p = await withHistory();
    await p.restoreReminder(rent);
    await spend(p, DateTime(2026, 10, 5, 10), 3000);

    final f = forecast(p, cap: 25000);
    expect(f.basis, EverydayBasis.usual);
    expect(f.usualMonths, 3);
    expect(f.daysAfterToday, 11);
    expect(f.spentSoFar, 3000);
    expect(f.billsDue, 15000);
    // Per day after the 20th: July 100, August 100, September 110. The
    // rent rows on the 25th are not everyday spend.
    expect(f.everyday, closeTo(1100, 0.01));
    expect(f.total, closeTo(19100, 0.01));
    expect(f.underCap, closeTo(5900, 0.01));
  });

  test('a bill paid this month counts once, as spend', () async {
    final p = await withHistory();
    await p.restoreReminder(
      const Reminder(
        id: 'rent',
        name: 'Rent',
        dayOfMonth: 25,
        categoryId: 'other_expense',
        expectedAmount: 15000,
        lastPaidMonth: '2026-10',
      ),
    );
    await spend(
      p,
      DateTime(2026, 10, 18, 10),
      15000,
      category: 'other_expense',
    );
    final f = forecast(p);
    expect(f.spentSoFar, 15000);
    expect(f.billsDue, 0);
    expect(f.total, closeTo(16100, 0.01));
    expect(f.cap, isNull);
    expect(f.underCap, isNull);
  });

  test('a bill paid 13 days early is not counted twice', () async {
    final p = await withHistory();
    await p.restoreReminder(rent);
    // Rent due the 25th, paid on the 12th.
    await spend(
      p,
      DateTime(2026, 10, 12, 10),
      15000,
      category: 'other_expense',
    );
    final f = forecast(p);
    expect(f.spentSoFar, 15000);
    expect(f.bills, isEmpty);
    expect(f.billsDue, 0);
  });

  test('a usual month\'s bill paid early is not everyday spend', () async {
    final p = await load();
    // Rent due the 5th, paid on the 25th of the month before: 11 days
    // early, inside the days after the 20th the everyday figure reads.
    for (final m in [7, 8, 9]) {
      await spend(p, DateTime(2026, m, 1, 10), 400);
      await spend(p, DateTime(2026, m, 25, 10), 1100);
      await spend(
        p,
        DateTime(2026, m, 25, 11),
        15000,
        category: 'other_expense',
      );
    }
    await p.restoreReminder(rent.copyWith(dayOfMonth: 5));
    final f = forecast(p);
    expect(f.basis, EverydayBasis.usual);
    expect(f.everyday, closeTo(1100, 0.01));
  });

  test("a pinned merchant's other purchases are everyday spend", () async {
    final p = await withHistory();
    await p.restoreReminder(rent);
    // A ₹499 monthly plan on the 26th, paid this month on the 3rd, and
    // ₹200 of shopping at the same merchant on the 27th of August and
    // September.
    for (final (d, amount) in [
      (DateTime(2026, 7, 26, 12), 499.0),
      (DateTime(2026, 8, 26, 12), 499.0),
      (DateTime(2026, 8, 27, 12), 200.0),
      (DateTime(2026, 9, 26, 12), 499.0),
      (DateTime(2026, 9, 27, 12), 200.0),
      (DateTime(2026, 10, 3, 12), 499.0),
    ]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'shopping',
        amount: amount,
        note: 'ShopMart',
        date: d,
      );
    }
    await p.setSubscriptionPins({
      'expense|shopmart': SubscriptionCycle.monthly,
    });
    final f = forecast(p);
    expect(f.billsDue, 15000);
    // Per day after the 20th: July 1100 / 11 (the ₹499 is the bill),
    // August 1300 / 11, September 1300 / 10; the middle is August's.
    expect(f.everyday, closeTo(1300, 0.01));
  });

  test('a bill paid early in the month before is still a bill', () async {
    final p = await load();
    // Power bill on the 2nd, paid on 18 October for November.
    for (final d in [
      DateTime(2026, 7, 2, 9),
      DateTime(2026, 8, 2, 9),
      DateTime(2026, 9, 2, 9),
      DateTime(2026, 10, 2, 9),
      DateTime(2026, 10, 18, 9),
    ]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'bills',
        amount: 1200,
        note: 'PowerCo',
        date: d,
      );
    }
    for (final m in [7, 8, 9, 10]) {
      await spend(p, DateTime(2026, m, 1, 8), 400);
      await spend(p, DateTime(2026, m, 10, 10), 100);
    }
    final f = forecast(p, at: DateTime(2026, 11, 1, 12));
    expect(f.basis, EverydayBasis.usual);
    // Everyday is the ₹100 a month, not the power bill.
    expect(f.everyday, lessThan(150));
  });

  test("with no history it uses this month's pace after 14 days", () async {
    final p = await load();
    await spend(p, DateTime(2026, 10, 1, 10), 1200);
    await spend(p, DateTime(2026, 10, 3, 10), 800);
    final f = forecast(p);
    expect(f.basis, EverydayBasis.pace);
    // ₹2,000 over 20 days = ₹100 a day, for 11 days.
    expect(f.everyday, closeTo(1100, 0.01));
  });

  test('before 14 days on record there is no everyday part', () async {
    final p = await load();
    await spend(p, DateTime(2026, 10, 10, 10), 500);
    final f = forecast(p);
    expect(f.basis, EverydayBasis.none);
    expect(f.everyday, 0);
    expect(f.total, 500);
  });

  test('uncounted wallet rows stay out; a counted-in row counts', () async {
    final p = await load();
    await spend(p, DateTime(2026, 10, 1, 10), 2000);
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Shop Pay',
    );
    final onWallet = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 700,
      note: 'wallet',
      date: DateTime(2026, 10, 4, 10),
    );
    await p.assignAccount(onWallet, wallet);
    final late = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 300,
      note: 'late',
      date: DateTime(2026, 9, 30, 20),
    );
    await p.setCountInForMany({late}, DateTime(2026, 10, 1));
    final f = forecast(p);
    expect(f.spentSoFar, 2300);
  });

  test('on the last day nothing more is expected', () async {
    final p = await withHistory();
    await spend(p, DateTime(2026, 10, 5, 10), 3000);
    final f = forecast(p, at: DateTime(2026, 10, 31, 12));
    expect(f.daysAfterToday, 0);
    expect(f.everyday, 0);
    expect(f.total, 3000);
  });

  test('a month too short for the days left is skipped', () async {
    final p = await load();
    for (final (y, m) in [(2026, 12), (2027, 1), (2027, 2)]) {
      await spend(p, DateTime(y, m, 1, 10), 400);
      await spend(p, DateTime(y, m, 20, 10), 50);
    }
    // 30 March: February has no day after the 30th, so two months remain.
    final f = forecast(p, at: DateTime(2027, 3, 30, 12));
    expect(f.basis, EverydayBasis.usual);
    expect(f.usualMonths, 2);
  });

  test('rows waiting for review count as spent', () async {
    final p = await load();
    await spend(p, DateTime(2026, 10, 2, 10), 1000);
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 250,
        merchant: 'SHOP',
        date: DateTime(2026, 10, 19, 10),
        ref: 'R1',
        categoryId: 'food',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.250 spent at SHOP on 19-10-26.',
        acctKey: null,
      ),
    ]);
    expect(pendingSpendIn(p, DateTime(2026, 10)), 250);
    expect(forecast(p).spentSoFar, 1250);
  });

  /// [withHistory] with its rent reminder, plus a ₹499 payment noted
  /// "StreamBox" on the 25th of July, August and September: a detected
  /// monthly pattern.
  Future<FinanceProvider> withPattern() async {
    final p = await withHistory();
    await p.restoreReminder(rent);
    for (final m in [7, 8, 9]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 499,
        note: 'StreamBox',
        date: DateTime(2026, m, 25, 12),
      );
    }
    return p;
  }

  test("a detected payment is a bill, not everyday spend", () async {
    final p = await withPattern();
    final f = forecast(p);
    expect(f.billsDue, 15499);
    expect(f.everyday, closeTo(1100, 0.01));
  });

  test('a hidden payment counts as everyday spend instead', () async {
    final p = await withPattern();
    final when = now;
    final f = computeMonthForecast(
      p,
      patterns: detectRecurringPatterns(p.countedTransactions, now: when),
      hidden: const {'expense|streambox'},
      now: when,
    )!;
    expect(f.billsDue, 15000);
    // (₹1,100 + ₹499) a month over the days after the 20th: July and
    // August ₹145.36 a day, September ₹159.90; the middle one, 11 days.
    expect(f.everyday, closeTo(1599, 0.01));
  });

  test(
    'a merchant pinned for one yearly payment stays everyday spend',
    () async {
      final p = await withHistory();
      await p.restoreReminder(rent);
      // One ₹1,499 yearly plan in July, then ordinary ₹200 purchases at the
      // same merchant after the 20th in August and September.
      for (final (m, amount) in [(7, 1499.0), (8, 200.0), (9, 200.0)]) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'shopping',
          amount: amount,
          note: 'ShopMart',
          date: DateTime(2026, m, 26, 12),
        );
      }
      await p.setSubscriptionPins({
        'expense|shopmart': SubscriptionCycle.yearly,
      });
      final f = forecast(p);
      // Not due this month, so its rows are everyday: per day after the 20th
      // July (1100 + 1499) / 11, August 1300 / 11, September 1300 / 10; the
      // middle is September's ₹130 a day.
      expect(f.billsDue, 15000);
      expect(f.everyday, closeTo(1430, 0.01));
    },
  );

  test(
    'a typed row of a bill amount in another category is everyday',
    () async {
      final p = await load();
      for (final m in [7, 8, 9]) {
        await spend(p, DateTime(2026, m, 1, 10), 400);
        await spend(p, DateTime(2026, m, 25, 10), 1100);
        // ₹500 for groceries, typed in by hand, beside a ₹500 maid reminder.
        await spend(p, DateTime(2026, m, 26, 10), 500);
      }
      await p.restoreReminder(
        const Reminder(
          id: 'maid',
          name: 'Maid',
          dayOfMonth: 25,
          categoryId: 'household',
          expectedAmount: 500,
        ),
      );
      final f = forecast(p);
      expect(f.everyday, closeTo(1600, 0.01));
    },
  );

  test('with two usual months the lower one sets the estimate', () async {
    final p = await load();
    for (final (m, amount) in [(8, 1100.0), (9, 31000.0)]) {
      await spend(p, DateTime(2026, m, 1, 10), 400);
      await spend(p, DateTime(2026, m, 25, 10), amount);
    }
    final f = forecast(p);
    expect(f.usualMonths, 2);
    // August ₹100 a day; September's one big purchase is not the usual.
    expect(f.everyday, closeTo(1100, 0.01));
  });

  test('rent by bank transfer in another category is still a bill', () async {
    final p = await load();
    for (final m in [7, 8, 9]) {
      await spend(p, DateTime(2026, m, 1, 10), 400);
      await spend(p, DateTime(2026, m, 25, 10), 1100);
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 15000,
          merchant: '',
          date: DateTime(2026, m, 25, 11),
          ref: 'IMPS$m',
          categoryId: 'other_expense',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.15000 debited from a/c XX4321 by IMPS on 25-0$m-26.',
          acctKey: null,
        ),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
    }
    await p.restoreReminder(
      const Reminder(
        id: 'rent',
        name: 'Rent',
        dayOfMonth: 25,
        categoryId: 'housing_rent',
        expectedAmount: 15000,
      ),
    );
    final f = forecast(p);
    expect(f.billsDue, 15000);
    expect(f.everyday, closeTo(1100, 0.01));
  });

  test('records that start mid-month pace over their own days', () async {
    final p = await load();
    // On record from the 8th: 15 days by the 22nd, ₹1,500 of everyday.
    await spend(p, DateTime(2026, 10, 8, 10), 900);
    await spend(p, DateTime(2026, 10, 15, 10), 600);
    final f = forecast(p, at: DateTime(2026, 10, 22, 12));
    expect(f.basis, EverydayBasis.pace);
    expect(f.daysAfterToday, 9);
    expect(f.everyday, closeTo(900, 0.01));
  });

  test('an empty ledger has no forecast', () async {
    final p = await load();
    expect(
      computeMonthForecast(p, patterns: const [], hidden: const {}, now: now),
      isNull,
    );
  });

  group('isOrphanedAccount', () {
    /// An account holding an SMS-made number, as a backup brings it back.
    Future<String> restoredWithKey(FinanceProvider p) async {
      await p.importData({
        'app': 'expense_tracker',
        'version': 21,
        'transactions': <Object>[],
        'accounts': [
          {
            'id': 'acc_restored',
            'name': 'HDFC',
            'type': 'bank',
            'keys': ['HDFC:4321'],
          },
        ],
      }, replace: false);
      return 'acc_restored';
    }

    test('a numbered account no row uses', () async {
      final p = await load();
      final id = await restoredWithKey(p);
      expect(p.isOrphanedAccount(p.accountById(id)!), isTrue);
    });

    test('a number linked by hand is waiting, not emptied', () async {
      final p = await load();
      final id = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.addAccountKey(id, 'HDFC:4321');
      expect(p.accountById(id)!.linkedByHand, {'HDFC:4321'});
      expect(p.isOrphanedAccount(p.accountById(id)!), isFalse);
    });

    test('a typed number alerts already used is an SMS one', () async {
      final p = await load();
      final old = await restoredWithKey(p);
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 70,
          merchant: 'SHOP',
          date: DateTime(2026, 10, 19, 10),
          ref: 'R4',
          categoryId: 'food',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.70 debited from a/c XX4321 on 19-10-26.',
          acctKey: 'HDFC:4321',
        ),
      ]);
      await p.deleteAccount(old);
      final id = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.addAccountKey(id, 'HDFC:4321');
      expect(p.accountById(id)!.linkedByHand, isEmpty);
    });

    test('typing in an SMS number again keeps it one', () async {
      final p = await load();
      final id = await restoredWithKey(p);
      await p.addAccountKey(id, 'HDFC:4321');
      expect(p.accountById(id)!.linkedByHand, isEmpty);
      expect(p.isOrphanedAccount(p.accountById(id)!), isTrue);
    });

    test('a hand-linked number an alert arrived on is an SMS one', () async {
      final p = await load();
      final id = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.addAccountKey(id, 'HDFC:4321');
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 60,
          merchant: 'SHOP',
          date: DateTime(2026, 10, 19, 10),
          ref: 'R3',
          categoryId: 'food',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.60 debited from a/c XX4321 on 19-10-26.',
          acctKey: 'HDFC:4321',
        ),
      ]);
      expect(p.accountById(id)!.linkedByHand, isEmpty);
      // Its only row gone, it reads as emptied again.
      await p.deleteTransactions([p.pendingTransactions.single.id]);
      expect(p.isOrphanedAccount(p.accountById(id)!), isTrue);
    });

    test('undoing the unlink of an SMS number keeps it one', () async {
      final p = await load();
      final id = await restoredWithKey(p);
      await p.removeAccountKey(id, 'HDFC:4321');
      await p.addAccountKey(id, 'HDFC:4321', byHand: false);
      expect(p.accountById(id)!.linkedByHand, isEmpty);
      expect(p.isOrphanedAccount(p.accountById(id)!), isTrue);
    });

    test('never a hand-made account, a wallet or a closed one', () async {
      final p = await load();
      final hand = await p.addAccount(name: 'Cash', type: AccountType.bank);
      expect(p.isOrphanedAccount(p.accountById(hand)!), isFalse);
      final wallet = await p.addAccount(
        name: 'me',
        type: AccountType.wallet,
        service: 'Shop Pay',
      );
      expect(p.isOrphanedAccount(p.accountById(wallet)!), isFalse);
      final saved = await p.addAccount(name: 'RD', type: AccountType.savings);
      await p.addAccountKey(saved, 'SBI:2468');
      await p.closeAccount(saved);
      expect(p.isOrphanedAccount(p.accountById(saved)!), isFalse);
    });

    test('not while a confirmed or pending row uses it', () async {
      final p = await load();
      final id = await restoredWithKey(p);
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 90,
          merchant: 'SHOP',
          date: DateTime(2026, 10, 19, 10),
          ref: 'R2',
          categoryId: 'food',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.90 debited from a/c XX4321 on 19-10-26.',
          acctKey: 'HDFC:4321',
        ),
      ]);
      expect(p.isOrphanedAccount(p.accountById(id)!), isFalse);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      expect(p.isOrphanedAccount(p.accountById(id)!), isFalse);
    });
  });
}
