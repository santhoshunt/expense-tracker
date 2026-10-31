import 'package:shared_preferences/shared_preferences.dart';

import '../models/subscription_cycle.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'launch_actions.dart';
import 'notification_ids.dart';
import 'notification_service.dart';
import 'subscriptions.dart';

/// Fires the subscription price-rise alert: one notification for each raised
/// payment that [cachedSubscriptions] flags with a priceRise, the same rule
/// as the Up mark on Subscriptions. A tap opens Cockpit, Budgets and bills,
/// Subscriptions ([kSubscriptionsPayload]).
///
/// Same contract as UnusualSpendMonitor: it runs while the app is open and
/// after background imports, and de-dupes through prefs markers
/// `price_rise_fired_<hit key>_<yyyy-MM-dd>`, keyed on the raised payment's
/// date, so each rise fires once.
class PriceRiseMonitor {
  final NotificationService notifications;

  bool _busy = false;
  bool _rerunRequested = false;
  bool _sweptOldMarkers = false;

  PriceRiseMonitor({NotificationService? notifications})
    : notifications = notifications ?? NotificationService.instance;

  static const markerPrefix = 'price_rise_fired_';

  /// A raised payment older than this never alerts, so the first run does
  /// not post notes for renewals from months ago.
  static const freshDays = 31;

  /// Must stay above freshDays, or a swept marker's rise would fire again.
  static const markerKeepDays = 40;

  static String _ymd(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

  static String firedKey(String hitKey, DateTime paid) =>
      '$markerPrefix${hitKey}_${_ymd(paid)}';

  Future<void> check(FinanceProvider finance, SettingsProvider settings) async {
    if (_busy) {
      _rerunRequested = true;
      return;
    }
    if (!settings.priceRiseAlerts) return;
    _busy = true;
    try {
      // No clock seam: cachedSubscriptions reads this same clock.
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final prefs = await SharedPreferences.getInstance();

      if (!_sweptOldMarkers) {
        _sweptOldMarkers = true;
        for (final k in prefs.getKeys().toList()) {
          if (!k.startsWith(markerPrefix)) continue;
          final paid = DateTime.tryParse(k.substring(k.lastIndexOf('_') + 1));
          if (paid == null) continue;
          if (today.difference(paid).inDays > markerKeepDays) {
            await prefs.remove(k);
          }
        }
      }

      final summary = cachedSubscriptions(finance, settings.hiddenUpcoming);
      for (final item in summary.active) {
        if (item.priceRise == null) continue;
        final paid = item.hit.history.last.date;
        final paidDay = DateTime(paid.year, paid.month, paid.day);
        if (today.difference(paidDay).inDays > freshDays) continue;
        final key = firedKey(item.hit.key, paidDay);
        if (prefs.getBool(key) ?? false) continue;
        // No permission: a show() is silently dropped. Bail WITHOUT the
        // marker, so the alert still fires once it is granted.
        if (!await notifications.areEnabled) return;
        final text = priceRiseAlertText(item);
        await notifications.show(
          id: NotificationIds.priceRise(item.hit.key),
          title: text.title,
          body: text.body,
          payload: kSubscriptionsPayload,
        );
        await prefs.setBool(key, true);
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

/// The note for [item]'s rise: the new price in the title, the old price
/// and the extra cost a month and a year in the body. The "when" follows
/// the plan's cycle, so a yearly renewal reads "last year".
({String title, String body}) priceRiseAlertText(SubscriptionItem item) {
  final rise = item.priceRise?.amount ?? 0;
  final latest = item.hit.history.last.amount;
  final previous = latest - rise;
  final cycle = item.hit.cycle ?? SubscriptionCycle.monthly;
  final perYear = cycle.yearlyCost(rise);
  final when = switch (cycle) {
    SubscriptionCycle.monthly => 'last month',
    SubscriptionCycle.quarterly => 'last quarter',
    SubscriptionCycle.halfYearly => 'six months ago',
    SubscriptionCycle.yearly => 'last year',
  };
  return (
    title: '${item.hit.label} now costs ${fmtMoneyTidy(latest)}',
    body:
        'Was ${fmtMoneyTidy(previous)} $when. That is '
        '${fmtMoneyWhole(perYear / 12)} more a month, '
        '${fmtMoneyWhole(perYear)} more a year.',
  );
}
