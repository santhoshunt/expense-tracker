import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/services/upcoming_items.dart';

/// Marking bills paid from the forecast: a reminder's created date, and a
/// detected payment marked paid for one cycle. Amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // 4 October: the bills window reaches back to 27 September.
  final now = DateTime(2026, 10, 4, 10);

  Future<FinanceProvider> load() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  List<DueBill> bills(FinanceProvider p, List<RecurringHit> hits) => billsDue(
    p,
    patterns: hits,
    hidden: const {},
    from: DateTime(2026, 9, 27),
    to: DateTime(2026, 10, 31),
    now: now,
  );

  Reminder broadband({String? createdOn, int day = 30}) => Reminder(
    id: 'bb',
    name: 'Broadband',
    dayOfMonth: day,
    categoryId: 'other_expense',
    expectedAmount: 700,
    createdOn: createdOn,
  );

  group('a reminder made this month', () {
    test('never lists last month as overdue', () async {
      final p = await load();
      await p.restoreReminder(broadband(createdOn: '2026-10-04'));
      final due = bills(p, const []);
      expect(due.map((b) => b.due), [DateTime(2026, 10, 30)]);
      expect(due.single.reminderId, 'bb');
    });

    test('still lists an earlier day of its own month', () async {
      final p = await load();
      await p.restoreReminder(broadband(createdOn: '2026-10-04', day: 2));
      expect(bills(p, const []).map((b) => b.due), [DateTime(2026, 10, 2)]);
    });

    test('one made before 1.32 behaves as before', () async {
      final p = await load();
      await p.restoreReminder(broadband());
      expect(bills(p, const []).map((b) => b.due), [
        DateTime(2026, 9, 30),
        DateTime(2026, 10, 30),
      ]);
    });

    test('addReminder dates it, and JSON keeps the date', () async {
      final p = await load();
      await p.addReminder(
        name: 'Gym',
        dayOfMonth: 5,
        expectedAmount: 1200,
        categoryId: 'other_expense',
      );
      final r = p.reminders.single;
      expect(DateTime.tryParse(r.createdOn ?? ''), isNotNull);
      expect(Reminder.fromJson(r.toJson()).createdOn, r.createdOn);
    });
  });

  group('marking a reminder paid', () {
    test('only moves forward: Oct, then Sep, stays Oct', () async {
      final p = await load();
      await p.restoreReminder(broadband());
      await p.markReminderPaid('bb', DateTime(2026, 10, 30));
      await p.markReminderPaid('bb', DateTime(2026, 9, 30));
      expect(p.reminders.single.lastPaidMonth, '2026-10');
      expect(bills(p, const []), isEmpty);
    });

    test('Undo restores only its own mark', () async {
      final p = await load();
      await p.restoreReminder(broadband());
      await p.markReminderPaid('bb', DateTime(2026, 9, 30));
      // An alert pays October meanwhile: undoing September keeps it.
      await p.markReminderPaid('bb', DateTime(2026, 10, 30));
      await p.undoReminderPaid('bb', marked: '2026-09', previous: null);
      expect(p.reminders.single.lastPaidMonth, '2026-10');
      await p.undoReminderPaid('bb', marked: '2026-10', previous: null);
      expect(p.reminders.single.lastPaidMonth, isNull);
    });
  });

  group('a detected payment marked paid', () {
    /// A ₹499 payment noted "StreamBox" on the 2nd of July, August and
    /// September: next due 2 October, two days overdue on the 4th.
    Future<(FinanceProvider, List<RecurringHit>)> streaming() async {
      final p = await load();
      for (final m in [7, 8, 9]) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'entertainment',
          amount: 499,
          note: 'StreamBox',
          date: DateTime(2026, m, 2, 12),
        );
      }
      final hits = detectRecurringPatterns(p.countedTransactions, now: now);
      return (p, hits);
    }

    test('leaves the bills and Upcoming, and Undo brings it back', () async {
      final (p, hits) = await streaming();
      final hit = hits.single;
      expect(bills(p, hits).single.patternKey, hit.key);

      await p.markPatternPaid(hit.key, hit.nextDue);
      expect(bills(p, hits), isEmpty);
      final upcoming = buildUpcomingItems(
        p,
        hits: hits,
        hidden: const {},
        now: now,
      );
      expect(upcoming.where((u) => u.hideKey == hit.key), isEmpty);

      await p.restorePatternPaid(hit.key, null);
      expect(bills(p, hits).single.patternKey, hit.key);
    });

    test('the next payment moves past the mark', () async {
      final (p, hits) = await streaming();
      await p.markPatternPaid(hits.single.key, hits.single.nextDue);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 499,
        note: 'StreamBox',
        date: DateTime(2026, 10, 3, 12),
      );
      final later = DateTime(2026, 11, 3, 10);
      final next = detectRecurringPatterns(
        p.countedTransactions,
        now: later,
      ).single;
      // Due 2 November: after the 2 October mark, so due again.
      expect(hitMarkedPaid(p, next), isFalse);
    });

    test('a backup carries the marks; a merge keeps the later date', () async {
      final (p, hits) = await streaming();
      await p.markPatternPaid(hits.single.key, DateTime(2026, 10, 2));
      final data = jsonDecode(jsonEncode(p.exportData()));
      expect(data['version'], 21);
      expect(data['patternPaid'], {hits.single.key: '2026-10-02'});

      final other = await load();
      await other.markPatternPaid(hits.single.key, DateTime(2026, 9, 2));
      await other.importData(data as Map<String, dynamic>, replace: false);
      expect(other.patternPaidThrough(hits.single.key), '2026-10-02');
    });
  });

  test('marks older than 70 days are dropped on load', () async {
    SharedPreferences.setMockInitialValues({
      'pattern_paid_v1': jsonEncode({
        'expense|old': '2020-01-01',
        'expense|new': _dayKey(DateTime.now()),
      }),
    });
    final p = await load();
    expect(p.patternPaidThrough('expense|old'), isNull);
    expect(p.patternPaidThrough('expense|new'), isNotNull);
  });
}

String _dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
