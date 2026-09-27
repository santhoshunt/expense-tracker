import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/background_import.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/sms_import_service.dart';

class CountingImport extends SmsImportService {
  int drains = 0;
  final runs = <AutoImportFrequency>[];

  @override
  Future<int> drainNotifications(FinanceProvider finance) async {
    drains++;
    return 1;
  }

  @override
  Future<SmsImportResult?> maybeAutoRun(
    FinanceProvider finance,
    AutoImportFrequency frequency,
  ) async {
    runs.add(frequency);
    return const SmsImportResult(
      scanned: 2,
      matched: 2,
      imported: 2,
      spamDropped: 0,
    );
  }
}

/// Background runs follow the Auto-import setting: an SMS wakes only Every
/// SMS, the 6-hour check only Daily and Weekly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<int> runWith(
    AutoImportFrequency mode,
    BackgroundTrigger trigger,
    CountingImport import,
  ) async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    await settings.setAutoImport(mode);
    return runBackgroundImport(
      finance,
      settings,
      trigger,
      import: import,
      notify: false,
    );
  }

  for (final (mode, trigger, runs) in [
    (AutoImportFrequency.everySms, BackgroundTrigger.sms, true),
    (AutoImportFrequency.everySms, BackgroundTrigger.periodic, false),
    (AutoImportFrequency.daily, BackgroundTrigger.periodic, true),
    (AutoImportFrequency.weekly, BackgroundTrigger.periodic, true),
    (AutoImportFrequency.daily, BackgroundTrigger.sms, false),
    (AutoImportFrequency.everyOpen, BackgroundTrigger.periodic, false),
    (AutoImportFrequency.off, BackgroundTrigger.sms, false),
    (AutoImportFrequency.off, BackgroundTrigger.periodic, false),
  ]) {
    test(
      '${mode.name} on ${trigger.name} ${runs ? 'imports' : 'waits'}',
      () async {
        final import = CountingImport();
        final imported = await runWith(mode, trigger, import);
        expect(imported, runs ? 3 : 0);
        expect(import.drains, runs ? 1 : 0);
        expect(import.runs, runs ? [mode] : isEmpty);
      },
    );
  }

  test('the worker trigger name maps both ways', () {
    expect(BackgroundImportScheduler.triggerOf('sms'), BackgroundTrigger.sms);
    expect(
      BackgroundImportScheduler.triggerOf('periodic'),
      BackgroundTrigger.periodic,
    );
    expect(
      BackgroundImportScheduler.triggerOf(null),
      BackgroundTrigger.periodic,
    );
  });

  test('tapping the review note opens the review list', () {
    LaunchActions.instance.resetForTest();
    LaunchActions.instance.onNotificationPayload(kReviewPayload);
    expect(LaunchActions.instance.pending.value, LaunchAction.openReview);
    LaunchActions.instance.resetForTest();
  });

  test('Every SMS persists by name', () async {
    final s = SettingsProvider();
    await s.load();
    await s.setAutoImport(AutoImportFrequency.everySms);
    final again = SettingsProvider();
    await again.load();
    expect(again.autoImport, AutoImportFrequency.everySms);
    expect(again.toBackupMap()['autoImport'], 'everySms');
  });
}
