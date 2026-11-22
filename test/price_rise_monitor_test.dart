import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/notification_ids.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/price_rise_monitor.dart';

class _Notifications implements NotificationService {
  final shown = <({int id, String title, String body, String? payload})>[];
  bool enabled = true;

  @override
  Future<void> init() async {}

  @override
  Future<bool> get areEnabled async => enabled;

  @override
  Future<NotificationStatus> get status async => NotificationStatus.enabled;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async => shown.add((id: id, title: title, body: body, payload: payload));

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

  @override
  Future<void> showImportCheck({
    required int id,
    required String title,
    required String body,
    required String payload,
    String? keepLabel,
  }) async {}

  @override
  Future<void> showImportCheckSummary(int count) async {}

  @override
  Future<List<int>> activeImportChecks() async => const [];

  @override
  Future<void> cancelId(int id) async {}
}

/// The subscription price-rise alert. Every name and amount is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FinanceProvider.useIsolateCodec = false;
  });

  // One clock read; payments are dated at noon on earlier days, a month
  // apart, the last one 10 days ago.
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime daysAgo(int n) => DateTime(now.year, now.month, now.day - n, 12);

  Future<(FinanceProvider, SettingsProvider)> withPayments(
    List<double> amounts, {
    String name = 'Streamly',
  }) async {
    final p = FinanceProvider();
    await p.load();
    await p.importTransactions([
      for (final (i, amount) in amounts.indexed)
        Tx(
          id: '${name}_$i',
          type: TxType.expense,
          categoryId: 'bills',
          amount: amount,
          note: name,
          date: daysAgo(10 + 30 * (amounts.length - 1 - i)),
        ),
    ], replace: true);
    final s = SettingsProvider();
    await s.load();
    return (p, s);
  }

  test('a rise fires once, with the new and old price', () async {
    final (p, s) = await withPayments([499, 499, 649]);
    final notes = _Notifications();
    final monitor = PriceRiseMonitor(notifications: notes);
    await monitor.check(p, s);
    expect(notes.shown, hasLength(1));
    final note = notes.shown.single;
    expect(note.id, NotificationIds.priceRise('expense|streamly'));
    expect(note.title, startsWith('Streamly now costs'));
    expect(note.title, contains('649'));
    expect(note.body, startsWith('Was '));
    expect(note.body, contains('499'));
    expect(note.payload, kSubscriptionsPayload);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(PriceRiseMonitor.firedKey('expense|streamly', daysAgo(10)
          .copyWith(hour: 0))),
      isTrue,
    );

    await monitor.check(p, s);
    await PriceRiseMonitor(notifications: notes).check(p, s);
    expect(notes.shown, hasLength(1), reason: 'the marker holds it');
  });

  test('a one-off higher payment is no rise', () async {
    final (p, s) = await withPayments([499, 499, 699, 499]);
    final notes = _Notifications();
    await PriceRiseMonitor(notifications: notes).check(p, s);
    expect(notes.shown, isEmpty);
  });

  test('a steady price and a small change are no rise', () async {
    final (p, s) = await withPayments([499, 499, 499]);
    final notes = _Notifications();
    await PriceRiseMonitor(notifications: notes).check(p, s);
    expect(notes.shown, isEmpty);

    // Under 5%: tax drift.
    final (q, t) = await withPayments([1000, 1000, 1040], name: 'Fibrenet');
    await PriceRiseMonitor(notifications: notes).check(q, t);
    expect(notes.shown, isEmpty);
  });

  test('without notification permission nothing fires and nothing is '
      'marked, so it fires once allowed', () async {
    final (p, s) = await withPayments([499, 499, 649]);
    final notes = _Notifications()..enabled = false;
    final monitor = PriceRiseMonitor(notifications: notes);
    await monitor.check(p, s);
    expect(notes.shown, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((k) => k.startsWith(PriceRiseMonitor.markerPrefix)),
      isEmpty,
    );

    notes.enabled = true;
    await monitor.check(p, s);
    expect(notes.shown, hasLength(1));
  });

  test('the setting off keeps it quiet', () async {
    final (p, s) = await withPayments([499, 499, 649]);
    await s.setPriceRiseAlerts(false);
    final notes = _Notifications();
    await PriceRiseMonitor(notifications: notes).check(p, s);
    expect(notes.shown, isEmpty);
  });

  test('a hidden subscription does not alert', () async {
    final (p, s) = await withPayments([499, 499, 649]);
    await s.hideUpcoming('expense|streamly');
    final notes = _Notifications();
    await PriceRiseMonitor(notifications: notes).check(p, s);
    expect(notes.shown, isEmpty);
  });

  test('the first check sweeps markers older than it keeps', () async {
    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final old = DateTime(
      today.year,
      today.month,
      today.day - PriceRiseMonitor.markerKeepDays - 5,
    );
    final recent = DateTime(today.year, today.month, today.day - 5);
    SharedPreferences.setMockInitialValues({
      '${PriceRiseMonitor.markerPrefix}expense|gone_${ymd(old)}': true,
      '${PriceRiseMonitor.markerPrefix}expense|kept_${ymd(recent)}': true,
      'unrelated_key': true,
    });
    final (p, s) = await withPayments([499, 499, 499]);
    await PriceRiseMonitor(notifications: _Notifications()).check(p, s);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((k) => k.startsWith(PriceRiseMonitor.markerPrefix)),
      ['${PriceRiseMonitor.markerPrefix}expense|kept_${ymd(recent)}'],
    );
    expect(prefs.getBool('unrelated_key'), isTrue);
  });
}
