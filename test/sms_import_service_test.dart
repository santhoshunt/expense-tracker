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
  @override
  bool get isSupported => true;

  @override
  Future<bool> hasAccess() async => false;

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<Map<String, dynamic>> diagnostics() async => const {};

  @override
  Future<DateTime?> lastCapture() async => null;

  @override
  Future<List<SmsMessage>> drain() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSmsSource source;
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
    service = SmsImportService(
      source: source,
      notifications: FakeNotificationSource(),
    );
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
}
