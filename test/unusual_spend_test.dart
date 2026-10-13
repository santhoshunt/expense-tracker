import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/spend_history.dart';
import 'package:expense_tracker/services/unusual_spend.dart';
import 'package:expense_tracker/services/unusual_spend_monitor.dart';
import 'package:expense_tracker/utils/format.dart';

class FakeNotifications implements NotificationService {
  bool enabled = true;
  final shown = <(int id, String title, String body, String? payload)>[];

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
    shown.add((id, title, body, payload));
  }

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<void> scheduleRecap(DateTime when, String monthName) async {}

  @override
  Future<void> cancelRecap() async {}

  @override
  Future<void> showReview(int count) async {}

  @override
  Future<void> cancelReview() async {}
}

/// The unusual spending alert: its rule, the categories it lists, and the
/// monitor that notifies. The clock is fixed at 20 Dec 2025 and every row
/// sits in fixed past months; amounts and notes are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2025, 12, 20, 10);
  final december = DateTime(2025, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    LaunchActions.instance.resetForTest();
  });

  /// July to November 2025 on record from the 1st, so December's usual
  /// month is the middle of five whole months. In December:
  /// - Food & Dining at ₹6,000 against a usual ₹4,000: listed.
  /// - Shopping at ₹4,400 against ₹3,000 (1.47 times): not listed.
  /// - Transport at ₹900, under the ₹1,000 floor: not listed.
  /// - Education at ₹1,500, spent once in August and never since, so its
  ///   usual is zero: listed.
  Future<FinanceProvider> ledger({double decemberFood = 6000}) async {
    final p = FinanceProvider();
    await p.load();
    Future<void> add(String category, double amount, DateTime date) =>
        p.addTransaction(
          type: TxType.expense,
          categoryId: category,
          amount: amount,
          note: 'test $category',
          date: date,
        );
    for (var m = 7; m <= 11; m++) {
      await add('transport', 100, DateTime(2025, m, 1));
      await add('food', 4000, DateTime(2025, m, 5));
      await add('shopping', 3000, DateTime(2025, m, 8));
    }
    await add('education', 500, DateTime(2025, 8, 12));
    await add('food', decemberFood, DateTime(2025, 12, 3));
    await add('shopping', 4400, DateTime(2025, 12, 4));
    await add('transport', 900, DateTime(2025, 12, 6));
    await add('education', 1500, DateTime(2025, 12, 9));
    return p;
  }

  Future<SettingsProvider> settings() async {
    final s = SettingsProvider();
    await s.load();
    return s;
  }

  group('isUnusualSpend', () {
    test('needs 1.5 times the usual month', () {
      expect(isUnusualSpend(6000, 4000), isTrue);
      expect(isUnusualSpend(5999, 4000), isFalse);
    });

    test('needs ₹1,000 over the usual month', () {
      expect(isUnusualSpend(2000, 1000), isTrue);
      expect(isUnusualSpend(1999, 1000), isFalse);
    });

    test('a usual of zero counts from ₹1,000; no usual never does', () {
      expect(isUnusualSpend(1000, 0), isTrue);
      expect(isUnusualSpend(999, 0), isFalse);
      expect(isUnusualSpend(50000, null), isFalse);
    });
  });

  group('unusualCategories', () {
    test('lists only the categories over both lines, biggest first', () async {
      final p = await ledger();
      final found = unusualCategories(p, now: now);
      expect([for (final c in found) c.id], ['food', 'education']);
      expect(found.first.label, 'Food & Dining');
      expect(found.first.spent, 6000);
      expect(found.first.usual, 4000);
      expect(found.last.usual, 0);
    });

    test("its usual is the history sheet's Usual month", () async {
      final p = await ledger();
      final food = unusualCategories(p, now: now).first;
      final sheet = buildSpendHistory(
        p,
        subject: const HistorySubject.category('food', 'Food & Dining'),
        months: [for (var m = 1; m <= 12; m++) DateTime(2025, m)],
        now: now,
      );
      expect(food.usual, sheet.usual);
      expect(food.spent, sheet.anchorAmount);
    });

    test('skips the ids it is told to', () async {
      final p = await ledger();
      final found = unusualCategories(p, now: now, skip: {'food'});
      expect([for (final c in found) c.id], ['education']);
    });

    test('fewer than two whole months: nothing to compare', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 300,
        note: 'test food',
        date: DateTime(2025, 11, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 9000,
        note: 'test food',
        date: DateTime(2025, 12, 2),
      );
      expect(unusualCategories(p, now: now), isEmpty);
    });
  });

  group('unusualAlertText', () {
    test('names the month and the usual month', () {
      final t = unusualAlertText(
        const UnusualCategory(
          id: 'food',
          label: 'Food & Dining',
          spent: 6000,
          usual: 4000,
        ),
        december,
      );
      expect(t.title, 'Food & Dining is above usual');
      expect(
        t.body,
        '${fmtMoney(6000)} so far in December. A usual month is '
        '${fmtMoney(4000)}.',
      );
    });

    test('a usual of zero says most months have none', () {
      final t = unusualAlertText(
        const UnusualCategory(
          id: 'education',
          label: 'Education',
          spent: 1500,
          usual: 0,
        ),
        december,
      );
      expect(
        t.body,
        '${fmtMoney(1500)} so far in December. Most months have none.',
      );
    });
  });

  group('UnusualSpendMonitor', () {
    late FakeNotifications notifications;
    late UnusualSpendMonitor monitor;

    setUp(() {
      notifications = FakeNotifications();
      monitor = UnusualSpendMonitor(
        notifications: notifications,
        clock: () => now,
      );
    });

    test('alerts each category once a month, with its payload', () async {
      final p = await ledger();
      final s = await settings();
      await monitor.check(p, s);
      expect(
        [for (final n in notifications.shown) n.$2],
        ['Food & Dining is above usual', 'Education is above usual'],
      );
      expect(notifications.shown.first.$4, unusualPayload('food', december));
      expect(
        notifications.shown.last.$3,
        '${fmtMoney(1500)} so far in December. Most months have none.',
      );
      expect(
        notifications.shown.first.$1,
        UnusualSpendMonitor.notificationId('food'),
      );

      await monitor.check(p, s);
      expect(notifications.shown, hasLength(2), reason: 'markers dedupe');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(UnusualSpendMonitor.firedKey('food', december)),
        isTrue,
      );
    });

    test('a category crossing later still alerts', () async {
      final p = await ledger(decemberFood: 5000);
      final s = await settings();
      await monitor.check(p, s);
      expect(
        [for (final n in notifications.shown) n.$2],
        ['Education is above usual'],
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1200,
        note: 'test food',
        date: DateTime(2025, 12, 15),
      );
      await monitor.check(p, s);
      expect(notifications.shown.last.$2, 'Food & Dining is above usual');
      expect(notifications.shown, hasLength(2));
    });

    test('notifications off: no marker, so it fires once on', () async {
      final p = await ledger();
      final s = await settings();
      notifications.enabled = false;
      await monitor.check(p, s);
      expect(notifications.shown, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(UnusualSpendMonitor.firedKey('food', december)),
        isNull,
      );

      notifications.enabled = true;
      await monitor.check(p, s);
      expect(notifications.shown, hasLength(2));
    });

    test('the switch off sends nothing', () async {
      final p = await ledger();
      final s = await settings();
      await s.setUnusualAlerts(false);
      await monitor.check(p, s);
      expect(notifications.shown, isEmpty);
    });

    test('concurrent checks alert once', () async {
      final p = await ledger();
      final s = await settings();
      await Future.wait([monitor.check(p, s), monitor.check(p, s)]);
      expect(notifications.shown, hasLength(2));
    });

    test("sweeps earlier months' markers, keeps this month's", () async {
      SharedPreferences.setMockInitialValues({
        UnusualSpendMonitor.firedKey('food', DateTime(2025, 11)): true,
        UnusualSpendMonitor.firedKey('food', december): true,
      });
      final p = await ledger();
      final s = await settings();
      await monitor.check(p, s);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey(
          UnusualSpendMonitor.firedKey('food', DateTime(2025, 11)),
        ),
        isFalse,
      );
      // December's food marker stood, so only Education alerted.
      expect(
        [for (final n in notifications.shown) n.$2],
        ['Education is above usual'],
      );
    });

    test('clearAll removes the markers', () async {
      final p = await ledger();
      final s = await settings();
      await monitor.check(p, s);
      await p.clearAll();
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where(
          (k) => k.startsWith(UnusualSpendMonitor.markerPrefix),
        ),
        isEmpty,
      );
    });
  });

  group('the setting', () {
    test('is on by default and travels in backups', () async {
      final s = await settings();
      expect(s.unusualAlerts, isTrue);
      await s.setUnusualAlerts(false);
      final map = s.toBackupMap();
      expect(map['unusualAlerts'], isFalse);

      SharedPreferences.setMockInitialValues({});
      final fresh = await settings();
      expect(fresh.unusualAlerts, isTrue);
      await fresh.applyBackupMap(map);
      expect(fresh.unusualAlerts, isFalse);
      final reloaded = await settings();
      expect(reloaded.unusualAlerts, isFalse, reason: 'restore persists');
    });
  });

  group('the payload', () {
    test('carries the month and the id, ids with colons included', () {
      expect(unusualPayload('food', december), 'unusual:2025-12:food');
      final h = parseUnusualPayload(
        unusualPayload('cat_1:x', DateTime(2026, 3)),
      );
      expect(h?.categoryId, 'cat_1:x');
      expect(h?.month, DateTime(2026, 3));
    });

    test('holds the category and month for one take', () {
      LaunchActions.instance.onNotificationPayload(
        unusualPayload('food', december),
      );
      expect(
        LaunchActions.instance.pending.value,
        LaunchAction.openCategoryHistory,
      );
      final h = LaunchActions.instance.takeHistory();
      expect(h?.categoryId, 'food');
      expect(h?.month, december);
      expect(LaunchActions.instance.takeHistory(), isNull);
    });

    test('a cold start from the alert holds it too', () async {
      LaunchActions.instance.resetForTest();
      await LaunchActions.instance.init(
        coldNotificationPayload: () async => unusualPayload('food', december),
      );
      expect(
        LaunchActions.instance.pending.value,
        LaunchAction.openCategoryHistory,
      );
      expect(LaunchActions.instance.takeHistory()?.categoryId, 'food');
    });

    test('malformed payloads are ignored', () {
      for (final p in [
        kUnusualPayloadPrefix,
        '${kUnusualPayloadPrefix}food',
        '${kUnusualPayloadPrefix}2025-13:food',
        '${kUnusualPayloadPrefix}2025-12:',
      ]) {
        LaunchActions.instance.onNotificationPayload(p);
        expect(LaunchActions.instance.pending.value, isNull, reason: p);
        expect(LaunchActions.instance.takeHistory(), isNull, reason: p);
      }
    });
  });
}
