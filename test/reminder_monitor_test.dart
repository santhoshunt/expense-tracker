import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  }) async {
    shown.add((id, title, body));
  }
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
