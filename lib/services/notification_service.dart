import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// Only tz.UTC is used (see scheduleRecap), which needs no zone database.
// Since timezone 0.11.1 its name is "Etc/UTC", which the plugin hands to
// Android's ZoneId as it did "UTC"; both are valid there.
import 'package:timezone/timezone.dart' as tz;

import 'import_checks.dart';
import 'launch_actions.dart';
import 'notification_ids.dart';

/// Why a notification would or would not reach the user right now.
///
/// Kept distinct because each needs a different remedy: [appBlocked] is the
/// system-level switch (only Android Settings can flip it), [channelBlocked]
/// is the app's own "Budget alerts" channel muted there, and [unavailable]
/// means the plugin itself failed (a build or device problem, not the user).
/// Collapsing all three to "blocked" sent people to a permission dialog that
/// could not help them.
enum NotificationStatus { enabled, appBlocked, channelBlocked, unavailable }

/// Pure mapping behind [NotificationService.status], separated so the
/// decision table is unit-testable without a platform.
NotificationStatus notificationStatusFrom({
  required bool initFailed,
  required bool? appEnabled,
  required Importance? channelImportance,
}) {
  if (initFailed || appEnabled == null) return NotificationStatus.unavailable;
  if (!appEnabled) return NotificationStatus.appBlocked;
  // No channel yet (API < 26, or never created) is fine; only an explicit
  // "none" importance means the user muted it.
  if (channelImportance == Importance.none) {
    return NotificationStatus.channelBlocked;
  }
  return NotificationStatus.enabled;
}

