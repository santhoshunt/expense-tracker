import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/upcoming_monitor.dart';
import 'package:expense_tracker/utils/dates.dart';

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

  /// A card with a due day of today and a manual outstanding of ₹5000.
  Future<(FinanceProvider, SettingsProvider, String)> cardFixture() async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    final id = await finance.addAccount(
      name: 'HDFC Card',
      type: AccountType.creditCard,
    );
    await finance.setManualBalance(id, 5000); // outstanding for cards
    await finance.setCardCycle(id, dueDay: DateTime.now().day);
    return (finance, settings, id);
  }

  test('card bill due today fires exactly once per cycle', () async {
    final (finance, settings, id) = await cardFixture();
    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.$2, contains('bill due today'));

    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1), reason: 'marker dedupes');

    final due = nextMonthlyOccurrence(DateTime.now().day, DateTime.now());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UpcomingMonitor.cardDueKey(id, due)), isTrue);
  });

  test('reminders toggle off suppresses everything', () async {
    final (finance, settings, _) = await cardFixture();
    await settings.setUpcomingReminders(false);
    await monitor.check(finance, settings);
    expect(notifications.shown, isEmpty);
  });

  test('disabled notifications: bails WITHOUT recording the marker', () async {
    final (finance, settings, id) = await cardFixture();
    notifications.enabled = false;
    await monitor.check(finance, settings);
    expect(notifications.shown, isEmpty);

    final due = nextMonthlyOccurrence(DateTime.now().day, DateTime.now());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UpcomingMonitor.cardDueKey(id, due)), isNull);

    notifications.enabled = true;
    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1));
  });

  test('card with no dues stays quiet', () async {
    final (finance, settings, id) = await cardFixture();
    await finance.setManualBalance(id, 0);
    notifications.shown.clear();
    await monitor.check(finance, settings);
    expect(notifications.shown, isEmpty);
  });

  test('recurring payment due today fires once, hidden key never', () async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    final now = DateTime.now();
    for (final daysAgo in [90, 60, 30]) {
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 649,
        note: 'Netflix',
        date: DateTime(now.year, now.month, now.day - daysAgo),
      );
    }

    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.$2, contains('Netflix'));
    await monitor.check(finance, settings);
    expect(notifications.shown, hasLength(1));

    // Hiding the pattern suppresses its reminder (fresh monitor + markers).
    SharedPreferences.setMockInitialValues({});
    await settings.hideUpcoming('expense|netflix');
    notifications.shown.clear();
    await UpcomingMonitor(
      notifications: notifications,
    ).check(finance, settings);
    expect(notifications.shown, isEmpty);
  });

  test('concurrent checks coalesce', () async {
    final (finance, settings, _) = await cardFixture();
    await Future.wait([
      monitor.check(finance, settings),
      monitor.check(finance, settings),
    ]);
    expect(notifications.shown, hasLength(1));
  });
}
