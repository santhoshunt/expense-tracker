import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// Safe to spend today: (cap - spent before today - bills due) / days left,
/// less today's spend.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // 19 September: 12 days left, today included.
  final now = DateTime(2026, 9, 19, 14);

  Reminder bill(
    String id,
    double amount,
    int day, {
    String category = 'other_expense',
    String? paid,
  }) => Reminder(
    id: id,
    name: id,
    dayOfMonth: day,
    categoryId: category,
    expectedAmount: amount,
    lastPaidMonth: paid,
  );

  Future<FinanceProvider> ledger({
    double today = 0,
    List<Reminder> reminders = const [],
  }) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 22500,
      note: '',
      date: DateTime(2026, 9, 3, 10),
    );
    // Transfers are outside the cap.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transfer_out',
      amount: 9000,
      note: '',
      date: DateTime(2026, 9, 4, 10),
    );
    if (today > 0) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: today,
        note: '',
        date: DateTime(2026, 9, 19, 9),
      );
    }
    for (final r in reminders) {
      await p.restoreReminder(r);
    }
    return p;
  }

  SafeToSpend safe(
    FinanceProvider p, {
    double cap = 40000,
    List<RecurringHit> patterns = const [],
    Set<String> hidden = const {},
  }) => computeSafeToSpend(
    p,
    cap: cap,
    patterns: patterns,
    hidden: hidden,
    now: now,
  )!;

  // Due 30 September: 11 days out, beyond the Upcoming card's window.
  final rent = bill('Rent', 5000, 30);
  final phone = bill('Phone', 1000, 25);

  test('the worked example: 958 a day', () async {
    final s = safe(await ledger(reminders: [rent, phone]));
    expect(s.billsDue, 6000);
    expect(s.daysLeft, 12);
    expect(s.spentBeforeToday, 22500);
    expect(s.dailyAllowance, closeTo(11500 / 12, 1e-9));
    expect(s.leftToday, closeTo(958.33, 0.01));
    expect(s.over, isFalse);
  });

  test("today's spend comes off today only", () async {
    final s = safe(await ledger(today: 400, reminders: [rent, phone]));
    expect(s.dailyAllowance, closeTo(11500 / 12, 1e-9));
    expect(s.leftToday, closeTo(11500 / 12 - 400, 1e-9));
    expect(s.remainingAfterToday, 11100);
    // Tomorrow spreads what is left over 11 days.
    expect(s.allowanceOn(20), closeTo(11100 / 11, 1e-9));
    expect(s.allowanceOn(30), 11100);
    expect(s.allowanceOn(19), isNull);
    expect(s.allowanceOn(31), isNull);
  });

  test('paid, transfer and next-month reminders are not bills', () async {
    final s = safe(
      await ledger(
        reminders: [
          rent,
          bill('Paid', 700, 22, paid: '2026-09'),
          bill('Savings', 3000, 25, category: 'transfer_out'),
          // Overdue by more than the week's grace.
          bill('Old', 900, 2),
        ],
      ),
    );
    expect(s.billsDue, 5000);
  });

  test('a detected payment counts once, and not with its reminder', () async {
    final hit = RecurringHit(
      key: 'expense|netflix',
      label: 'Netflix',
      categoryId: 'food',
      type: TxType.expense,
      expectedAmount: 499,
      lastDate: DateTime(2026, 8, 28),
      intervalDays: 30,
      nextDue: DateTime(2026, 9, 28),
    );
    final alone = safe(await ledger(), patterns: [hit]);
    expect(alone.billsDue, 499);
    final hidden = safe(
      await ledger(),
      patterns: [hit],
      hidden: {'expense|netflix'},
    );
    expect(hidden.billsDue, 0);
    // "Make a reminder" from it: one bill, not two.
    final both = safe(
      await ledger(reminders: [bill('Netflix', 499, 28, category: 'food')]),
      patterns: [hit],
    );
    expect(both.billsDue, 499);
    // A reminder with no amount counts nothing, so it must not hide the
    // detected bill either.
    SharedPreferences.setMockInitialValues({});
    final noAmount = safe(
      await ledger(
        reminders: [
          const Reminder(
            id: 'Netflix',
            name: 'Netflix',
            dayOfMonth: 28,
            categoryId: 'food',
          ),
        ],
      ),
      patterns: [hit],
    );
    expect(noAmount.billsDue, 499);
  });

  test('a detected payment already in the review queue is not due', () async {
    final p = await ledger();
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 700,
        merchant: 'zzqq',
        date: DateTime(2026, 9, 19, 8),
        ref: null,
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs 700 debited to zzqq',
      ),
    ]);
    final key = recurringKeyOf(p.pendingTransactions.single);
    expect(key, isNotNull);
    final hit = RecurringHit(
      key: key!,
      label: 'zzqq',
      categoryId: 'other_expense',
      type: TxType.expense,
      expectedAmount: 700,
      lastDate: DateTime(2026, 8, 20),
      intervalDays: 30,
      nextDue: DateTime(2026, 9, 20),
    );
    final s = safe(p, patterns: [hit]);
    expect(s.billsDue, 0);
    expect(s.spentToday, 700);
  });

  test("last month's overdue bill still counts early in the month", () async {
    final s = computeSafeToSpend(
      await ledger(reminders: [bill('EB', 900, 29)]),
      cap: 40000,
      patterns: const [],
      hidden: const {},
      now: DateTime(2026, 10, 2, 9),
    )!;
    // 29 September, three days overdue, and 29 October.
    expect(s.billsDue, 1800);
  });

  test('an alert still waiting for review is spend', () async {
    final p = await ledger(reminders: [rent]);
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 2000,
        merchant: 'zzqq',
        date: DateTime(2026, 9, 19, 11),
        ref: null,
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
      ),
    ]);
    final s = safe(p);
    expect(s.spentToday, 2000);
    expect(s.leftToday, closeTo((40000 - 22500 - 5000) / 12 - 2000, 1e-9));
  });

  test('a row counted into this month is this month\'s spend', () async {
    final p = await ledger();
    // Paid on 30 August, counted in September: the cap sees it.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1200,
      note: '',
      date: DateTime(2026, 8, 30, 10),
      countIn: DateTime(2026, 9, 1),
    );
    // Paid today, counted in October: out of September's cap.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 300,
      note: '',
      date: DateTime(2026, 9, 19, 9),
      countIn: DateTime(2026, 10, 1),
    );
    final s = safe(p);
    expect(s.spentBeforeToday, 22500 + 1200);
    expect(s.spentToday, 0);
  });

  test('billsDue from today lists what is ahead, today included', () async {
    final p = await ledger(
      reminders: [rent, phone, bill('Past', 800, 12), bill('Milk', 60, 19)],
    );
    // Due today: `from` is 14:00, the due dates midnight. Both kinds must
    // still count.
    final gym = RecurringHit(
      key: 'expense|gym',
      label: 'Gym',
      categoryId: 'food',
      type: TxType.expense,
      expectedAmount: 1500,
      lastDate: DateTime(2026, 8, 19),
      intervalDays: 31,
      nextDue: DateTime(2026, 9, 19),
    );
    final due = billsDue(
      p,
      patterns: [gym],
      hidden: const {},
      from: now,
      to: DateTime(2026, 9, 30),
      now: now,
    );
    expect(
      {for (final b in due) (b.label, b.due.day, b.amount)},
      {
        ('Gym', 19, 1500.0),
        ('Milk', 19, 60.0),
        ('Phone', 25, 1000.0),
        ('Rent', 30, 5000.0),
      },
    );
    // Soonest first.
    expect(due.map((b) => b.due.day).toList(), [19, 19, 25, 30]);
  });
  test('no cap, no figure', () async {
    expect(
      computeSafeToSpend(
        await ledger(),
        cap: 0,
        patterns: const [],
        hidden: const {},
        now: now,
      ),
      isNull,
    );
  });

  test('bills past the cap are over, spend past it is overCap', () async {
    final bills = safe(await ledger(reminders: [rent, phone]), cap: 25000);
    expect(bills.over, isTrue);
    expect(bills.overCap, isFalse);
    final spend = safe(await ledger(), cap: 20000);
    expect(spend.overCap, isTrue);
  });

  group('the Today and Add widget', () {
    Future<Map<String, dynamic>> snapshot(double cap) async {
      final finance = await ledger(reminders: [rent, phone]);
      final settings = SettingsProvider();
      await settings.load();
      await settings.setMonthlyBudget(cap);
      return jsonDecode(
            jsonEncode(
              buildHomeWidgetSnapshot(finance, settings, now, const []),
            ),
          )
          as Map<String, dynamic>;
    }

    test('carries today and one label per later day of the month', () async {
      final data = await snapshot(40000);
      final safe = data['safe'] as Map<String, dynamic>;
      expect(safe['day'], epochDay(now));
      expect(safe['label'], isA<String>());
      // 20..30 September.
      expect(safe['next'], hasLength(11));
    });

    test('no budget, no row', () async {
      final data = await snapshot(0);
      expect(data.containsKey('safe'), isFalse);
    });

    test(
      'over budget reads so; bills that eat the rest read as zero',
      () async {
        final over = (await snapshot(20000))['safe'] as Map<String, dynamic>;
        expect(over['label'], 'Over budget');
        expect((over['next'] as List).toSet(), {'Over budget'});
        // A fresh ledger: the first one's rows are saved in the mock store.
        SharedPreferences.setMockInitialValues({});
        final tight = (await snapshot(25000))['safe'] as Map<String, dynamic>;
        expect(tight['label'], isNot('Over budget'));
        expect(tight['label'], contains('0'));
      },
    );
  });
}