/// Thin wrapper over flutter_local_notifications for app-generated alerts
/// (currently budget thresholds). Android-focused: on other platforms the
/// methods are safe no-ops.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// Test seam: widget tests have no platform plugin, so they inject the
  /// status the UI should render.
  @visibleForTesting
  static Future<NotificationStatus> Function()? statusOverride;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialised = false;

  static const _channelId = 'budget_alerts';
  static const _channelName = 'Budget alerts';

  /// Every alert on this channel, as Android Settings lists it: payment
  /// reminders and unusual spending post here too. Android updates the
  /// description of an existing channel when it is created again.
  static const _channelDescription =
      'Budget thresholds, unusual spending and payments coming due';

  static const _recapChannelId = 'monthly_recap';
  static const _recapChannelName = 'Monthly recap';
  static const _recapChannelDescription =
      "A note on the 1st that last month's recap is ready";

  /// Fixed, so every reschedule replaces the one pending recap.
  static const recapNotificationId = 97000;

  /// Its own channel, not the recap's: Android mutes channels one at a
  /// time, and a shared one would tie the two notes together.
  static const _weeklyChannelId = 'weekly_digest';
  static const _weeklyChannelName = 'Weekly digest';
  static const _weeklyChannelDescription =
      "A note on Monday that last week's digest is ready";

  /// Fixed, so every reschedule replaces the one pending digest note.
  static const weeklyDigestNotificationId = 98000;

  static const _reviewChannelId = 'import_review';
  static const _reviewChannelName = 'Transactions to review';
  static const _reviewChannelDescription =
      'How many imported transactions are waiting, when more than 5 are';

  /// Fixed, so a later import updates the one note instead of adding more.
  static const reviewNotificationId = 93000;

  /// One note per guessed or To sort import, bundled under a summary.
  static const _importCheckChannelId = 'import_checks';
  static const _importCheckChannelName = 'Payments to check';
  static const _importCheckChannelDescription =
      'New payments counted with a guessed category or as To sort';
  static const _importCheckGroup = 'import_checks';

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (_initialised || !_supported) return;
    // Monochrome vector, not the launcher icon: Android flattens the
    // status-bar small icon to one colour, so the full-colour launcher
    // rendered as a shapeless white blob.
    const android = AndroidInitializationSettings('@drawable/ic_stat_notify');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
      // Taps while the app is running; a tap that starts the app is read
      // from launchPayload() instead. The plugin sends Keep to the
      // background handler below even then; should a later version send it
      // here, it must still not open the row.
      onDidReceiveNotificationResponse: (r) {
        if (r.actionId == kImportCheckKeepAction) {
          ImportChecks.keep(r.payload);
          return;
        }
        LaunchActions.instance.onNotificationPayload(r.payload);
      },
      // Keep on a payment-to-check note, in the plugin's own engine.
      onDidReceiveBackgroundNotificationResponse: importCheckAction,
    );
    // Create the channel up front. Lazily-created-on-first-show meant the
    // channel didn't exist in system settings until the first threshold ever
    // fired, so the user couldn't find or configure it beforehand.
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
            ),
          );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _recapChannelId,
              _recapChannelName,
              description: _recapChannelDescription,
            ),
          );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _weeklyChannelId,
              _weeklyChannelName,
              description: _weeklyChannelDescription,
            ),
          );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _reviewChannelId,
              _reviewChannelName,
              description: _reviewChannelDescription,
            ),
          );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _importCheckChannelId,
              _importCheckChannelName,
              description: _importCheckChannelDescription,
            ),
          );
    }
    _initialised = true;
  }

  /// Whether notifications can currently be shown (permission granted and
  /// not blocked in system settings).
  ///
  /// On Android this also checks the budget channel's importance: app-level
  /// enabled + channel blocked used to report true, so the monitor recorded
  /// the threshold as delivered while show() was a silent no-op — the alert
  /// was then suppressed for the rest of the month.
  Future<bool> get areEnabled async =>
      (await status) == NotificationStatus.enabled;

  /// Detailed availability, see [NotificationStatus]. Never throws.
  Future<NotificationStatus> get status async {
    final override = statusOverride;
    if (override != null) return override();
    if (!_supported) return NotificationStatus.unavailable;
    // Everything below talks to the plugin. Under widget tests the platform
    // interface is never registered and throws a LateInitializationError
    // (an Error, so plain `on Exception` would miss it); on a device the
    // plugin can fail to initialise (a missing small-icon resource shipped
    // exactly that way once). Neither is a permission problem, so they must
    // not read as "blocked".
    try {
      await init();
    } catch (e) {
      debugPrint('Notification init failed: $e');
      return NotificationStatus.unavailable;
    }
    try {
      return await _status();
    } catch (e) {
      debugPrint('Notification availability check failed: $e');
      return NotificationStatus.unavailable;
    }
  }

  Future<NotificationStatus> _status() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return NotificationStatus.unavailable;
      final appEnabled = await android.areNotificationsEnabled();
      Importance? channelImportance;
      if (appEnabled == true) {
        final channels = await android.getNotificationChannels();
        channelImportance = channels
            ?.where((c) => c.id == _channelId)
            .firstOrNull
            ?.importance;
      }
      return notificationStatusFrom(
        initFailed: false,
        appEnabled: appEnabled,
        channelImportance: channelImportance,
      );
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios == null) return NotificationStatus.unavailable;
    final options = await ios.checkPermissions();
    if (options == null) return NotificationStatus.unavailable;
    return options.isEnabled
        ? NotificationStatus.enabled
        : NotificationStatus.appBlocked;
  }

  /// Requests notification permission (Android 13+ / iOS). Safe to call more
  /// than once; returns true when notifications may be shown.
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    try {
      return await _requestPermission();
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
      return false;
    }
  }

  Future<bool> _requestPermission() async {
    await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
  }

  /// An alert on the budget channel. [payload] is what a tap hands to
  /// [LaunchActions], such as an unusual-spending alert's category.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_supported) return;
    await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  /// The payload of the notification whose tap started the app, or null.
  Future<String?> launchPayload() async {
    if (!_supported) return null;
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  /// Schedules the "recap is ready" note for [when], replacing any pending
  /// one (same id). [monthName] is the month the recap will cover. The text
  /// carries no figures: it shows on the lock screen, and Hide income exists.
  ///
  /// No cancel first: the plugin's cancel also removes a note already
  /// showing, and rebooking the same id replaces the alarm anyway.
  ///
  /// [when] is converted to UTC, keeping the same moment, so the device's
  /// zone never has to be looked up by name. Inexact: Android may deliver
  /// it a little late, and needs no exact-alarm permission for that.
  Future<void> scheduleRecap(DateTime when, String monthName) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    await _plugin.zonedSchedule(
      id: recapNotificationId,
      title: 'Your $monthName recap',
      body: 'See how $monthName went.',
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _recapChannelId,
          _recapChannelName,
          channelDescription: _recapChannelDescription,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: kRecapPayload,
    );
  }

  /// Schedules the Monday note that [week]'s digest is ready, replacing any
  /// pending one (same id). [weekLabel] names its dates ("12 to 18 Oct").
  /// No amounts, for the same reasons as [scheduleRecap], which this
  /// mirrors. The payload carries [week], so a late tap still opens it.
  Future<void> scheduleWeeklyDigest(
    DateTime when,
    DateTime week,
    String weekLabel,
  ) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    await _plugin.zonedSchedule(
      id: weeklyDigestNotificationId,
      title: 'Your week, $weekLabel',
      body: 'See how last week went.',
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _weeklyChannelId,
          _weeklyChannelName,
          channelDescription: _weeklyChannelDescription,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: weeklyPayload(week),
    );
  }

  /// "N imported transactions are waiting". A count only, no amounts or
  /// merchants: it can show on the lock screen. Re-posting the same id
  /// updates the text without sounding again.
  Future<void> showReview(int count) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    await _plugin.show(
      id: reviewNotificationId,
      title: 'Transactions to review',
      body: '$count imported transactions are waiting for you.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _reviewChannelId,
          _reviewChannelName,
          channelDescription: _reviewChannelDescription,
          onlyAlertOnce: true,
        ),
      ),
      payload: kReviewPayload,
    );
  }

  Future<void> cancelReview() async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    await _plugin.cancel(id: reviewNotificationId);
  }

  /// A payment-to-check note. With [keepLabel] (a guessed row) it carries
  /// Keep, which runs in the plugin's own engine without opening the app,
  /// and Change; without one (a To sort row) only Pick a category. Private
  /// visibility: the lock screen follows the phone's sensitive-content
  /// setting.
  Future<void> showImportCheck({
    required int id,
    required String title,
    required String body,
    required String payload,
    String? keepLabel,
  }) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _importCheckChannelId,
          _importCheckChannelName,
          channelDescription: _importCheckChannelDescription,
          groupKey: _importCheckGroup,
          visibility: NotificationVisibility.private,
          onlyAlertOnce: true,
          actions: [
            if (keepLabel != null)
              AndroidNotificationAction(kImportCheckKeepAction, keepLabel),
            AndroidNotificationAction(
              kImportCheckChangeAction,
              keepLabel != null ? 'Change' : 'Pick a category',
              showsUserInterface: true,
            ),
          ],
        ),
      ),
      payload: payload,
    );
  }

  /// The heading that bundles two or more payment-to-check notes.
  Future<void> showImportCheckSummary(int count) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    await _plugin.show(
      id: NotificationIds.importCheckSummary,
      title: 'Payments to check',
      body: '$count new payments need a look.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _importCheckChannelId,
          _importCheckChannelName,
          channelDescription: _importCheckChannelDescription,
          groupKey: _importCheckGroup,
          setAsGroupSummary: true,
          visibility: NotificationVisibility.private,
          onlyAlertOnce: true,
        ),
      ),
      payload: kImportChecksPayload,
    );
  }

  /// Ids of the payment-to-check notes in the shade now, summary left out.
  /// Swiped and cancelled notes are gone from it. Ids only: the plugin's
  /// Android side never returns a note's payload. Empty off Android or on a
  /// plugin failure.
  Future<List<int>> activeImportChecks() async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    try {
      await init();
      final active = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.getActiveNotifications();
      return [
        for (final n in active ?? const <ActiveNotification>[])
          if (n.channelId == _importCheckChannelId &&
              n.id != null &&
              n.id != NotificationIds.importCheckSummary)
            n.id!,
      ];
    } catch (e) {
      debugPrint('Active notifications failed: $e');
      return const [];
    }
  }

  /// Never throws: it runs on every ledger change, where a plugin failure
  /// must cost only the note.
  Future<void> cancelId(int id) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await init();
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('Notification cancel failed: $e');
    }
  }

  /// Whether the note with [id] is booked and not delivered yet. Static so
  /// the test stand-ins, which implement this class, need not provide it.
  static Future<bool> isBooked(int id) => instance._isBooked(id);

  Future<bool> _isBooked(int id) async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    await init();
    final pending = await _plugin.pendingNotificationRequests();
    return pending.any((r) => r.id == id);
  }

  /// Drops the booked recap note, if any. One already showing stays: the
  /// plugin's cancel removes both, so it runs only while still booked.
  Future<void> cancelRecap() async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    final pending = await _plugin.pendingNotificationRequests();
    if (pending.any((r) => r.id == recapNotificationId)) {
      await _plugin.cancel(id: recapNotificationId);
    }
  }

  /// Drops the booked digest note, if any; one already showing stays, as
  /// in [cancelRecap].
  Future<void> cancelWeeklyDigest() async {
    if (!_supported || defaultTargetPlatform != TargetPlatform.android) return;
    await init();
    final pending = await _plugin.pendingNotificationRequests();
    if (pending.any((r) => r.id == weeklyDigestNotificationId)) {
      await _plugin.cancel(id: weeklyDigestNotificationId);
    }
  }
}
