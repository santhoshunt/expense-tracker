import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'notification_service.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';

/// Fires "card bill due" and "recurring payment expected" notifications.
///
/// Same contract as BudgetMonitor: there is no background service — this
/// runs while the app is open (launch, resume, data changes) and de-dupes
/// per billing cycle via prefs markers, so each item notifies at most once
/// per due date's month:
///   `card_due_fired_<accountId>_<yyyy-MM>`
///   `recurring_due_fired_<hit key>_<yyyy-MM>`
class UpcomingMonitor {
  /// Card bills notify when due within this many days.
  static const cardWindowDays = 3;

  /// Recurring payments notify when expected within this many days (overdue
  /// ones — negative day counts — are included until the detector drops
  /// them).
  static const recurringWindowDays = 2;

  /// Manual reminders notify when due within this many days (overdue ones
  /// included until marked paid or past the grace window).
  static const reminderWindowDays = 2;

  final NotificationService notifications;
  bool _busy = false;
  bool _rerunRequested = false;
  bool _sweptOldMarkers = false;

  UpcomingMonitor({NotificationService? notifications})
    : notifications = notifications ?? NotificationService.instance;

  static String _ym(DateTime d) => monthKey(d);

  static String cardDueKey(String accountId, DateTime due) =>
      'card_due_fired_${accountId}_${_ym(due)}';

  static String recurringDueKey(String hitKey, DateTime due) =>
      'recurring_due_fired_${hitKey}_${_ym(due)}';

  /// Marking a reminder paid moves its due date to a new month, hence a new
  /// key — no marker clearing needed.
  static String reminderDueKey(String reminderId, DateTime due) =>
      'reminder_due_fired_${reminderId}_${_ym(due)}';

  static String _inDays(int days) => days == 0
      ? 'today'
      : days == 1
      ? 'tomorrow'
      : 'in $days days';

  Future<void> check(FinanceProvider finance, SettingsProvider settings) async {
    if (_busy) {
      _rerunRequested = true;
      return;
    }
    if (!settings.upcomingReminders) return;
    _busy = true;
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final prefs = await SharedPreferences.getInstance();

      if (!_sweptOldMarkers) {
        _sweptOldMarkers = true;
        // Markers are keyed by the DUE month, which can be next month for a
        // bill notified late in this one — sweep only strictly-past months
        // ('yyyy-MM' compares correctly as a string).
        final ym = _ym(now);
        for (final k in prefs.getKeys().toList()) {
          final isOurs =
              k.startsWith('card_due_fired_') ||
              k.startsWith('recurring_due_fired_') ||
              k.startsWith('reminder_due_fired_');
          if (!isOurs) continue;
          final suffix = k.substring(k.lastIndexOf('_') + 1);
          if (suffix.compareTo(ym) < 0) await prefs.remove(k);
        }
      }

      // Each entry: dedup key, notification id, title, body.
      final checks = <({String key, int id, String title, String body})>[];

      for (final a in finance.openAccounts) {
        if (!a.isCard || a.dueDay == null) continue;
        final out = finance.accountOutstanding(a);
        if (out == null || out <= 0) continue;
        final due = nextMonthlyOccurrence(a.dueDay!, now);
        final days = due.difference(today).inDays;
        if (days > cardWindowDays) continue;
        checks.add((
          key: cardDueKey(a.id, due),
          // Masked hash, same scheme as BudgetMonitor's custom-budget ids;
          // the 94xxx range is distinct from budget alerts (90xxx/92xxx).
          id: 94000 + ((a.id.hashCode & 0x7fffffff) % 1000),
          title: '${a.name} bill due ${_inDays(days)}',
          body: '${fmtMoney(out)} due on ${fmtDate(due)}',
        ));
      }

      final hits = detectRecurring(
        finance.transactions,
        now: now,
        alias: finance.merchantAlias,
      );
      for (final h in hits) {
        if (settings.hiddenUpcoming.contains(h.key)) continue;
        final days = h.daysUntil(now);
        if (days > recurringWindowDays) continue;
        checks.add((
          key: recurringDueKey(h.key, h.nextDue),
          id: 95000 + ((h.key.hashCode & 0x7fffffff) % 1000),
          title: 'Upcoming payment: ${h.label}',
          body: days < 0
              ? '~${fmtMoney(h.expectedAmount)} was expected on '
                    '${fmtDate(h.nextDue)}'
              : '~${fmtMoney(h.expectedAmount)} expected ${_inDays(days)} '
                    '(${fmtDate(h.nextDue)})',
        ));
      }

      for (final r in finance.reminders) {
        final due = reminderNextDue(r, now);
        final days = reminderDaysUntil(r, now);
        if (days > reminderWindowDays) continue;
        final amount = r.expectedAmount;
        final when = days < 0
            ? 'was due on ${fmtDate(due)}'
            : 'due ${_inDays(days)} (${fmtDate(due)})';
        checks.add((
          key: reminderDueKey(r.id, due),
          id: 96000 + ((r.id.hashCode & 0x7fffffff) % 1000),
          title: 'Reminder: ${r.name}',
          body: amount == null ? when : '${fmtMoney(amount)} $when',
        ));
      }

      for (final c in checks) {
        if (prefs.getBool(c.key) ?? false) continue;
        // No permission → a show() is silently dropped. Bail WITHOUT
        // recording the marker so the reminder still fires once granted.
        if (!await notifications.areEnabled) return;
        await notifications.show(id: c.id, title: c.title, body: c.body);
        await prefs.setBool(c.key, true);
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
