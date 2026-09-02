import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper over flutter_local_notifications for app-generated alerts
/// (currently budget thresholds). Android-focused: on other platforms the
/// methods are safe no-ops.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

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
  Future<bool> get areEnabled async {
    if (!_supported) return false;
    // Everything below talks to the plugin. Under widget tests the platform
    // interface is never registered and throws a LateInitializationError
    // (an Error, so plain `on Exception` would miss it) — treat any failure
    // as "notifications unavailable" rather than crashing the caller.
    try {
      return await _areEnabled();
    } catch (e) {
      debugPrint('Notification availability check failed: $e');
      return false;
    }
  }

  Future<bool> _areEnabled() async {
    await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final appEnabled = await android?.areNotificationsEnabled() ?? false;
      if (!appEnabled) return false;
      final channels = await android?.getNotificationChannels();
      final channel = channels?.where((c) => c.id == _channelId).firstOrNull;
      return channel == null || channel.importance != Importance.none;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final options = await ios?.checkPermissions();
    return options?.isEnabled ?? false;
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
