import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
      const InitializationSettings(android: android, iOS: ios),
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
              description: 'Alerts when you approach or exceed your budget',
              importance: Importance.high,
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

  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_supported) return;
    await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Alerts when you approach or exceed your budget',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(id, title, body, details);
  }
}
