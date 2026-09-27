import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/spend_comparison.dart';

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
    await p.addReminder(
      name: 'Rent',
      dayOfMonth: 25,
      expectedAmount: 18000,
      categoryId: 'food',
    );
    await p.addReminder(
      name: 'Netflix',
      dayOfMonth: 21,
      expectedAmount: 649,
      categoryId: 'food',
    );
    // 12 days out: past the reminders' week.
    await p.addReminder(name: 'Gym', dayOfMonth: 30, categoryId: 'food');
    final up = buildHomeWidgetSnapshot(p, s, now, const [])['upcoming'] as List;
    expect([for (final u in up) u['label']], ['Netflix', 'Rent']);
    expect(up.first['dueDay'], epochDay(DateTime(2026, 7, 21)));
    expect(up.first['dueLabel'], '21 Jul');
    expect(up.first['amountLabel'], '₹649');
  });

  test('epochDay counts local calendar days from 1970', () {
    expect(epochDay(DateTime(1970, 1, 2, 23, 59)), 1);
    expect(epochDay(DateTime(2026, 7, 18, 0, 1)), epochDay(now));
    expect(epochDay(DateTime(2026, 7, 19)) - epochDay(now), 1);
  });
}
