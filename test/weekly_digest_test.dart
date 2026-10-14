import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/notification_ids.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/weekly_digest.dart';

/// v1.39.0 weekly digest: weeks, the usual week, the Monday booking and
/// the note's payload. 12 Oct 2026 is a Monday. Names and amounts are made
/// up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('weekStartOf', () {
    test('a Monday is its own start, at midnight', () {
      expect(
        weekStartOf(DateTime(2026, 10, 12, 15, 30)),
        DateTime(2026, 10, 12),
      );
    });

    test('a Sunday belongs to the Monday before it', () {
      expect(weekStartOf(DateTime(2026, 10, 18, 23)), DateTime(2026, 10, 12));
    });

    test('a week can start in the month before', () {
      expect(weekStartOf(DateTime(2026, 10, 1)), DateTime(2026, 9, 28));
      expect(weekStartOf(DateTime(2027, 1, 2)), DateTime(2026, 12, 28));
    });
  });

  group('buildWeekDigest', () {
    // Wednesday: the current week holds Monday to Wednesday.
    final now = DateTime(2026, 10, 14, 10);

    Future<FinanceProvider> ledger() async {
      final p = FinanceProvider();
      await p.load();
      Future<void> add(
        String category,
        double amount,
        DateTime date, {
        TxType type = TxType.expense,
      }) => p.addTransaction(
        type: type,
        categoryId: category,
        amount: amount,
        note: 'test $category',
        date: date,
      );
      // Week of 21 Sep, the first on record: Monday 100, Thursday 1,000.
      await add('food', 100, DateTime(2026, 9, 21));
      await add('food', 1000, DateTime(2026, 9, 24));
      // Week of 28 Sep: Tuesday 300.
      await add('food', 300, DateTime(2026, 9, 29));
      // Week of 5 Oct: Wednesday 200, Friday 5,000.
      await add('food', 200, DateTime(2026, 10, 7));
      await add('shopping', 5000, DateTime(2026, 10, 9));
      // This week: two spends, a transfer, pay, and one row waiting.
      await add('food', 50, DateTime(2026, 10, 12, 9));
      await add('transport', 150, DateTime(2026, 10, 13, 18));
      await add('food', 20, DateTime(2026, 10, 13, 19));
      await add(kTransferOutCategoryId, 4000, DateTime(2026, 10, 13));
      await add('salary', 9000, DateTime(2026, 10, 12), type: TxType.income);
      await p.restoreTransaction(
        Tx(
          id: 'test-pending',
          type: TxType.expense,
          categoryId: 'food',
          amount: 75,
          note: 'test pending',
          date: DateTime(2026, 10, 13),
          pending: true,
        ),
      );
      return p;
    }

    test('the current week counts Monday to today, day by day', () async {
      final p = await ledger();
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      expect(d.start, DateTime(2026, 10, 12));
      expect(d.daysShown, 3);
      expect(d.byDay, [50, 170, 0, 0, 0, 0, 0]);
      expect(d.spent, 220, reason: 'the bars add up to the total');
      expect(d.income, 9000);
      // Two spends, the fares, the transfer and the pay: transfers count
      // as rows, not as spend.
      expect(d.count, 5);
      expect(d.toReview, 1);
      expect(d.end, DateTime(2026, 10, 18));
    });

    test('the usual week is day-aligned and starts at the first row', () async {
      final p = await ledger();
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      // Monday to Wednesday of the three weeks on record: 200, 300, 100.
      // The Thursday and Friday rows stay out; whole weeks would give
      // 5,200, 300 and 1,100, a median of 1,100.
      expect(d.usual, 200);
    });

    test('a past week counts all seven days, against whole weeks', () async {
      final p = await ledger();
      final d = buildWeekDigest(p, DateTime(2026, 10, 7), now: now);
      expect(d.start, DateTime(2026, 10, 5));
      expect(d.daysShown, 7);
      expect(d.spent, 5200);
      expect(d.byDay, [0, 0, 200, 0, 5000, 0, 0]);
      // 28 Sep's 300 and 21 Sep's 1,100.
      expect(d.usual, 700);
    });

    test('under two earlier weeks on record there is no usual week', () async {
      final p = await ledger();
      expect(buildWeekDigest(p, DateTime(2026, 9, 28), now: now).usual, isNull);
      expect(buildWeekDigest(p, DateTime(2026, 9, 21), now: now).usual, isNull);
    });

    test('a quiet week in between counts as nothing spent', () async {
      final p = FinanceProvider();
      await p.load();
      Future<void> add(double amount, DateTime date) => p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: amount,
        note: 'test food',
        date: date,
      );
      await add(900, DateTime(2026, 9, 21));
      // Nothing in the week of 28 Sep.
      await add(300, DateTime(2026, 10, 5));
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      // 900, 0 and 300 by Wednesday: 21 Sep's Monday row counts.
      expect(d.usual, 300);
    });

    test('top categories and biggest payments come largest first', () async {
      final p = await ledger();
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      expect(
        [for (final e in d.topCategories) e.key.id],
        ['transport', 'food'],
      );
      expect([for (final e in d.topCategories) e.value], [150, 70]);
      expect([for (final t in d.biggest) t.amount], [150, 50, 20]);
    });

    test('a dangling category keeps its raw id', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'gone-category',
        amount: 40,
        note: 'test gone',
        date: DateTime(2026, 10, 12),
      );
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      expect(d.topCategories.single.key.id, 'gone-category');
    });

    test('an empty ledger is an empty week', () async {
      final p = FinanceProvider();
      await p.load();
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      expect(d.spent, 0);
      expect(d.count, 0);
      expect(d.usual, isNull);
      expect(d.topCategories, isEmpty);
      expect(d.biggest, isEmpty);
    });

    test('a new row shows at once despite the memo', () async {
      final p = await ledger();
      final week = DateTime(2026, 10, 12);
      expect(buildWeekDigest(p, week, now: now).spent, 220);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 30,
        note: 'test later',
        date: DateTime(2026, 10, 14, 8),
      );
      expect(buildWeekDigest(p, week, now: now).spent, 250);
    });
  });

  group('weeklyDigestBooking', () {
    test('Monday 08:30 books today 09:00 for last week', () {
      final b = weeklyDigestBooking(
        DateTime(2026, 10, 12, 8, 30),
        hasData: true,
      );
      expect(b?.when, DateTime(2026, 10, 12, 9));
      expect(b?.week, DateTime(2026, 10, 5));
    });

    test('Monday 09:00 books next Monday for this week', () {
      final b = weeklyDigestBooking(DateTime(2026, 10, 12, 9), hasData: true);
      expect(b?.when, DateTime(2026, 10, 19, 9));
      expect(b?.week, DateTime(2026, 10, 12));
    });

    test('mid-week books next Monday, across a month end too', () {
      final b = weeklyDigestBooking(DateTime(2026, 9, 30, 22), hasData: true);
      expect(b?.when, DateTime(2026, 10, 5, 9));
      expect(b?.week, DateTime(2026, 9, 28));
    });

    test('an empty ledger books nothing', () {
      expect(
        weeklyDigestBooking(DateTime(2026, 10, 12, 8), hasData: false),
        isNull,
      );
    });
  });

  test('the note names the week', () {
    expect(weekRangeLabel(DateTime(2026, 10, 12)), '12 to 18 Oct');
    expect(weekRangeLabel(DateTime(2026, 9, 28)), '28 Sep to 4 Oct');
  });

  group('the note payload', () {
    tearDown(LaunchActions.instance.resetForTest);

    test('round-trips the Monday', () {
      final week = DateTime(2026, 10, 5);
      expect(weeklyPayload(week), 'weekly:2026-10-05');
      expect(parseWeeklyPayload(weeklyPayload(week)), week);
    });

    test('rejects a day that is not a Monday, or not a date', () {
      expect(parseWeeklyPayload('weekly:2026-10-13'), isNull);
      // 30 Feb would roll into March.
      expect(parseWeeklyPayload('weekly:2026-02-30'), isNull);
      expect(parseWeeklyPayload('weekly:2026-1-5'), isNull);
      expect(parseWeeklyPayload('weekly:'), isNull);
      expect(parseWeeklyPayload('recap'), isNull);
    });

    test('a tap opens the digest and hands over its week once', () {
      LaunchActions.instance.onNotificationPayload('weekly:2026-10-12');
      expect(
        LaunchActions.instance.pending.value,
        LaunchAction.openWeeklyDigest,
      );
      expect(LaunchActions.instance.takeWeek(), DateTime(2026, 10, 12));
      expect(LaunchActions.instance.takeWeek(), isNull);
    });

    test('a malformed payload opens nothing', () {
      LaunchActions.instance.onNotificationPayload('weekly:2026-10-13');
      expect(LaunchActions.instance.pending.value, isNull);
      expect(LaunchActions.instance.takeWeek(), isNull);
    });
  });

  test('the note has its own id in the table', () {
    expect(
      NotificationService.weeklyDigestNotificationId,
      NotificationIds.weeklyDigest,
    );
    expect(
      NotificationIds.ranges.where((r) => r.owner == 'Weekly digest'),
      hasLength(1),
    );
  });

  test('the switch defaults on, persists and rides the backup', () async {
    final s = SettingsProvider();
    await s.load();
    expect(s.weeklyDigest, isTrue);
    await s.setWeeklyDigest(false);
    final again = SettingsProvider();
    await again.load();
    expect(again.weeklyDigest, isFalse);
    expect(again.toBackupMap()['weeklyDigest'], isFalse);

    SharedPreferences.setMockInitialValues({});
    final fresh = SettingsProvider();
    await fresh.load();
    // An older backup without the key keeps the current value.
    await fresh.applyBackupMap({'monthlyBudget': 100});
    expect(fresh.weeklyDigest, isTrue);
    await fresh.applyBackupMap({'weeklyDigest': false});
    expect(fresh.weeklyDigest, isFalse);
  });
}
