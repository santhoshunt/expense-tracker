import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/utils/format.dart';

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
      expect(snap['pendingCount'], 1);
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
      expect(recent[1]['unseen'], isFalse);
      // A midnight row has no time to show.
      expect(recent.last['timeLabel'], isNull);
      expect(recent[2]['merchant'], isNull);
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
    final pay = up.last as Map<String, dynamic>;
    expect(pay['kind'], 'in');
    expect(pay['amountLabel'], '+₹90,000');

    await s.setHideIncome(true);
    expect((await upcoming()).last['amountLabel'], '+$kMaskedAmount');
  });

  test('epochDay counts local calendar days from 1970', () {
    expect(epochDay(DateTime(1970, 1, 2, 23, 59)), 1);
    expect(epochDay(DateTime(2026, 7, 18, 0, 1)), epochDay(now));
    expect(epochDay(DateTime(2026, 7, 19)) - epochDay(now), 1);
  });
}
