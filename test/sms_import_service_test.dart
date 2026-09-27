import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/notification_source.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/sms_source.dart';

/// The service's incremental-scan watermark must never move past messages
/// that were not scanned — the audit found a short lookback after a long
/// gap did exactly that (permanently skipping the gap).
const _markerKey = 'sms_last_scan_millis';
const _autoRunKey = 'sms_auto_import_last_run_millis';

class FakeSmsSource implements SmsSource {
  List<SmsMessage> inbox = [];
  bool complete = true;

  @override
  bool get isSupported => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<SmsPermission> requestPermission() async => SmsPermission.granted;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<SmsQueryResult> query({
    required DateTime since,
    DateTime? until,
  }) async {
    final msgs = inbox
        .where(
          (m) =>
              m.date.isAfter(since) &&
              (until == null || m.date.isBefore(until)),
        )
        .toList();
    return SmsQueryResult(messages: msgs, complete: complete);
  }
}

class FakeNotificationSource implements NotificationSource {
  List<SmsMessage> buffered = [];
  int maxSeq = -1;
  final acked = <int>[];

  @override
  bool get isSupported => true;

  @override
  Future<bool> hasAccess() async => buffered.isNotEmpty;

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<Map<String, dynamic>> diagnostics() async => const {};

  @override
  Future<DateTime?> lastCapture() async => null;

  @override
  Future<NotificationBatch> peek() async => NotificationBatch(buffered, maxSeq);

  @override
  Future<void> ack(NotificationBatch batch) async => acked.add(batch.maxSeq);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSmsSource source;
  late FakeNotificationSource notifications;
  late SmsImportService service;

  SmsMessage msg(DateTime date) => SmsMessage(
    sender: 'XX-NOBANK-S',
    body: 'not a transaction alert',
    date: date,
  );

  Future<FinanceProvider> finance() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  setUp(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    source = FakeSmsSource();
    notifications = FakeNotificationSource();
    service = SmsImportService(source: source, notifications: notifications);
  });

  group('watermark', () {
    test(
      'a short lookback does NOT jump the marker past an unscanned gap',
      () async {
        final now = DateTime.now();
        final marker = now
            .subtract(const Duration(days: 20))
            .millisecondsSinceEpoch;
        SharedPreferences.setMockInitialValues({_markerKey: marker});
        source.inbox = [msg(now.subtract(const Duration(days: 2)))];

        await service.run(await finance(), lookback: const Duration(days: 7));

        final prefs = await SharedPreferences.getInstance();
        // Days 20→7 were never scanned; the marker must still point at day 20.
        expect(prefs.getInt(_markerKey), marker);
      },
    );

    test('a contiguous incremental scan advances the marker', () async {
      final now = DateTime.now();
      final marker = now
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({_markerKey: marker});
      final newest = now.subtract(const Duration(hours: 1));
      source.inbox = [msg(newest)];

      await service.run(await finance());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_markerKey), newest.millisecondsSinceEpoch);
    });

    test('a wide lookback covering the gap advances the marker', () async {
      final now = DateTime.now();
      final marker = now
          .subtract(const Duration(days: 20))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({_markerKey: marker});
      final newest = now.subtract(const Duration(hours: 1));
      source.inbox = [msg(newest)];

      await service.run(await finance(), lookback: const Duration(days: 30));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_markerKey), newest.millisecondsSinceEpoch);
    });

    test('a truncated (incomplete) scan does not advance the marker', () async {
      final now = DateTime.now();
      final marker = now
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({_markerKey: marker});
      source.inbox = [msg(now.subtract(const Duration(hours: 1)))];
      source.complete = false;

      await service.run(await finance());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_markerKey), marker);
    });

    test(
      'a custom range entirely in the past never advances the marker',
      () async {
        final now = DateTime.now();
        final marker = now
            .subtract(const Duration(days: 2))
            .millisecondsSinceEpoch;
        SharedPreferences.setMockInitialValues({_markerKey: marker});
        source.inbox = [msg(now.subtract(const Duration(days: 10)))];

        await service.run(
          await finance(),
          range: DateTimeRange(
            start: now.subtract(const Duration(days: 15)),
            end: now.subtract(const Duration(days: 8)),
          ),
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(_markerKey), marker);
      },
    );

    test('first run (no marker) records one', () async {
      SharedPreferences.setMockInitialValues({});
      final newest = DateTime.now().subtract(const Duration(hours: 1));
      source.inbox = [msg(newest)];

      await service.run(await finance());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_markerKey), newest.millisecondsSinceEpoch);
    });
  });

  group('auto-run cadence', () {
    test('weekly recovers when the stored last-run is in the future', () async {
      // A clock that jumped forward once wrote a future marker; the plain
      // difference stayed negative and weekly auto-import never fired again.
      final future = DateTime.now().add(const Duration(days: 400));
      SharedPreferences.setMockInitialValues({
        _autoRunKey: future.millisecondsSinceEpoch,
      });

      final result = await service.maybeAutoRun(
        await finance(),
        AutoImportFrequency.weekly,
      );
      expect(result, isNotNull);
    });

    test('weekly does not fire again within the week', () async {
      SharedPreferences.setMockInitialValues({
        _autoRunKey: DateTime.now()
            .subtract(const Duration(days: 2))
            .millisecondsSinceEpoch,
      });
      final result = await service.maybeAutoRun(
        await finance(),
        AutoImportFrequency.weekly,
      );
      expect(result, isNull);
    });
  });
  group('notification buffer', () {
    const body =
        'INR 1,840.00 spent on YES BANK Card xxxx @UPI_NOVA TILES AND N '
        '06-07-2026 03:41:52 pm. Avl Lmt INR 187,264.38. '
        'SMS BLKCC 4417 to 9840909000 if not you';

    test(
      'captured alerts are cleared only once their rows are saved',
      () async {
        SharedPreferences.setMockInitialValues({});
        notifications
          ..buffered = [
            SmsMessage(
              sender: 'Yes Bank',
              body: body,
              date: DateTime(2026, 7, 6),
            ),
          ]
          ..maxSeq = 7;
        final p = await finance();
        expect(await service.drainNotifications(p), 1);
        expect(p.pendingCount, 1);
        expect(notifications.acked, [7]);
      },
    );

    test('a run imports the buffer too and clears it after', () async {
      SharedPreferences.setMockInitialValues({});
      notifications
        ..buffered = [
          SmsMessage(
            sender: 'Yes Bank',
            body: body,
            date: DateTime(2026, 7, 6),
          ),
        ]
        ..maxSeq = 3;
      final result = await service.run(await finance());
      expect(result!.imported, 1);
      expect(notifications.acked, [3]);
    });
  });

  test('Every SMS is due on every run', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await finance();
    expect(
      await service.maybeAutoRun(p, AutoImportFrequency.everySms),
      isNotNull,
    );
    expect(
      await service.maybeAutoRun(p, AutoImportFrequency.everySms),
      isNotNull,
    );
  });
}
