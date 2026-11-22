import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/budget.dart';
import 'package:expense_tracker/services/budget_monitor.dart';
import 'package:expense_tracker/services/notification_ids.dart';
import 'package:expense_tracker/services/unusual_spend_monitor.dart';
import 'package:expense_tracker/services/upcoming_monitor.dart';

import 'upcoming_monitor_test.dart' show FakeNotifications;

/// A posted alert is withdrawn once its reason goes: posted, then settled,
/// then the next run cancels it once; still due, never cancelled; settled
/// before it was posted, no cancel call. Names and amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotifications notes;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    notes = FakeNotifications();
  });

  Future<(FinanceProvider, SettingsProvider)> fixture() async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    return (finance, settings);
  }

  group('UpcomingMonitor', () {
    // Due tomorrow, inside every window.
    final day = DateTime(2026, 10, 19, 10);
    final due = DateTime(2026, 10, 20);

    /// A monthly reminder on the 20th with no creation date, so the fixed
    /// dates count whatever the real today.
    Future<String> reminder(FinanceProvider finance) async {
      final id = await finance.addReminder(
        name: 'Test tuition',
        dayOfMonth: 20,
        expectedAmount: 3700,
        categoryId: 'other_expense',
      );
      await finance.updateReminder(
        Reminder(
          id: id,
          name: 'Test tuition',
          dayOfMonth: 20,
          expectedAmount: 3700,
          categoryId: 'other_expense',
        ),
      );
      return id;
    }

    Future<void> run(FinanceProvider f, SettingsProvider s) =>
        UpcomingMonitor(notifications: notes).check(f, s, now: day);

    test('a reminder paid, unpaid, paid: withdrawn, posted, withdrawn, '
        'each once', () async {
      final (finance, settings) = await fixture();
      final id = await reminder(finance);
      final key = UpcomingMonitor.reminderDueKey(id, due);
      final prefs = await SharedPreferences.getInstance();
      await run(finance, settings);
      expect(notes.shown, hasLength(1));

      await finance.markReminderPaid(id, due);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.cancelled, [NotificationIds.reminder(id)]);
      expect(prefs.getBool(key), isFalse);

      // Paid was a mistake: owed again, so it is posted again, once.
      await finance.clearReminderPaid(id);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.shown, hasLength(2));
      expect(notes.shown.last.$1, NotificationIds.reminder(id));
      expect(prefs.getBool(key), isTrue);
      expect(notes.cancelled, hasLength(1));

      // Paid for real: withdrawn again, once.
      await finance.markReminderPaid(id, due);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.cancelled, List.filled(2, NotificationIds.reminder(id)));
      expect(notes.shown, hasLength(2));
    });

    test('a deleted reminder is withdrawn once', () async {
      final (finance, settings) = await fixture();
      final id = await reminder(finance);
      await run(finance, settings);
      await finance.deleteReminder(id);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.cancelled, [NotificationIds.reminder(id)]);
    });

    test('a reminder still due is never withdrawn', () async {
      final (finance, settings) = await fixture();
      await reminder(finance);
      for (var i = 0; i < 3; i++) {
        await run(finance, settings);
      }
      expect(notes.shown, hasLength(1));
      expect(notes.cancelled, isEmpty);
    });

    test('paid before it was ever posted: no cancel call', () async {
      final (finance, settings) = await fixture();
      final id = await reminder(finance);
      notes.enabled = false;
      await run(finance, settings);
      await finance.markReminderPaid(id, due);
      notes.enabled = true;
      await run(finance, settings);
      expect(notes.shown, isEmpty);
      expect(notes.cancelled, isEmpty);
    });

    test('a card bill marked paid is withdrawn once', () async {
      final (finance, settings) = await fixture();
      final id = await finance.addAccount(
        name: 'Test card',
        type: AccountType.creditCard,
      );
      await finance.setManualBalance(id, 4100);
      await finance.setCardCycle(id, dueDay: 20);
      await run(finance, settings);
      expect(notes.shown.single.$2, startsWith('Test card bill due'));

      await run(finance, settings);
      expect(notes.cancelled, isEmpty, reason: 'still owed');
      await finance.markCardBillPaid(id, due);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.cancelled, [NotificationIds.cardBill(id)]);

      // Mark unpaid: owed again, posted again once; paid again, withdrawn
      // again once.
      await finance.clearCardBillPaid(id);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.shown, hasLength(2));
      await finance.markCardBillPaid(id, due);
      await run(finance, settings);
      await run(finance, settings);
      expect(notes.cancelled, List.filled(2, NotificationIds.cardBill(id)));
    });

    test('a recurring payment that arrived is withdrawn once', () async {
      final (finance, settings) = await fixture();
      Future<void> pay(DateTime d) => finance.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 389,
        note: 'Test club',
        date: d,
      );
      // Every 30 days: next expected on 1 Oct.
      for (final d in [
        DateTime(2026, 7, 3),
        DateTime(2026, 8, 2),
        DateTime(2026, 9, 1),
      ]) {
        await pay(d);
      }
      final early = DateTime(2026, 9, 30, 10);
      await UpcomingMonitor(
        notifications: notes,
      ).check(finance, settings, now: early);
      expect(notes.shown, hasLength(1));

      await pay(DateTime(2026, 10, 1, 9));
      final later = DateTime(2026, 10, 1, 12);
      for (var i = 0; i < 2; i++) {
        await UpcomingMonitor(
          notifications: notes,
        ).check(finance, settings, now: later);
      }
      expect(notes.cancelled, [NotificationIds.recurring('expense|test club')]);
      expect(notes.shown, hasLength(1));
    });

    test('an occurrence past the tracked window is left alone', () async {
      final (finance, settings) = await fixture();
      // Announced for 1 Oct, nothing tracks it on 19 Oct.
      SharedPreferences.setMockInitialValues({
        UpcomingMonitor.reminderDueKey('gone', DateTime(2026, 10, 1)): true,
      });
      await run(finance, settings);
      expect(notes.cancelled, isEmpty);
    });
  });

  group('BudgetMonitor', () {
    // The monitor's own clock, fixed, so no run straddles a month end.
    final now = DateTime(2026, 10, 15, 10);

    BudgetMonitor monitorAt() =>
        BudgetMonitor(notifications: notes, clock: () => now);

    Future<String> spend(FinanceProvider finance, double amount) =>
        finance.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: amount,
          note: 'test groceries',
          date: DateTime(now.year, now.month, 1),
        );

    test('the cap back under its level is withdrawn once', () async {
      final (finance, settings) = await fixture();
      await settings.setMonthlyBudget(1000);
      final row = await spend(finance, 850);
      final monitor = monitorAt();
      await monitor.check(finance, settings);
      expect(notes.shown, hasLength(1));

      await monitor.check(finance, settings);
      expect(notes.cancelled, isEmpty, reason: 'still at 85%');
      await finance.deleteTransaction(row);
      await monitor.check(finance, settings);
      await monitor.check(finance, settings);
      expect(notes.cancelled, [NotificationIds.cap(now.month)]);

      // Over the level again this month: that crossing was announced, so
      // nothing posts and nothing is cancelled again.
      await spend(finance, 850);
      await monitor.check(finance, settings);
      await monitor.check(finance, settings);
      expect(notes.shown, hasLength(1));
      expect(notes.cancelled, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(budgetAlertMonthKey(now)), 80);
    });

    test('a deleted budget is withdrawn once, by a fresh monitor too', () async {
      final (finance, settings) = await fixture();
      await spend(finance, 920);
      final id = await finance.addBudget(
        name: 'Test home',
        limit: 1000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );
      await monitorAt().check(finance, settings);
      expect(notes.shown, hasLength(1));

      await finance.deleteBudget(id);
      // A background run builds its own monitor.
      await monitorAt().check(finance, settings);
      await monitorAt().check(finance, settings);
      expect(notes.cancelled, [NotificationIds.customBudget(id)]);
    });

    test('deleted before it was ever posted: no cancel call', () async {
      final (finance, settings) = await fixture();
      await spend(finance, 920);
      final id = await finance.addBudget(
        name: 'Test home',
        limit: 1000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );
      final monitor = monitorAt();
      notes.enabled = false;
      await monitor.check(finance, settings);
      await finance.deleteBudget(id);
      notes.enabled = true;
      await monitor.check(finance, settings);
      expect(notes.shown, isEmpty);
      expect(notes.cancelled, isEmpty);
    });
  });

  group('UnusualSpendMonitor', () {
    final now = DateTime(2025, 12, 20, 10);
    final december = DateTime(2025, 12);

    /// Food at ₹4,000 a month July to November, then ₹6,000 in December:
    /// unusual. Returns December's row.
    Future<String> ledger(FinanceProvider p) async {
      for (var m = 7; m <= 11; m++) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 4000,
          note: 'test food',
          date: DateTime(2025, m, 5),
        );
      }
      return p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 6000,
        note: 'test food',
        date: DateTime(2025, 12, 3),
      );
    }

    UnusualSpendMonitor monitor() =>
        UnusualSpendMonitor(notifications: notes, clock: () => now);

    test('a category no longer unusual is withdrawn once', () async {
      final (finance, settings) = await fixture();
      final row = await ledger(finance);
      final m = monitor();
      await m.check(finance, settings);
      expect(notes.shown, hasLength(1));
      await m.check(finance, settings);
      expect(notes.cancelled, isEmpty, reason: 'still unusual');

      await finance.deleteTransaction(row);
      await m.check(finance, settings);
      await m.check(finance, settings);
      expect(notes.cancelled, [UnusualSpendMonitor.notificationId('food')]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(UnusualSpendMonitor.firedKey('food', december)),
        isFalse,
      );

      // Unusual again this month: that crossing was announced, so nothing
      // posts and nothing is cancelled again.
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 6000,
        note: 'test food',
        date: DateTime(2025, 12, 4),
      );
      await m.check(finance, settings);
      await m.check(finance, settings);
      expect(notes.shown, hasLength(1));
      expect(notes.cancelled, hasLength(1));
    });

    test('settled before it was ever posted: no cancel call', () async {
      final (finance, settings) = await fixture();
      final row = await ledger(finance);
      final m = monitor();
      notes.enabled = false;
      await m.check(finance, settings);
      await finance.deleteTransaction(row);
      notes.enabled = true;
      await m.check(finance, settings);
      expect(notes.shown, isEmpty);
      expect(notes.cancelled, isEmpty);
    });
  });
}
