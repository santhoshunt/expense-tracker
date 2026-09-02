import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/budget.dart';
import 'package:expense_tracker/services/budget_monitor.dart';
import 'package:expense_tracker/services/notification_service.dart';

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
  late BudgetMonitor monitor;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    notifications = FakeNotifications();
    monitor = BudgetMonitor(notifications: notifications);
  });

  Future<(FinanceProvider, SettingsProvider)> fixture({
    double cap = 1000,
    double spent = 850,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    await settings.setMonthlyBudget(cap);
    if (spent > 0) {
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: spent,
        note: '',
        date: DateTime.now(),
      );
    }
    return (finance, settings);
  }

  test('fires the 80% alert exactly once per month', () async {
    final (finance, settings) = await fixture();
    await monitor.check(finance, settings);
    expect(notifications.shown.length, 1);

    await monitor.check(finance, settings);
    expect(notifications.shown.length, 1, reason: 'marker dedupes the level');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(budgetAlertMonthKey(DateTime.now())), 80);
  });

  test('disabled notifications: bails WITHOUT recording the level', () async {
    final (finance, settings) = await fixture();
    notifications.enabled = false;
    await monitor.check(finance, settings);
    expect(notifications.shown, isEmpty);

    // The level must not be burned — once permission arrives, it fires.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(budgetAlertMonthKey(DateTime.now())), isNull);

    notifications.enabled = true;
    await monitor.check(finance, settings);
    expect(notifications.shown.length, 1);
  });

  test('concurrent checks coalesce to one alert', () async {
    final (finance, settings) = await fixture();
    await Future.wait([
      monitor.check(finance, settings),
      monitor.check(finance, settings),
    ]);
    expect(notifications.shown.length, 1);
  });

  test(
    'custom budget alerts fire and updateBudget clears its marker',
    () async {
      final (finance, settings) = await fixture(cap: 0, spent: 850);
      final id = await finance.addBudget(
        name: 'Personal',
        limit: 1000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );

      await monitor.check(finance, settings);
      expect(notifications.shown.length, 1);
      final prefs = await SharedPreferences.getInstance();
      final key = customBudgetAlertKey(id, DateTime.now());
      expect(prefs.getInt(key), 80);

      // Editing the budget resets the month's marker so the monitor
      // re-evaluates against the new limit.
      final budget = finance.budgets.single;
      await finance.updateBudget(budget.copyWith(limit: 900));
      expect(prefs.getInt(key), isNull);
    },
  );
}
