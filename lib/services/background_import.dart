import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import 'budget_monitor.dart';
import 'budget_widget_service.dart';
import 'home_widgets_service.dart';
import 'notification_service.dart';
import 'sms_import_service.dart';
import 'unusual_spend_monitor.dart';
import 'upcoming_monitor.dart';

/// What woke the background import (SmsImportWorker.kt).
enum BackgroundTrigger {
  /// A new SMS arrived; runs only in [AutoImportFrequency.everySms].
  sms,

  /// The 6-hour check; runs [AutoImportFrequency.daily] and
  /// [AutoImportFrequency.weekly] when their cadence is due.
  periodic,
}

/// The review notification appears once more rows than this wait.
const int kReviewNotifyThreshold = 5;

/// The native side of background import: WorkManager scheduling, the SMS
/// receiver switch, and the hand-off between the app's engine and the
/// headless one. Only one Dart isolate may hold the ledger at a time
/// (FinanceProvider rewrites the whole store from memory), so the app's
/// [awaitIdle] waits for a headless run to finish before anything loads.
class BackgroundImportScheduler {
  static const channel = MethodChannel('expense_tracker/background');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Runs an import in the app's own engine when the worker finds it alive.
  /// Home sets it while mounted; null answers "busy" and the worker retries.
  static Future<BackgroundImportResult?> Function(BackgroundTrigger trigger)?
  runImportHandler;

  static bool _listening = false;

