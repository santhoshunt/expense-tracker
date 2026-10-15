import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/background_import.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/sms_import_service.dart';

import 'upcoming_monitor_test.dart' show FakeNotifications;

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
/// SMS, the 6-hour check imports only for Daily and Weekly. Every run
/// checks the alerts.
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
    final result = await runBackgroundImport(
      finance,
      settings,
      trigger,
      import: import,
      notify: false,
    );
    expect(result.ok, isTrue);
    return result.imported;
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
    // A notification capture runs as an SMS arrival.
    expect(BackgroundImportScheduler.triggerOf('notif'), BackgroundTrigger.sms);
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

  test("the app's own engine leaves reminder entries to itself", () async {
    final finance = FinanceProvider();
    await finance.load();
    await finance.restoreReminder(
      Reminder(
        id: 'rem',
        name: 'Rent',
        dayOfMonth: 1,
        categoryId: 'other_expense',
        expectedAmount: 100,
        autoAdd: true,
        autoSince: '2020-01-01',
        lastPaidMonth: '2020-01',
      ),
    );
    final settings = SettingsProvider();
    await settings.load();
    await runBackgroundImport(
      finance,
      settings,
      BackgroundTrigger.periodic,
      import: CountingImport(),
      notify: false,
      postReminders: false,
    );
    expect(finance.transactions, isEmpty);
    await runBackgroundImport(
      finance,
      settings,
      BackgroundTrigger.periodic,
      import: CountingImport(),
      notify: false,
    );
    expect(finance.transactions, isNotEmpty);
  });

  group('alerts with the app shut (v1.39.1)', () {
    /// A card billed ₹5,000 due today, with Auto-import Off: no import
    /// runs, but the check must.
    Future<(FinanceProvider, SettingsProvider)> dueCard() async {
      final finance = FinanceProvider();
      await finance.load();
      final settings = SettingsProvider();
      await settings.load();
      await settings.setAutoImport(AutoImportFrequency.off);
      final id = await finance.addAccount(
        name: 'Test Card',
        type: AccountType.creditCard,
      );
      await finance.setManualBalance(id, 5000);
      await finance.setCardCycle(id, dueDay: DateTime.now().day);
      return (finance, settings);
    }

    test('a periodic run notifies a bill due today', () async {
      final (finance, settings) = await dueCard();
      final notes = FakeNotifications();
      final import = CountingImport();
      await runBackgroundImport(
        finance,
        settings,
        BackgroundTrigger.periodic,
        import: import,
        notify: false,
        notifications: notes,
      );
      expect(import.runs, isEmpty, reason: 'Off imports nothing');
      expect(notes.shown, hasLength(1));
      expect(notes.shown.single.$2, contains('bill due today'));

      // A later run, or the app opening, does not repeat it.
      await runBackgroundImport(
        finance,
        settings,
        BackgroundTrigger.periodic,
        import: import,
        notify: false,
        notifications: notes,
      );
      expect(notes.shown, hasLength(1));
    });

    test('a run that pushes spending over the monthly budget alerts', () async {
      final finance = FinanceProvider();
      await finance.load();
      final settings = SettingsProvider();
      await settings.load();
      await settings.setMonthlyBudget(1000);
      final now = DateTime.now();
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1500,
        note: 'test dinner',
        date: DateTime(now.year, now.month, now.day),
      );
      final notes = FakeNotifications();
      await runBackgroundImport(
        finance,
        settings,
        BackgroundTrigger.periodic,
        import: CountingImport(),
        notify: false,
        notifications: notes,
      );
      expect(notes.shown, isNotEmpty);
    });

    test("the app's own engine runs its own checks instead", () async {
      final (finance, settings) = await dueCard();
      final notes = FakeNotifications();
      await runBackgroundImport(
        finance,
        settings,
        BackgroundTrigger.periodic,
        import: CountingImport(),
        notify: false,
        checkAlerts: false,
        notifications: notes,
      );
      expect(notes.shown, isEmpty);
    });
  });
}
