import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'card_bill.dart';
import 'launch_actions.dart';
import 'notification_ids.dart';
import 'notification_service.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';
import 'upcoming_items.dart';

/// Fires "card bill due" and "recurring payment expected" notifications.
///
/// Same contract as BudgetMonitor: this runs while the app is open (launch,
/// resume, data changes) and from the background import, and de-dupes via
/// prefs markers, so each item notifies at most once per due date:
///   `card_due_fired_<accountId>_<yyyy-MM-dd>`
///   `recurring_due_fired_<hit key>_<yyyy-MM-dd>`
///   `reminder_due_fired_<reminderId>_<yyyy-MM-dd>`
/// A marker ending in a bare `yyyy-MM` (the older form) covers every due
/// date in that month until the sweep drops it.
class UpcomingMonitor {
  /// Card bills notify when due within this many days — the same window
  /// that turns the dashboard row red.
  static const cardWindowDays = kCardUrgentWindowDays;

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

  /// A marker is swept once its due date is this many days old: well past
  /// the longest overdue window (7 days for reminders, repeats and card
  /// bills), so an item still overdue never loses its marker.
  static const markerKeepDays = 40;

  static String _ymd(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

  static String cardDueKey(String accountId, DateTime due) =>
      'card_due_fired_${accountId}_${_ymd(due)}';

  static String recurringDueKey(String hitKey, DateTime due) =>
      'recurring_due_fired_${hitKey}_${_ymd(due)}';

  /// Marking a reminder paid moves its due date on, hence a new key: no
  /// marker clearing needed.
  static String reminderDueKey(String reminderId, DateTime due) =>
      'reminder_due_fired_${reminderId}_${_ymd(due)}';

  /// The older month-keyed form of [key] ("..._2026-10" for
  /// "..._2026-10-30"), which still counts as fired for its whole month.
  static String _monthFormOf(String key) => key.substring(0, key.length - 3);

  /// The due date a marker's suffix names: the day itself, or the last day
  /// of the month for the older month-keyed form. Null when unreadable.
  static DateTime? _markerDue(String suffix) {
    if (suffix.length == 10) return DateTime.tryParse(suffix);
    if (suffix.length == 7) {
      final first = DateTime.tryParse('$suffix-01');
      return first == null ? null : DateTime(first.year, first.month + 1, 0);
    }
    return null;
  }

  /// [now] defaults to the clock; tests pass a fixed date.
  Future<void> check(
    FinanceProvider finance,
    SettingsProvider settings, {
    DateTime? now,
  }) async {
    if (_busy) {
      _rerunRequested = true;
      return;
    }
    if (!settings.upcomingReminders) return;
    _busy = true;
    try {
      final clock = now ?? DateTime.now();
      final today = DateTime(clock.year, clock.month, clock.day);
      final prefs = await SharedPreferences.getInstance();

      if (!_sweptOldMarkers) {
        _sweptOldMarkers = true;
        // Only markers whose due date is long gone: one still inside an
        // overdue window keeps that item from notifying again.
        for (final k in prefs.getKeys().toList()) {
          final isOurs =
              k.startsWith('card_due_fired_') ||
              k.startsWith('recurring_due_fired_') ||
              k.startsWith('reminder_due_fired_');
          if (!isOurs) continue;
          final due = _markerDue(k.substring(k.lastIndexOf('_') + 1));
          if (due != null && today.difference(due).inDays > markerKeepDays) {
            await prefs.remove(k);
          }
        }
      }

      // Each entry: dedup key, notification id, title, body.
      final checks = <({String key, int id, String title, String body})>[];

      for (final a in finance.openAccounts) {
        // Only a billed, unpaid cycle notifies. Paid: due moves to next
        // month (beyond the window) and next cycle's key is new. Not yet
        // billed: nothing is owed until the statement generates, however
        // close the due date sits.
        final s = cardBillStatus(a, clock);
        if (s == null || s.phase != CardBillPhase.billed) continue;
        final out = finance.accountOutstanding(a);
        if (out == null || out <= 0) continue;
        if (s.daysUntil > cardWindowDays) continue;
        checks.add((
          key: cardDueKey(a.id, s.due),
          // 94000 to 94999; every range is listed in NotificationIds.
          id: NotificationIds.cardBill(a.id),
          title: s.daysUntil < 0
              ? '${a.name} bill overdue'
              : '${a.name} bill due ${fmtInDays(s.daysUntil)}',
          body: s.daysUntil < 0
              ? '${fmtMoney(out)} was due on ${fmtDate(s.due)}'
              : '${fmtMoney(out)} due on ${fmtDate(s.due)}',
        ));
      }

      final hits = detectRecurring(
        finance.countedTransactions,
        now: clock,
        alias: finance.merchantAlias,
        pinned: finance.subscriptionPins,
      );
      for (final h in hits) {
        if (settings.hiddenUpcoming.contains(h.key)) continue;
        // Marked paid by hand: its alert never came, so nothing to remind.
        if (hitMarkedPaid(finance, h)) continue;
        // Its reminder notifies (or, adding itself, needs no reminding).
        if (finance.reminders.any((r) => reminderCoversHit(r, h, clock))) {
          continue;
        }
        final days = h.daysUntil(clock);
        if (days > recurringWindowDays) continue;
        checks.add((
          key: recurringDueKey(h.key, h.nextDue),
          id: NotificationIds.recurring(h.key),
          title: 'Upcoming payment: ${h.label}',
          body: days < 0
              ? '~${fmtMoney(h.expectedAmount)} was expected on '
                    '${fmtDate(h.nextDue)}'
              : '~${fmtMoney(h.expectedAmount)} expected ${fmtInDays(days)} '
                    '(${fmtDate(h.nextDue)})',
        ));
      }

      for (final r in finance.reminders) {
        // Add it for me records the expense itself: nothing to remind.
        if (r.autoAdd || reminderFinished(r, clock)) continue;
        final due = reminderNextDue(r, clock);
        final days = reminderDaysUntil(r, clock);
        if (days > reminderWindowDays) continue;
        final amount = r.expectedAmount;
        final when = days < 0
            ? 'was due on ${fmtDate(due)}'
            : 'due ${fmtInDays(days)} (${fmtDate(due)})';
        checks.add((
          key: reminderDueKey(r.id, due),
          id: NotificationIds.reminder(r.id),
          title: 'Reminder: ${r.name}',
          body: amount == null ? when : '${fmtMoney(amount)} $when',
        ));
      }

      for (final c in checks) {
        if ((prefs.getBool(c.key) ?? false) ||
            (prefs.getBool(_monthFormOf(c.key)) ?? false)) {
          continue;
        }
        // No permission → a show() is silently dropped. Bail WITHOUT
        // recording the marker so the reminder still fires once granted.
        if (!await notifications.areEnabled) return;
        await notifications.show(
          id: c.id,
          title: c.title,
          body: c.body,
          payload: kUpcomingPayload,
        );
        await prefs.setBool(c.key, true);
      }
    } finally {
      _busy = false;
      if (_rerunRequested) {
        _rerunRequested = false;
        await check(finance, settings, now: now);
      }
    }
  }
}