  /// Answers the worker's `runImport` calls on the app's engine.
  static void listen() {
    if (_listening || !_android) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'runImport') return null;
      final handler = runImportHandler;
      if (handler == null) return 'busy';
      final result = await handler(triggerOf(call.arguments));
      if (result == null) return 'busy';
      return result.ok ? result.imported : 'failed';
    });
  }

  /// 'sms' and 'notif' (an alert captured from a notification) both run
  /// as an SMS arrival.
  static BackgroundTrigger triggerOf(Object? name) =>
      name == 'sms' || name == 'notif'
      ? BackgroundTrigger.sms
      : BackgroundTrigger.periodic;

  /// Books or cancels the periodic check and switches the SMS receiver on
  /// or off to match [mode]. Safe to repeat; runs on start and on change.
  static Future<void> apply(AutoImportFrequency mode) async {
    if (!_android) return;
    try {
      await channel.invokeMethod<void>('configure', {'mode': mode.name});
    } on MissingPluginException {
      // Tests and the headless engine have no scheduler.
    } on PlatformException catch (e) {
      debugPrint('Background import configure failed: $e');
    }
  }

  /// Asks for the Receive SMS permission Every SMS needs (Read SMS rides
  /// along). True when both are granted.
  static Future<bool> requestReceiveSms() async {
    if (!_android) return false;
    try {
      return await channel.invokeMethod<bool>('requestReceiveSms') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Returns once no headless run holds the ledger. The native side gives
  /// up after a minute, so a stuck run cannot keep the app from opening.
  static Future<void> awaitIdle() async {
    if (!_android) return;
    try {
      await channel
          .invokeMethod<void>('awaitIdle')
          .timeout(const Duration(seconds: 70));
    } catch (e) {
      debugPrint('awaitIdle: $e');
    }
  }

  /// The headless engine asks which trigger started it.
  static Future<BackgroundTrigger> takeTrigger() async {
    try {
      return triggerOf(await channel.invokeMethod<String>('takeTrigger'));
    } catch (_) {
      return BackgroundTrigger.periodic;
    }
  }

  /// The headless engine reports back, so the worker can finish. [ok] false
  /// (the ledger did not load, or the import threw) keeps the alerts queued
  /// behind this run from counting as read.
  static Future<void> finished(int imported, {required bool ok}) async {
    try {
      await channel.invokeMethod<void>('finished', {
        'imported': imported,
        'ok': ok,
      });
    } catch (e) {
      debugPrint('Background import finish failed: $e');
    }
  }
}

/// One background import: the SMS inbox and captured notifications into the
/// ledger, as the Auto-import setting allows for [trigger]. Sure rows count
/// at once; the rest wait pending in review. [syncWidgets] refreshes the
/// home-screen widgets (the headless engine has no Home screen listening
/// for changes); [notify] posts or
/// clears the review notification. Never throws: [BackgroundImportResult.ok]
/// is false when the import failed part-way.
Future<BackgroundImportResult> runBackgroundImport(
  FinanceProvider finance,
  SettingsProvider settings,
  BackgroundTrigger trigger, {
  required SmsImportService import,
  bool syncWidgets = false,
  bool notify = true,
  bool postReminders = true,
  bool checkAlerts = true,
  NotificationService? notifications,
}) async {
  var imported = 0;
  // Of [imported], the rows that wait in review rather than counted at once.
  var toReview = 0;
  var ok = true;
  final mode = settings.autoImport;
  final runs = switch (trigger) {
    BackgroundTrigger.sms => mode == AutoImportFrequency.everySms,
    BackgroundTrigger.periodic =>
      mode == AutoImportFrequency.daily || mode == AutoImportFrequency.weekly,
  };
  if (runs) {
    try {
      final drained = await import.drainNotifications(finance);
      imported += drained;
      toReview += drained == 0 ? 0 : drained - import.lastDrainCounted;
      final run = await import.maybeAutoRun(finance, mode);
      imported += run?.imported ?? 0;
      toReview += run?.toReview ?? 0;
    } catch (e) {
      ok = false;
      debugPrint('Background import failed: $e');
    }
  }
  // Add it for me reminders due while the app was shut, before the widgets
  // read the totals. Not over a ledger that failed to load. The app's own
  // engine passes [postReminders] false and adds them itself, with the toast
  // that offers Remove.
  if (postReminders && finance.loadWarnings.isEmpty) {
    try {
      await finance.postDueReminders(DateTime.now());
    } catch (e) {
      // The import itself still ran; the next open retries these.
      debugPrint('Background reminder entries failed: $e');
    }
  }
  if (syncWidgets) {
    try {
      await BudgetWidgetService().sync(finance, settings);
      await HomeWidgetsService().sync(finance, settings);
    } catch (e) {
      debugPrint('Background widget sync failed: $e');
    }
  }
  if (notify) {
    // Only new rows that wait in review post it: a swiped-away note stays
    // away until then, and rows that counted at once ask for no review.
    await ReviewNotifier.sync(finance.pendingCount, allowPost: toReview > 0);
  }
  // Bills come due and imports push budgets over with the app shut: until
  // v1.39.1 these alerts waited for the next open. Each monitor remembers
  // what it sent, so opening the app later never repeats one. The app's
  // own engine passes [checkAlerts] false and runs its own monitors.
  if (checkAlerts && finance.loadWarnings.isEmpty) {
    await runAlertChecks(finance, settings, notifications: notifications);
  }
  return (imported: imported, ok: ok);
}

/// Budget, unusual spending and payment-due checks, for an engine with no
/// Home screen to run them. One failing never stops the others.
/// [notifications] is the tests' stand-in for the plugin.
Future<void> runAlertChecks(
  FinanceProvider finance,
  SettingsProvider settings, {
  NotificationService? notifications,
}) async {
  final checks = <(String, Future<void> Function())>[
    (
      'Budget',
      () =>
          BudgetMonitor(notifications: notifications).check(finance, settings),
    ),
    (
      'Unusual spending',
      () => UnusualSpendMonitor(
        notifications: notifications,
      ).check(finance, settings),
    ),
    (
      'Upcoming',
      () => UpcomingMonitor(
        notifications: notifications,
      ).check(finance, settings),
    ),
  ];
  for (final (name, run) in checks) {
    try {
      await run();
    } catch (e) {
      debugPrint('Background $name check failed: $e');
    }
  }
}

/// What one background import did.
typedef BackgroundImportResult = ({int imported, bool ok});

/// Keeps the "transactions to review" notification in step with the queue:
/// shown above [kReviewNotifyThreshold] when [allowPost], cleared at or
/// below it. The app passes allowPost false, so reviewing rows clears it
/// (or updates the count on one this isolate showed) but opening the app
/// never posts it.
abstract final class ReviewNotifier {
  /// What this isolate last told the plugin; null until the first call.
  static bool? _shown;
  static int? _shownCount;

  static Future<void> sync(int pending, {required bool allowPost}) async {
    try {
      if (pending > kReviewNotifyThreshold) {
        if (!allowPost && _shown != true) return;
        if (pending == _shownCount && _shown == true) return;
        await NotificationService.instance.showReview(pending);
        _shown = true;
        _shownCount = pending;
      } else if (_shown != false) {
        await NotificationService.instance.cancelReview();
        _shown = false;
      }
    } catch (e) {
      debugPrint('Review notification failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _shown = null;
    _shownCount = null;
  }
}
