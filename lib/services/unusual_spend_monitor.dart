import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/dates.dart';
import 'launch_actions.dart';
import 'notification_ids.dart';
import 'notification_service.dart';
import 'unusual_spend.dart';

/// Fires the unusual spending alert: one notification per category per
/// month once [unusualCategories] lists it. A tap opens that category's
/// history sheet on that month ([unusualPayload]).
///
/// Same contract as BudgetMonitor and UpcomingMonitor: there is no
/// background service, so this runs while the app is open (launch, imports,
/// edits), and de-dupes through prefs markers
/// `unusual_alert_fired_<categoryId>_<yyyy-MM>`.
class UnusualSpendMonitor {
  final NotificationService notifications;

  /// Test seam, so fixtures can sit in fixed past months.
  final DateTime Function() clock;

  bool _busy = false;
  bool _rerunRequested = false;
  bool _sweptOldMarkers = false;

  UnusualSpendMonitor({
    NotificationService? notifications,
    DateTime Function()? clock,
  }) : notifications = notifications ?? NotificationService.instance,
       clock = clock ?? DateTime.now;

  static const markerPrefix = 'unusual_alert_fired_';

  static String firedKey(String categoryId, DateTime month) =>
      '$markerPrefix${categoryId}_${monthKey(month)}';

  /// Stable per category, 200000 to 299999 (see NotificationIds). A wide
  /// range, so two categories alerting in one month rarely share an id (a
  /// shared id replaces the earlier note in the shade).
  static int notificationId(String categoryId) =>
      NotificationIds.unusual(categoryId);

  Future<void> check(FinanceProvider finance, SettingsProvider settings) async {
    if (_busy) {
      _rerunRequested = true;
      return;
    }
    if (!settings.unusualAlerts) return;
    _busy = true;
    try {
      final now = clock();
      final month = DateTime(now.year, now.month);
      final prefs = await SharedPreferences.getInstance();

      if (!_sweptOldMarkers) {
        _sweptOldMarkers = true;
        // 'yyyy-MM' compares correctly as a string.
        final ym = monthKey(month);
        for (final k in prefs.getKeys().toList()) {
          if (!k.startsWith(markerPrefix)) continue;
          final suffix = k.substring(k.lastIndexOf('_') + 1);
          if (suffix.compareTo(ym) < 0) await prefs.remove(k);
        }
      }

      // Already alerted this month: skipped before any history is built.
      final found = unusualCategories(
        finance,
        now: now,
        skip: {
          for (final e in finance.expenseByCategory(month))
            if (prefs.getBool(firedKey(e.key.id, month)) ?? false) e.key.id,
        },
      );
      for (final c in found) {
        // No permission: a show() is silently dropped. Bail WITHOUT the
        // marker, so the alert still fires once it is granted.
        if (!await notifications.areEnabled) return;
        final text = unusualAlertText(c, month);
        await notifications.show(
          id: notificationId(c.id),
          title: text.title,
          body: text.body,
          payload: unusualPayload(c.id, month),
        );
        await prefs.setBool(firedKey(c.id, month), true);
      }
    } finally {
      _busy = false;
      if (_rerunRequested) {
        _rerunRequested = false;
        await check(finance, settings);
      }
    }
  }
}
