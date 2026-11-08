import 'dart:convert';

import 'package:flutter/material.dart'
    show Brightness, Color, DateTimeRange, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/budget_widget_service.dart';
import 'package:expense_tracker/services/card_bill.dart';
import 'package:expense_tracker/services/forward_series.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/services/subscriptions.dart';
import 'package:expense_tracker/utils/contrast.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/trip_budget_card.dart';

/// The Month pace, Upcoming and Today widgets' snapshot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime(2026, 7, 18, 14, 30);

  Future<FinanceProvider> ledger() async {
    final p = FinanceProvider();
    await p.load();
    Future<void> spend(DateTime d, double amount, [String cat = 'food']) =>
        p.addTransaction(
          type: TxType.expense,
          categoryId: cat,
          amount: amount,
          note: '',
          date: d,
        );
    // Three complete months from the 1st, then July so far.
    for (final m in [4, 5, 6]) {
      await spend(DateTime(2026, m, 1, 10), 100.0 * m);
      await spend(DateTime(2026, m, 12, 10), 50);
      await spend(DateTime(2026, m, 25, 10), 10.0 * m);
    }
    await spend(DateTime(2026, 7, 2, 10), 300);
    await spend(DateTime(2026, 7, 18, 9), 120);
    await spend(DateTime(2026, 7, 18, 11), 80);
    // A transfer is not spend.
    await spend(DateTime(2026, 7, 18, 12), 5000, 'transfer_out');
    return p;
  }

  test('the usual curve agrees with the Usual card on every day', () async {
    final p = await ledger();
    final curve = usualCumulativeByDay(p, DateTime(2026, 7))!;
    expect(curve, hasLength(31));
    for (final day in [1, 11, 12, 18, 25, 30]) {
      final c = buildMonthComparison(
        p,
        DateTime(2026, 7),
        now: DateTime(2026, 7, day, 12),
      );
      expect(curve[day - 1], c.vsUsual.reference, reason: 'day $day');
    }
    // The last day compares whole months: entry 30.
    final last = buildMonthComparison(
      p,
      DateTime(2026, 7),
      now: DateTime(2026, 7, 31, 12),
    );
    expect(curve[30], last.vsUsual.reference);
    // Cumulative, so it never falls.
    for (var d = 1; d < 31; d++) {
      expect(curve[d], greaterThanOrEqualTo(curve[d - 1]));
    }
  });

  test('no curve without two comparable months', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 10,
      note: '',
      date: DateTime(2026, 6, 1, 10),
    );
    expect(usualCumulativeByDay(p, DateTime(2026, 7)), isNull);
  });

  test('today counts payments by the spend rule and skips transfers', () async {
    final p = await ledger();
    final today = p.spendOnDay(now);
    expect(today.spent, 200);
    expect(today.count, 2);
    expect(p.spendOnDay(DateTime(2026, 7, 17)).count, 0);
  });

  test('the snapshot carries dates, labels and the curve', () async {
    final p = await ledger();
    final s = SettingsProvider();
    await s.load();
    await s.setMonthlyBudget(50000);
    final snap = buildHomeWidgetSnapshot(p, s, now, const []);
    // Survives the trip to Kotlin.
    final json = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
    expect(json['computedDay'], epochDay(now));
    expect(json['monthKey'], 2026 * 12 + 7);
    expect(json['monthLabel'], 'July');
    final pace = json['pace'] as Map<String, dynamic>;
    expect(pace['spent'], 500);
    expect(pace['spentLabel'], '₹500');
    expect(pace['capLabel'], '₹50,000');
    expect((pace['usualByDay'] as List), hasLength(31));
    final today = json['today'] as Map<String, dynamic>;
    expect(today['day'], epochDay(now));
    expect(today['spentLabel'], '₹200');
    expect(today['count'], 2);
    expect(json['upcoming'], isEmpty);
  });

  test('upcoming lists bills due within the window, nearest first', () async {
    final p = await ledger();
    final s = SettingsProvider();
    await s.load();
    // Restored, not added: addReminder stamps the real date as created,
    // which is after this test's July "now".
    for (final r in const [
      Reminder(
        id: 'rent',
        name: 'Rent',
        dayOfMonth: 25,
        expectedAmount: 18000,
        categoryId: 'food',
      ),
      Reminder(
        id: 'netflix',
        name: 'Netflix',
        dayOfMonth: 21,
        expectedAmount: 649,
        categoryId: 'food',
      ),
      // 12 days out: past the reminders' week.
      Reminder(id: 'gym', name: 'Gym', dayOfMonth: 30, categoryId: 'food'),
    ]) {
      await p.restoreReminder(r);
    }
    final up = buildHomeWidgetSnapshot(p, s, now, const [])['upcoming'] as List;
    expect([for (final u in up) u['label']], ['Netflix', 'Rent']);
    expect(up.first['dueDay'], epochDay(DateTime(2026, 7, 21)));
    expect(up.first['dueLabel'], '21 Jul');
    expect(up.first['amountLabel'], '₹649');
  });

  test('split lists the top three and Other, with their colours', () async {
    final p = await ledger();
    final s = SettingsProvider();
    await s.load();
    for (final (cat, amount) in [
      ('food', 800.0),
      ('transport', 500.0),
      ('shopping', 300.0),
      ('entertainment', 200.0),
      ('health', 100.0),
      ('education', 50.0),
    ]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: cat,
        amount: amount,
        note: '',
        date: DateTime(2026, 7, 10, 10),
      );
    }
    final split = buildHomeWidgetSnapshot(p, s, now, const [])['split'] as Map;
    final rows = split['rows'] as List;
    expect(rows, hasLength(4));
    expect(rows.last['label'], 'Other');
    expect(rows.last['amount'], 350);
    expect(rows.first['color'], isA<int>());
    expect(split['total'], greaterThanOrEqualTo(1950));
  });

  group('the Recent widget', () {
    /// A ledger saved with these rows, so pending and unseen rows load as
    /// stored.
    Future<FinanceProvider> saved(List<Tx> rows) async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
        'imports_auto_counted_v1': true,
      });
      final p = FinanceProvider();
      await p.load();
      return p;
    }

    test('lists the newest confirmed rows, signed, with the new marker '
        'and the review count', () async {
      final p = await saved([
        Tx(
          id: 'old',
          type: TxType.expense,
          categoryId: 'food',
          amount: 90,
          note: 'Bakery',
          date: DateTime(2026, 7, 10),
        ),
        Tx(
          id: 'salary',
          type: TxType.income,
          categoryId: 'salary',
          amount: 125000,
          note: '',
          date: DateTime(2026, 7, 16, 9, 15),
        ),
        Tx(
          id: 'move',
          type: TxType.expense,
          categoryId: 'transfer_out',
          amount: 5000,
          note: '',
          date: DateTime(2026, 7, 17, 8),
        ),
        Tx(
          id: 'lunch',
          type: TxType.expense,
          categoryId: 'food',
          amount: 450,
          note: 'Corner Cafe',
          date: DateTime(2026, 7, 18, 13, 5),
          unseen: true,
        ),
        Tx(
          id: 'waiting',
          type: TxType.expense,
          categoryId: 'shopping',
          amount: 999,
          note: '',
          date: DateTime(2026, 7, 18, 14),
          pending: true,
        ),
        Tx(
          id: 'tea',
          type: TxType.expense,
          categoryId: 'food',
          amount: 30,
          note: '',
          date: DateTime(2026, 7, 9),
        ),
      ]);
      final s = SettingsProvider();
      await s.load();
      final snap =
          jsonDecode(jsonEncode(buildHomeWidgetSnapshot(p, s, now, const [])))
              as Map<String, dynamic>;
      expect(snap['toReview'], 1);
      final recent = snap['recent'] as List;
      // Four rows, newest first; the pending one is not among them.
      expect(
        [for (final r in recent) r['amountLabel']],
        ['−₹450', '−₹5,000', '+₹1,25,000', '−₹90'],
      );
      expect(
        [for (final r in recent) r['kind']],
        ['out', 'neutral', 'in', 'out'],
      );
      final lunch = recent.first as Map<String, dynamic>;
      expect(lunch['label'], 'Food & Dining');
      expect(lunch['merchant'], 'Corner Cafe');
      expect(lunch['unseen'], isTrue);
      expect(lunch['day'], epochDay(now));
      expect(lunch['timeLabel'], '1:05 PM');
      expect(lunch['dateLabel'], '18 Jul');
      expect(lunch['icon'], 'food');
      expect(lunch['color'], categoryById('food').color.toARGB32());
      expect(recent[1]['unseen'], isFalse);
      // A midnight row has no time to show.
      expect(recent.last['timeLabel'], isNull);
      expect(recent[2]['merchant'], isNull);
    });

    test('every widget counts what the badge counts, past refunds '
        'included', () async {
      SharedPreferences.setMockInitialValues({
        'imports_auto_counted_v1': true,
        'refunds_linked_v1': true,
        'refund_suggest_ids_v1': ['test-back'],
      });
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        Tx(
          id: 'test-buy',
          type: TxType.expense,
          categoryId: 'shopping',
          amount: 900,
          note: 'Gadget Hub',
          date: DateTime(2026, 7, 10, 18, 30),
          acctKey: 'DEMO:4321',
        ),
        Tx(
          id: 'test-back',
          type: TxType.income,
          categoryId: 'other_income',
          amount: 900,
          note: '',
          smsBody: 'Refund of Rs 900.0 credited to a/c XX4321. -Demo Bank',
          source: TxSource.sms,
          sender: 'VM-DEMOBK',
          date: DateTime(2026, 7, 12, 10),
          // Worded as a refund on the purchase's account: the sheet offers
          // the purchase.
          acctKey: 'DEMO:4321',
        ),
        Tx(
          id: 'test-waiting',
          type: TxType.expense,
          categoryId: 'food',
          amount: 120,
          note: '',
          date: DateTime(2026, 7, 17, 9),
          pending: true,
        ),
      ]);
      final s = SettingsProvider();
      await s.load();
      // One import waits, and the sheet also asks about the past refund.
      expect(p.pendingCount, 1);
      expect(p.reviewCount(s.dismissedPairSuggestions), 2);
      final snap =
          jsonDecode(jsonEncode(buildHomeWidgetSnapshot(p, s, now, const [])))
              as Map<String, dynamic>;
      expect(snap['toReview'], 2);
      expect((snap['week'] as Map)['toReview'], 2);
      expect(snap.containsKey('pendingCount'), isFalse);
    });

    test('masks income when Hide income is on', () async {
      final p = await saved([
        Tx(
          id: 'salary',
          type: TxType.income,
          categoryId: 'salary',
          amount: 125000,
          note: '',
          date: DateTime(2026, 7, 16, 9, 15),
        ),
        Tx(
          id: 'lunch',
          type: TxType.expense,
          categoryId: 'food',
          amount: 450,
          note: '',
          date: DateTime(2026, 7, 17, 13),
        ),
      ]);
      final s = SettingsProvider();
      await s.load();
      await s.setHideIncome(true);
      final recent =
          buildHomeWidgetSnapshot(p, s, now, const [])['recent'] as List;
      expect(
        [for (final r in recent) r['amountLabel']],
        ['−₹450', '+$kMaskedAmount'],
      );
    });
  });

  test('upcoming carries income due, kinds, icons and due days', () async {
    final p = await ledger();
    final s = SettingsProvider();
    await s.load();
    await p.restoreReminder(
      const Reminder(
        id: 'rent',
        name: 'Rent',
        dayOfMonth: 16,
        expectedAmount: 18000,
        categoryId: 'bills',
      ),
    );
    final salary = RecurringHit(
      key: 'income|acme',
      label: 'Acme Payroll',
      categoryId: 'salary',
      type: TxType.income,
      expectedAmount: 90000,
      lastDate: DateTime(2026, 6, 20),
      intervalDays: 30,
      nextDue: DateTime(2026, 7, 20),
    );
    Future<List> upcoming() async =>
        buildHomeWidgetSnapshot(p, s, now, [salary])['upcoming'] as List;

    final up = await upcoming();
    expect([for (final u in up) u['label']], ['Rent', 'Acme Payroll']);
    final rent = up.first as Map<String, dynamic>;
    expect(rent['kind'], 'out');
    // Two days overdue: the widget reads it from the date.
    expect(rent['dueDay'], epochDay(now) - 2);
    expect(rent['amountLabel'], '₹18,000');
    expect(rent['icon'], categoryById('bills').iconKey);
    // A reminder is urgent from its due day; dark keeps the category hue.
    expect(rent['urgentDays'], 0);
    expect(rent['color'], categoryById('bills').color.toARGB32());
    final pay = up.last as Map<String, dynamic>;
    expect(pay['kind'], 'in');
    expect(pay['amountLabel'], '+₹90,000');
    // A detected payment is urgent only once overdue.
    expect(pay['urgentDays'], -1);
    expect(pay['color'], categoryById('salary').color.toARGB32());

    await s.setHideIncome(true);
    expect((await upcoming()).last['amountLabel'], '+$kMaskedAmount');
  });

  test('a light widget theme bakes glyph colours for its surface', () async {
    final p = await ledger();
    final s = SettingsProvider();
    await s.load();
    await p.restoreReminder(
      const Reminder(
        id: 'rent',
        name: 'Rent',
        dayOfMonth: 20,
        expectedAmount: 18000,
        categoryId: 'bills',
      ),
    );
    final snap = buildHomeWidgetSnapshot(p, s, now, const [], light: true);
    int light(Color base) => categoryGlyphColorOn(
      base,
      surface: FigmaPaletteLight.surface,
      dark: false,
    ).toARGB32();
    final rent = (snap['upcoming'] as List).single as Map<String, dynamic>;
    expect(rent['color'], light(categoryById('bills').color));
    final recent = (snap['recent'] as List).first as Map<String, dynamic>;
    expect(recent['color'], light(p.transactions.first.category.color));
  });

  test('the widget theme is light by the app theme mode', () async {
    final s = SettingsProvider();
    await s.load();
    await s.setMode(ThemeMode.light);
    expect(widgetThemeIsLight(s, Brightness.dark), isTrue);
    await s.setMode(ThemeMode.dark);
    expect(widgetThemeIsLight(s, Brightness.light), isFalse);
    await s.setMode(ThemeMode.system);
    expect(widgetThemeIsLight(s, Brightness.light), isTrue);
    expect(widgetThemeIsLight(s, Brightness.dark), isFalse);
  });

  test(
    'a card bill row is plain, uncoloured and urgent by its window',
    () async {
      final p = FinanceProvider();
      await p.load();
      final s = SettingsProvider();
      await s.load();
      final day = DateTime.now();
      final id = await p.addAccount(
        name: 'Demo Card',
        type: AccountType.creditCard,
      );
      // Outstanding on a card, due today.
      await p.setManualBalance(id, 5000);
      await p.setCardCycle(id, dueDay: day.day);
      final up =
          buildHomeWidgetSnapshot(
                p,
                s,
                day.add(const Duration(milliseconds: 200)),
                const [],
              )['upcoming']
              as List;
      final card =
          up.singleWhere((u) => (u as Map)['icon'] == 'card')
              as Map<String, dynamic>;
      expect(card['kind'], 'neutral');
      expect(card.containsKey('color'), isFalse);
      expect(card['urgentDays'], kCardUrgentWindowDays);
    },
  );

  test('the snapshot carries the Ahead balances and each credit card\'s '
      'cycle', () async {
    FinanceProvider.figuresClock = () => now;
    addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    final bank = await p.addAccount(name: 'Test bank', type: AccountType.bank);
    await p.setManualBalance(bank, 52000);
    final card = await p.addAccount(
      name: 'Test card',
      type: AccountType.creditCard,
      creditLimit: 80000,
    );
    await p.setCardCycle(card, statementDay: 25, dueDay: 12);
    await p.setCardRewards(card, const CardRewards(baseRate: 1));
    final buy = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'shopping',
      amount: 2000,
      note: 'Test store',
      date: DateTime(2026, 7, 10, 11),
    );
    await p.assignAccount(buy, card);
    final plain = await p.addAccount(
      name: 'Second card',
      type: AccountType.creditCard,
    );

    final snap =
        jsonDecode(
              jsonEncode(
                buildHomeWidgetSnapshot(
                  p,
                  s,
                  now,
                  const [],
                  patterns: const [],
                ),
              ),
            )
            as Map<String, dynamic>;
    final ahead = snap['ahead'] as Map<String, dynamic>;
    expect(ahead['startDay'], epochDay(now));
    final balances = ahead['balances'] as List;
    expect(balances, hasLength(31));
    // Day 0 already holds today's items, so it is not the start figure.
    final series = aheadSeries(
      p,
      patterns: const [],
      hidden: s.hiddenUpcoming,
      now: now,
    ).series;
    expect(balances[0], series.days[0].balance.round());

    final cards = snap['cards'] as List;
    expect([for (final c in cards) c['id']], [card, plain]);
    final c = cards.first as Map<String, dynamic>;
    expect(c['name'], 'Test card');
    expect(c['spentLabel'], '₹2,000');
    expect(c['limitLabel'], '₹80,000');
    expect(c['statementDay'], epochDay(DateTime(2026, 7, 25)));
    // The cycle's last day, which tells a widget drawn after it that the
    // figures belong to an ended cycle.
    expect(c['cycleEnd'], epochDay(DateTime(2026, 7, 25)));
    expect(
      c['dueDay'],
      epochDay(cardBillStatus(p.accountById(card)!, now)!.due),
    );
    expect(c['rewardsLabel'], startsWith('≈ '));
    final second = cards.last as Map<String, dynamic>;
    expect(second.containsKey('statementDay'), isFalse);
    // No statement day: the cycle is the calendar month.
    expect(second['cycleEnd'], epochDay(DateTime(2026, 7, 31)));
    expect(second['rewardsLabel'], isNull);
  });

  Map<String, dynamic> snapshotOf(FinanceProvider p, SettingsProvider s) =>
      jsonDecode(
            jsonEncode(
              buildHomeWidgetSnapshot(p, s, now, const [], patterns: const []),
            ),
          )
          as Map<String, dynamic>;

  test(
    'the snapshot lists running then upcoming trips with their days',
    () async {
      FinanceProvider.figuresClock = () => now;
      addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
      final p = FinanceProvider();
      await p.load();
      final s = SettingsProvider();
      await s.load();
      Future<void> trip(
        String name,
        double limit,
        String tag,
        DateTime start,
        DateTime end,
      ) => p.addBudget(
        name: name,
        limit: limit,
        mode: BudgetMode.include,
        categoryIds: const {},
        tag: tag,
        range: DateTimeRange(start: start, end: end),
      );
      await trip(
        'Test trip',
        15000,
        'test trip',
        DateTime(2026, 7, 16),
        DateTime(2026, 7, 20),
      );
      await trip(
        'Later trip',
        9000,
        'later trip',
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 3),
      );
      await trip(
        'Old trip',
        5000,
        'old trip',
        DateTime(2026, 7, 1),
        DateTime(2026, 7, 5),
      );
      await p.addBudget(
        name: 'Food cap',
        limit: 5000,
        mode: BudgetMode.include,
        categoryIds: const {'food'},
      );
      Future<void> spend(DateTime d, double amount, [List<String>? tags]) =>
          p.addTransaction(
            type: TxType.expense,
            categoryId: 'food',
            amount: amount,
            note: '',
            date: d,
            tags: tags ?? const [],
          );
      await spend(DateTime(2026, 7, 16, 10), 2000, ['test trip']);
      await spend(DateTime(2026, 7, 18, 9), 1100, ['test trip']);
      await spend(DateTime(2026, 7, 18, 11), 500);

      final block = snapshotOf(p, s)['trip'] as Map<String, dynamic>;
      expect(block['hasBudgets'], isTrue);
      expect(block['sectionVisible'], isTrue);
      final trips = block['trips'] as List;
      expect([for (final t in trips) t['name']], ['Test trip', 'Later trip']);
      final first = trips.first as Map<String, dynamic>;
      expect(first['startDay'], epochDay(DateTime(2026, 7, 16)));
      expect(first['endDay'], epochDay(DateTime(2026, 7, 20)));
      expect(first['limit'], 15000);
      expect(first['spent'], 3100);
      expect(first['byDay'], [2000, 0, 1100, 0, 0]);
      // ₹11,900 left over the 2 days after today.
      expect(first['allowance'], 5950);
      expect(
        first['allowance'],
        tripFutureAllowance(
          range: DateTimeRange(
            start: DateTime(2026, 7, 16),
            end: DateTime(2026, 7, 20),
          ),
          limit: 15000,
          spent: 3100,
          today: now,
        ),
      );
      // Before its start: the whole limit over all 3 days.
      expect((trips.last as Map<String, dynamic>)['allowance'], 3000);

      // Past its limit: no allowance.
      await spend(DateTime(2026, 7, 17, 10), 16000, ['test trip']);
      final over =
          ((snapshotOf(p, s)['trip'] as Map<String, dynamic>)['trips'] as List)
                  .first
              as Map<String, dynamic>;
      expect(over['name'], 'Test trip');
      expect(over.containsKey('allowance'), isFalse);
    },
  );

  test('a trip ended over a week ago lists nothing in Budgets', () async {
    FinanceProvider.figuresClock = () => now;
    addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    // Ended 13 days before now, past the 7 days kTripEndedDays lists it.
    await p.addBudget(
      name: 'Old trip',
      limit: 5000,
      mode: BudgetMode.include,
      categoryIds: const {},
      tag: 'old trip',
      range: DateTimeRange(
        start: DateTime(2026, 7, 1),
        end: DateTime(2026, 7, 5),
      ),
    );
    final block = snapshotOf(p, s)['trip'] as Map<String, dynamic>;
    expect(block['hasBudgets'], isFalse);
    expect(block['trips'], isEmpty);
  });

  test('the snapshot carries the Cash accounts\' total', () async {
    final s = SettingsProvider();
    await s.load();
    final empty = FinanceProvider();
    await empty.load();
    final none = snapshotOf(empty, s)['cash'] as Map<String, dynamic>;
    expect(none['count'], 0);
    expect(none['total'], 0);

    final p = FinanceProvider();
    await p.load();
    final wallet = await p.addAccount(
      name: 'Test cash',
      type: AccountType.cash,
    );
    await p.setManualBalance(wallet, 3000);
    final pouch = await p.addAccount(
      name: 'Second cash',
      type: AccountType.cash,
    );
    await p.setManualBalance(pouch, 1400);
    final bank = await p.addAccount(name: 'Test bank', type: AccountType.bank);
    await p.setManualBalance(bank, 50000);
    final cash = snapshotOf(p, s)['cash'] as Map<String, dynamic>;
    expect(cash['total'], 4400);
    expect(cash['count'], 2);
  });

  test(
    'the snapshot carries subscriptions with price rises and savings',
    () async {
      FinanceProvider.figuresClock = () => now;
      addTearDown(() => FinanceProvider.figuresClock = DateTime.now);
      final p = FinanceProvider();
      await p.load();
      final s = SettingsProvider();
      await s.load();
      Future<String> pay(String note, double amount, DateTime d, String cat) =>
          p.addTransaction(
            type: TxType.expense,
            categoryId: cat,
            amount: amount,
            note: note,
            date: d,
          );
      await pay('Test stream', 499, DateTime(2026, 4, 20, 10), 'bills');
      await pay('Test stream', 499, DateTime(2026, 5, 20, 10), 'bills');
      await pay('Test stream', 649, DateTime(2026, 6, 20, 10), 'bills');
      String? chitId;
      for (final m in [4, 5, 6]) {
        chitId = await pay(
          'Test chit',
          2000,
          DateTime(2026, m, 25, 10),
          kSavingsTransferCategoryId,
        );
      }
      final chitTx = p.transactions.firstWhere((t) => t.id == chitId);
      await p.setSubscriptionPins({
        subscriptionKeyOf(chitTx)!: SubscriptionCycle.monthly,
      });
      for (final m in [4, 5, 6]) {
        await pay('Test fibre', 799, DateTime(2026, m, 28, 10), 'bills');
      }

      final expected = buildSubscriptions(
        p.countedTransactions,
        now: now,
        alias: p.merchantAlias,
        hidden: s.hiddenUpcoming,
        pinned: p.subscriptionPins,
      );
      final block = snapshotOf(p, s)['subscriptions'] as Map<String, dynamic>;
      final rows = [
        for (final r in block['rows'] as List) r as Map<String, dynamic>,
      ];
      expect(
        [for (final r in rows) r['label']],
        [for (final i in expected.active) i.hit.label],
      );
      expect(rows, hasLength(3));
      for (var i = 0; i < rows.length; i++) {
        expect(rows[i]['dueDay'], epochDay(expected.active[i].hit.nextDue));
      }
      // Labels are the notes title-cased (merchantDisplayLabel).
      final stream = rows.firstWhere((r) => r['label'] == 'Test Stream');
      expect(stream['rise'], 150);
      expect(stream['savings'], isFalse);
      final chit = rows.firstWhere((r) => r['label'] == 'Test Chit');
      expect(chit['savings'], isTrue);
      expect(chit.containsKey('rise'), isFalse);
      final fibre = rows.firstWhere((r) => r['label'] == 'Test Fibre');
      expect(fibre.containsKey('rise'), isFalse);
      expect(block['monthly'], closeTo(expected.monthlyTotal, 1e-9));
      expect(
        block['savingsMonthly'],
        closeTo(expected.savingsMonthlyTotal, 1e-9),
      );
      // Spending only: the chit sits in its own total.
      expect(block['savingsMonthly'], greaterThan(0));
    },
  );

  test('the snapshot carries who owes you, largest first', () async {
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    final none = snapshotOf(p, s)['owed'] as Map<String, dynamic>;
    expect(none['count'], 0);
    expect(none['people'], isEmpty);

    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 4000,
      note: 'Test dinner',
      date: DateTime(2026, 7, 10, 20),
      people: const [
        SplitShare(name: 'Ravi', amount: 1500),
        SplitShare(name: 'Meena', amount: 1000),
        SplitShare(name: 'Arun', amount: 750),
      ],
    );
    // Settled by hand: off the balance and the list.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1200,
      note: 'Test lunch',
      date: DateTime(2026, 7, 12, 13),
      people: const [SplitShare(name: 'Priya', amount: 500, settled: true)],
    );
    final owed = snapshotOf(p, s)['owed'] as Map<String, dynamic>;
    expect(owed['total'], 3250);
    expect(owed['count'], 3);
    final people = [
      for (final o in owed['people'] as List) o as Map<String, dynamic>,
    ];
    expect([for (final o in people) o['name']], ['Ravi', 'Meena', 'Arun']);
    expect([for (final o in people) o['owed']], [1500, 1000, 750]);
  });

  test('epochDay counts local calendar days from 1970', () {
    expect(epochDay(DateTime(1970, 1, 2, 23, 59)), 1);
    expect(epochDay(DateTime(2026, 7, 18, 0, 1)), epochDay(now));
    expect(epochDay(DateTime(2026, 7, 19)) - epochDay(now), 1);
  });
}
