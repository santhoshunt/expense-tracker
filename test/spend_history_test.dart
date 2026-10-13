import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/spend_history.dart';
import 'package:expense_tracker/utils/fiscal_year.dart';

/// One category's or merchant's months for the history sheet: the same
/// figures the dashboard rows show, the usual month from the subject's first
/// spend, the biggest month, the running flag and an April to March window.
///
/// Every date is explicit and `now` is injected, so nothing here depends on
/// the day the suite runs. Merchants and notes are made up.
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

  Future<String> spend(
    FinanceProvider p,
    DateTime date,
    double amount, {
    String category = 'food',
    String note = 'seed',
    TxType type = TxType.expense,
    List<SplitShare> people = const [],
    DateTime? countIn,
    bool walletCounted = false,
  }) => p.addTransaction(
    type: type,
    categoryId: category,
    amount: amount,
    note: note,
    date: date,
    people: people,
    countIn: countIn,
    walletCounted: walletCounted,
  );

  /// The merchant identity the Top merchants row for [txId] would carry.
  String merchantKeyOf(FinanceProvider p, String txId) =>
      recurringKeyOf(p.transactions.firstWhere((t) => t.id == txId))!;

  /// The 12 months ending at [end], oldest first, as Month view passes them.
  List<DateTime> twelveTo(DateTime end) => [
    for (var i = 11; i >= 0; i--) DateTime(end.year, end.month - i),
  ];

  final june15 = DateTime(2026, 6, 15, 12);

  test('category months match expenseByCategory', () async {
    final p = await loaded();
    await spend(p, DateTime(2025, 6, 15), 777); // before the window
    await spend(p, DateTime(2025, 8, 3), 120);
    await spend(p, DateTime(2026, 1, 10), 300);
    await spend(p, DateTime(2026, 1, 20), 50);
    await spend(p, DateTime(2026, 1, 5), 999, category: 'transport');
    await spend(p, DateTime(2026, 6, 2), 80);

    final months = twelveTo(DateTime(2026, 6));
    final h = buildSpendHistory(
      p,
      subject: const HistorySubject.category('food', 'Food & Dining'),
      months: months,
      now: june15,
    );

    for (var i = 0; i < months.length; i++) {
      final row = p
          .expenseByCategory(months[i])
          .where((e) => e.key.id == 'food');
      expect(h.amounts[i], row.isEmpty ? 0 : row.first.value);
    }
    expect(h.amounts, [0, 120, 0, 0, 0, 0, 350, 0, 0, 0, 0, 80]);
    expect(h.months.first, DateTime(2025, 7));
    expect(h.anchor, DateTime(2026, 6));
    expect(h.total, 550);
    expect(h.anchorAmount, 80);
  });

  test('merchant months group by the month a row counts in', () async {
    final p = await loaded();
    final first = await spend(
      p,
      DateTime(2026, 2, 14),
      300,
      note: 'Brightleaf Cafe',
    );
    // Paid on 30 March, counted in April.
    await spend(
      p,
      DateTime(2026, 3, 30),
      200,
      note: 'Brightleaf Cafe',
      countIn: DateTime(2026, 4, 1),
    );
    await spend(p, DateTime(2026, 4, 10), 150, note: 'Brightleaf Cafe');
    // Another merchant, and money in from the same one: neither counts.
    await spend(p, DateTime(2026, 4, 12), 999, note: 'Copperpot Diner');
    await spend(
      p,
      DateTime(2026, 4, 15),
      500,
      category: 'other_income',
      note: 'Brightleaf Cafe',
      type: TxType.income,
    );

    final key = merchantKeyOf(p, first);
    final h = buildSpendHistory(
      p,
      subject: HistorySubject.merchant(key, 'Brightleaf Cafe'),
      months: [DateTime(2026, 2), DateTime(2026, 3), DateTime(2026, 4)],
      now: june15,
    );

    expect(h.amounts, [300, 0, 350]);
    expect(h.total, 650);
  });

  test('a split counts its own share', () async {
    final p = await loaded();
    final id = await spend(
      p,
      DateTime(2026, 5, 8),
      900,
      note: 'Lantern Grill',
      people: const [SplitShare(name: 'Friend A', amount: 300)],
    );
    final months = [DateTime(2026, 5)];

    final byCategory = buildSpendHistory(
      p,
      subject: const HistorySubject.category('food', 'Food & Dining'),
      months: months,
      now: june15,
    );
    final byMerchant = buildSpendHistory(
      p,
      subject: HistorySubject.merchant(merchantKeyOf(p, id), 'Lantern Grill'),
      months: months,
      now: june15,
    );

    expect(byCategory.amounts, [600]);
    expect(byMerchant.amounts, [600]);
    expect(byCategory.counts, [1]);
  });

  test('a split paid wholly for others is a row with no spend', () async {
    final p = await loaded();
    final id = await spend(
      p,
      DateTime(2026, 5, 9),
      400,
      note: 'Lantern Grill',
      people: const [SplitShare(name: 'Friend A', amount: 400)],
    );
    final months = [DateTime(2026, 4), DateTime(2026, 5)];
    final h = buildSpendHistory(
      p,
      subject: HistorySubject.merchant(merchantKeyOf(p, id), 'Lantern Grill'),
      months: months,
      now: june15,
    );
    // The sheet still offers its transactions: they exist, at ₹0 own share.
    expect(h.amounts, [0, 0]);
    expect(h.counts, [0, 1]);
    expect(h.anchorCount, 1);
    expect(h.totalCount, 1);
    expect(h.empty, isTrue);
  });

  test('an uncounted wallet row is left out', () async {
    final p = await loaded();
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Pocketpay',
    );
    final uncounted = await spend(
      p,
      DateTime(2026, 3, 5),
      250,
      note: 'Pebble Mart',
    );
    await p.assignAccount(uncounted, wallet);
    final counted = await spend(
      p,
      DateTime(2026, 4, 6),
      40,
      note: 'Pebble Mart',
      walletCounted: true,
    );
    await p.assignAccount(counted, wallet);
    await spend(p, DateTime(2026, 4, 20), 100, note: 'Pebble Mart');

    final row = p.transactions.firstWhere((t) => t.id == uncounted);
    expect(p.countsInTotals(row), isFalse);

    final months = [DateTime(2026, 3), DateTime(2026, 4)];
    final byCategory = buildSpendHistory(
      p,
      subject: const HistorySubject.category('food', 'Food & Dining'),
      months: months,
      now: june15,
    );
    final byMerchant = buildSpendHistory(
      p,
      subject: HistorySubject.merchant(
        merchantKeyOf(p, uncounted),
        'Pebble Mart',
      ),
      months: months,
      now: june15,
    );

    expect(byCategory.amounts, [0, 140]);
    expect(byMerchant.amounts, [0, 140]);
  });

  group('usual', () {
    /// Records start on 1 January (a whole month on record) with transport,
    /// and every month through June holds a row, so the usual window for
    /// June is January to May. Food first spends in February and skips
    /// March; the merchant first pays in March and skips April.
    Future<(FinanceProvider, String)> ledger() async {
      final p = await loaded();
      await spend(p, DateTime(2026, 1, 1), 100, category: 'transport');
      await spend(p, DateTime(2026, 2, 10), 300);
      await spend(p, DateTime(2026, 3, 10), 50, category: 'transport');
      await spend(p, DateTime(2026, 4, 10), 500);
      await spend(p, DateTime(2026, 5, 10), 100);
      await spend(p, DateTime(2026, 6, 2), 40);
      final power = await spend(
        p,
        DateTime(2026, 3, 12),
        500,
        category: 'bills',
        note: 'Riverline Power',
      );
      await spend(
        p,
        DateTime(2026, 5, 12),
        700,
        category: 'bills',
        note: 'Riverline Power',
      );
      // First spend in May: one usable month.
      await spend(p, DateTime(2026, 5, 20), 120, category: 'shopping');
      return (p, merchantKeyOf(p, power));
    }

    test('is the median from the first spend, zeros included', () async {
      final (p, power) = await ledger();
      final months = twelveTo(DateTime(2026, 6));

      final food = buildSpendHistory(
        p,
        subject: const HistorySubject.category('food', 'Food & Dining'),
        months: months,
        now: june15,
      );
      // February to May: [300, 0, 500, 100]. Dropping March's zero would
      // give 300; counting January from before the first spend, 100.
      expect(food.usual, 200);

      final merchant = buildSpendHistory(
        p,
        subject: HistorySubject.merchant(power, 'Riverline Power'),
        months: months,
        now: june15,
      );
      // March to May: [500, 0, 700].
      expect(merchant.usual, 500);

      // Anchored at May, the window is January to April: [300, 0, 500].
      final toMay = buildSpendHistory(
        p,
        subject: const HistorySubject.category('food', 'Food & Dining'),
        months: twelveTo(DateTime(2026, 5)),
        now: june15,
      );
      expect(toMay.usual, 300);
    });

    test('is null under two usable months', () async {
      final (p, _) = await ledger();
      final months = twelveTo(DateTime(2026, 6));

      final once = buildSpendHistory(
        p,
        subject: const HistorySubject.category('shopping', 'Shopping'),
        months: months,
        now: june15,
      );
      expect(once.usual, isNull);

      final never = buildSpendHistory(
        p,
        subject: const HistorySubject.category('health', 'Health'),
        months: months,
        now: june15,
      );
      expect(never.usual, isNull);
    });

    test('a future anchor takes the usual of the running month', () async {
      final (p, _) = await ledger();
      final h = buildSpendHistory(
        p,
        subject: const HistorySubject.category('food', 'Food & Dining'),
        months: twelveTo(DateTime(2026, 8)),
        now: june15,
      );
      expect(h.anchor, DateTime(2026, 8));
      expect(h.usual, 200);
    });
  });

  test('the biggest month, and none when nothing was spent', () async {
    final p = await loaded();
    await spend(p, DateTime(2026, 3, 4), 200);
    await spend(p, DateTime(2026, 4, 4), 700);
    await spend(p, DateTime(2026, 6, 4), 700); // a tie: the older one wins
    final months = twelveTo(DateTime(2026, 6));

    final food = buildSpendHistory(
      p,
      subject: const HistorySubject.category('food', 'Food & Dining'),
      months: months,
      now: june15,
    );
    expect(food.biggestMonth, DateTime(2026, 4));
    expect(food.biggest, 700);
    expect(food.empty, isFalse);

    final none = buildSpendHistory(
      p,
      subject: const HistorySubject.category('health', 'Health'),
      months: months,
      now: june15,
    );
    expect(none.biggestMonth, isNull);
    expect(none.biggest, 0);
    expect(none.empty, isTrue);
    expect(none.total, 0);
    expect(none.anchorAmount, 0);
  });

  test('anchorRunning follows now', () async {
    final p = await loaded();
    await spend(p, DateTime(2026, 6, 2), 80);
    final months = twelveTo(DateTime(2026, 6));
    SpendHistory at(DateTime now) => buildSpendHistory(
      p,
      subject: const HistorySubject.category('food', 'Food & Dining'),
      months: months,
      now: now,
    );

    expect(at(june15).anchorRunning, isTrue);
    expect(at(DateTime(2026, 7, 2, 12)).anchorRunning, isFalse); // ended
    expect(at(DateTime(2026, 5, 20, 12)).anchorRunning, isFalse); // ahead
  });

  test('an April-start year runs April to March', () async {
    final p = await loaded();
    await spend(p, DateTime(2025, 3, 20), 999); // last FY
    await spend(p, DateTime(2025, 4, 1), 100);
    await spend(p, DateTime(2025, 12, 9), 400);
    await spend(p, DateTime(2026, 3, 31), 250);
    await spend(p, DateTime(2026, 4, 2), 888); // next FY

    final h = buildSpendHistory(
      p,
      subject: const HistorySubject.category('food', 'Food & Dining'),
      months: yearMonths(2025, 4),
      now: DateTime(2026, 10, 12, 12),
    );

    expect(h.months.length, 12);
    expect(h.months.first, DateTime(2025, 4));
    expect(h.anchor, DateTime(2026, 3));
    expect(h.amounts, [100, 0, 0, 0, 0, 0, 0, 0, 400, 0, 0, 250]);
    expect(h.total, 750);
    expect(h.anchorAmount, 250);
    expect(h.biggestMonth, DateTime(2025, 12));
    expect(h.anchorRunning, isFalse);
  });

  test('an empty list of months is refused', () async {
    final p = await loaded();
    expect(
      () => buildSpendHistory(
        p,
        subject: const HistorySubject.category('food', 'Food & Dining'),
        months: const [],
        now: june15,
      ),
      throwsAssertionError,
    );
  });
}
