import 'package:flutter/foundation.dart' show visibleForTesting;
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
///
/// A marker holds true while its alert may be in the shade, and false once
/// [check] withdrew it because the item was settled (paid, deleted, arrived,
/// moved out of the window). False means only "withdrawn, do not cancel
/// again": an occurrence back among the checks with a false marker (Paid
/// tapped by mistake and undone, the paying row deleted) is owed again, so
/// it is posted again and its marker returns to true.
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

  // Recurring detection scans a year of rows, and this runs on every data
  // change, so the last result is kept, as HomeWidgetsService keeps its
  // own. Detection reads the ledger, the merchant aliases and the marked
  // subscriptions, which change only with a notification (a new
  // [FinanceProvider.revision]), and the clock: its day, and within the
  // day only which rows are dated after it. Rows are newest first, so
  // those lead the list and are counted from the front.
  Object? _hitsRev;
  int? _hitsDay;
  int? _hitsAhead;
  List<RecurringHit> _hits = const [];

  /// How many times [check] has run recurring detection; for tests.
  @visibleForTesting
  int detections = 0;

  List<RecurringHit> _recurring(FinanceProvider finance, DateTime clock) {
    final rows = finance.countedTransactions;
    var ahead = 0;
    while (ahead < rows.length && rows[ahead].date.isAfter(clock)) {
      ahead++;
    }
    final day = clock.year * 10000 + clock.month * 100 + clock.day;
    if (!identical(_hitsRev, finance.revision) ||
        _hitsDay != day ||
        _hitsAhead != ahead) {
      detections++;
      _hits = detectRecurring(
        rows,
        now: clock,
        alias: finance.merchantAlias,
        pinned: finance.subscriptionPins,
      );
      _hitsRev = finance.revision;
      _hitsDay = day;
      _hitsAhead = ahead;
    }
    return _hits;
  }

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

  /// How long past its due date an unpaid item stays tracked, and so would
  /// still be posted: the card bill, reminder and repeat grace windows are
  /// all 7 days. Past it the monitor stops tracking the item whether paid
  /// or not, so an older marker says nothing about settlement and its
  /// alert is left alone.
  static const _trackedOverdueDays = kCardOverdueDays;

  /// Each marker kind and the notification id its item posts under.
  static const _markerKinds = <({String prefix, int Function(String) id})>[
    (prefix: 'card_due_fired_', id: NotificationIds.cardBill),
    (prefix: 'recurring_due_fired_', id: NotificationIds.recurring),
    (prefix: 'reminder_due_fired_', id: NotificationIds.reminder),
  ];

  /// Withdraws each alert still marked up (true) whose occurrence is no
  /// longer among [checks]: a card bill paid or cleared, a recurring
  /// payment that arrived or was marked paid, hidden or taken over by a
  /// reminder, a reminder marked paid, deleted, moved or set to add itself.
  /// Only occurrences inside the tracked window qualify, and the
  /// marker turns false, so the next run does not cancel it again. No
  /// platform call happens without such a marker.
  ///
  /// A run cannot both post and withdraw one occurrence: this looks only at
  /// keys outside [checks], and posting only at keys inside them, both from
  /// the one list built per run. Across runs it flips only when the ledger
  /// does.
  Future<void> _withdrawSettled(
    SharedPreferences prefs,
    List<({String key, int id, String title, String body})> checks,
    DateTime today,
  ) async {
    final current = {for (final c in checks) c.key};
    // An item's newer occurrence already posted under the same id replaced
    // the old alert in the shade: cancelling that id would remove a live one.
    final live = {
      for (final c in checks)
        if (prefs.getBool(c.key) ?? false) c.id,
    };
    for (final k in prefs.getKeys().toList()) {
      if (current.contains(k)) continue;
      final kind = _markerKinds.where((m) => k.startsWith(m.prefix));
      if (kind.isEmpty || prefs.getBool(k) != true) continue;
      final cut = k.lastIndexOf('_');
      final suffix = k.substring(cut + 1);
      // Only the day-keyed form names one occurrence; the older month form
      // cannot say which one it covered, so it is left to the sweep.
      if (suffix.length != 10) continue;
      final due = DateTime.tryParse(suffix);
      if (due == null ||
          calendarDaysBetween(due, today) > _trackedOverdueDays) {
        continue;
      }
      final id = kind.first.id(k.substring(kind.first.prefix.length, cut));
      if (!live.contains(id)) await notifications.cancelId(id);
      await prefs.setBool(k, false);
    }
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
          if (due != null && calendarDaysBetween(due, today) > markerKeepDays) {
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
          // NotificationIds.cardBillStart to cardBillEnd; every range is
          // listed in NotificationIds.
          id: NotificationIds.cardBill(a.id),
          title: s.daysUntil < 0
              ? '${a.name} bill overdue'
              : '${a.name} bill due ${fmtInDays(s.daysUntil)}',
          body: s.daysUntil < 0
              ? '${fmtMoney(out)} was due on ${fmtDate(s.due)}'
              : '${fmtMoney(out)} due on ${fmtDate(s.due)}',
        ));
      }

      for (final h in _recurring(finance, clock)) {
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

      // A ledger that failed to load cannot show that a bill was settled.
      if (finance.loadWarnings.isEmpty) {
        await _withdrawSettled(prefs, checks, today);
      }

      for (final c in checks) {
        // True: announced and still up. False: withdrawn, and now owed
        // again, so it posts again.
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
