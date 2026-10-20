import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/reminder_schedule.dart';
import 'package:expense_tracker/services/upcoming_monitor.dart';

class FakeNotifications implements NotificationService {
  bool enabled = true;
  final shown = <(int id, String title, String body)>[];

  @override
  Future<void> init() async {}

  @override
  Future<bool> get areEnabled async => enabled;

  @override
  Future<NotificationStatus> get status async =>
      enabled ? NotificationStatus.enabled : NotificationStatus.appBlocked;

  @override
  Future<bool> requestPermission() async => enabled;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shown.add((id, title, body));
  }

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<void> scheduleRecap(DateTime when, String monthName) async {}

  @override
  Future<void> cancelRecap() async {}

  @override
  Future<void> scheduleWeeklyDigest(
    DateTime when,
    DateTime week,
    String weekLabel,
  ) async {}

  @override
  Future<void> cancelWeeklyDigest() async {}

  @override
  Future<void> showReview(int count) async {}

  @override
  Future<void> cancelReview() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotifications notifications;
  late UpcomingMonitor monitor;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    notifications = FakeNotifications();
    monitor = UpcomingMonitor(notifications: notifications);
  });

  Future<(FinanceProvider, SettingsProvider)> fixture() async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    return (finance, settings);
  }

  test('reminder due today fires once with its own key and id range', () async {
    final (finance, settings) = await fixture();
    final now = DateTime.now();
    final id = await finance.addReminder(
      name: 'Money to home',
      dayOfMonth: now.day,
      expectedAmount: 5000,
      categoryId: 'other_expense',
    );
    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1));
    final (nid, title, body) = notifications.shown.single;
    expect(title, 'Reminder: Money to home');
    expect(body, contains('₹5,000.00'));
    expect(body, contains('due today'));
    expect(nid, inInclusiveRange(96000, 96999));

    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1), reason: 'marker dedupes');
    final due = reminderNextDue(finance.reminders.single, now);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UpcomingMonitor.reminderDueKey(id, due)), isTrue);
  });

  test(
    'marked paid → silent; five days out → silent; toggle off → silent',
    () async {
      final (finance, settings) = await fixture();
      final now = DateTime.now();
      final id = await finance.addReminder(
        name: 'EB bill',
        dayOfMonth: now.day,
        categoryId: 'utilities',
      );
      await finance.markReminderPaid(
        id,
        DateTime(now.year, now.month, now.day),
      );
      await monitor.check(finance, settings);
      expect(notifications.shown, isEmpty, reason: 'paid this month');

      await finance.clearReminderPaid(id);
      // Move the due day five days ahead (wrapping inside the month is fine
      // for the window check: 5 days > reminderWindowDays either way).
      final far = DateTime(now.year, now.month, now.day + 5);
      await finance.updateReminder(
        finance.reminders.single.copyWith(dayOfMonth: far.day),
      );
      if (far.month == now.month) {
        await monitor.check(finance, settings);
        expect(
          notifications.shown,
          isEmpty,
          reason: 'outside the 2-day window',
        );
      }

      await finance.updateReminder(
        finance.reminders.single.copyWith(dayOfMonth: now.day),
      );
      await settings.setUpcomingReminders(false);
      await monitor.check(finance, settings);
      expect(notifications.shown, isEmpty, reason: 'reminders toggle off');
    },
  );

  /// A monthly reminder on [day] with no creation date, so every earlier
  /// month counts (the fixed dates below may sit before the real today).
  Future<String> monthlyReminder(FinanceProvider finance, int day) async {
    final id = await finance.addReminder(
      name: 'Money to home',
      dayOfMonth: day,
      expectedAmount: 5000,
      categoryId: 'other_expense',
    );
    await finance.updateReminder(
      Reminder(
        id: id,
        name: 'Money to home',
        dayOfMonth: day,
        expectedAmount: 5000,
        categoryId: 'other_expense',
      ),
    );
    return id;
  }

  test('an overdue reminder from last month notifies on the 2nd', () async {
    final (finance, settings) = await fixture();
    final id = await monthlyReminder(finance, 30);
    await monitor.check(finance, settings, now: DateTime(2026, 11, 2, 10));
    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.$3, contains('was due on'));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(UpcomingMonitor.reminderDueKey(id, DateTime(2026, 10, 30))),
      isTrue,
    );
  });

  test('an overdue reminder notifies once across months and runs', () async {
    final (finance, settings) = await fixture();
    await monthlyReminder(finance, 30);
    await monitor.check(finance, settings, now: DateTime(2026, 10, 30, 9));
    expect(notifications.shown, hasLength(1));
    // Each background run builds its own monitor, which sweeps afresh.
    for (final day in [DateTime(2026, 11, 1, 6), DateTime(2026, 11, 2, 12)]) {
      await UpcomingMonitor(
        notifications: notifications,
      ).check(finance, settings, now: day);
    }
    expect(notifications.shown, hasLength(1));
  });

  test('a month-keyed marker covers its month until it ages out', () async {
    final (finance, settings) = await fixture();
    final id = await monthlyReminder(finance, 31);
    final legacy = 'reminder_due_fired_${id}_2026-12';
    SharedPreferences.setMockInitialValues({legacy: true});
    // 3 Jan 2027: 31 Dec is 3 days overdue, already notified in December.
    await monitor.check(finance, settings, now: DateTime(2027, 1, 3, 10));
    expect(notifications.shown, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(legacy), isTrue);

    // 41 days after the end of December: swept.
    await UpcomingMonitor(
      notifications: notifications,
    ).check(finance, settings, now: DateTime(2027, 2, 10, 10));
    expect(prefs.getBool(legacy), isNull);
  });

  test('day 31 after February notifies on 1 March for 28 Feb', () async {
    final (finance, settings) = await fixture();
    final id = await monthlyReminder(finance, 31);
    await monitor.check(finance, settings, now: DateTime(2027, 3, 1, 10));
    expect(notifications.shown, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(UpcomingMonitor.reminderDueKey(id, DateTime(2027, 2, 28))),
      isTrue,
    );
  });

  test('old-month reminder markers are swept', () async {
    final (finance, settings) = await fixture();
    SharedPreferences.setMockInitialValues({
      'reminder_due_fired_x_2020-01': true,
    });
    await monitor.check(finance, settings);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('reminder_due_fired_x_2020-01'), isNull);
  });
}
