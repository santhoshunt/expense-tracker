import 'package:shared_preferences/shared_preferences.dart';

import '../models/spend_budget.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/format.dart';
import 'budget.dart';
import 'launch_actions.dart';
import 'notification_ids.dart';
import 'notification_service.dart';

/// One budget the monitor evaluates: spend, cap, dedup key, notification
/// id, an optional budget name for the alert text, and the card a tap opens.
typedef _BudgetCheck = ({
  double spent,
  double cap,
  String key,
  int id,
  String? name,
  String payload,
});

/// Evaluates the monthly spending cap AND every custom spend budget after
/// transactions change, firing a notification when a new threshold is
/// crossed.
///
/// De-duped per calendar month via `budget_alert_fired_…` markers (one for
/// the cap, one per custom budget), so each level (80 / 90 / over) alerts at
/// most once a month per budget. There is no background service — this runs
/// while the app is open, after imports and manual edits — see the note in
/// Settings.
class BudgetMonitor {
  final NotificationService notifications;
  bool _busy = false;

  /// One-shot per session: stale `budget_alert_fired_*` markers from past
  /// months otherwise accumulate in prefs forever (only clearAll swept them).
  bool _sweptOldMarkers = false;

  /// A check that arrived while one was in flight. Dropping it lost real
  /// alerts: during an import burst the *last* notification carries the final
  /// total and is the most likely to land mid-await, so the threshold would
  /// then wait for some unrelated later change.
  bool _rerunRequested = false;

  /// Test seam, as UnusualSpendMonitor has: a fixed date keeps a test from
  /// straddling a month end between its own clock read and this one.
  final DateTime Function() clock;

  BudgetMonitor({NotificationService? notifications, DateTime Function()? clock})
    : notifications = notifications ?? NotificationService.instance,
      clock = clock ?? DateTime.now;

  /// The alerts posted and not withdrawn, one "id|level|marker key" entry
  /// per notification id. The markers cannot say this: the provider removes
  /// a budget's marker when the budget is edited or deleted, and the cap's
  /// when the cap changes, which are the moments an alert may stop applying.
  /// Not under `budget_alert_fired_`, so the monthly sweep keeps it.
  static const showingKey = 'budget_alerts_showing';

  /// False once a run found nothing in [showingKey], so a user with no
  /// budget left skips the prefs read on every change, as before. True on a
  /// fresh monitor, which has not looked yet.
  bool _mayBeShowing = true;

  static ({int id, int level, String key}) _parseShowing(String entry) {
    final parts = entry.split('|');
    return (
      id: int.tryParse(parts[0]) ?? -1,
      level: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
      key: parts.length > 2 ? parts.sublist(2).join('|') : '',
    );
  }

  /// Withdraws each alert in [showing] whose reason went in the period it
  /// spoke of: its budget deleted or its limit cleared, the cap cleared, or
  /// the spend now under the level it announced (a row deleted, refunded,
  /// moved or now guessed, or the limit raised). The marker keeps the level,
  /// so the same level is not announced again this period: the alert says a
  /// line was crossed, which the user heard about this month, and a dip and
  /// return (an Undo, a row moved back) would otherwise sound twice for one
  /// crossing. A higher level still alerts. A withdrawn entry leaves
  /// [showing], and only a post adds one back, so no run can post and
  /// withdraw the same alert in turn without the spend moving. An alert about a
  /// month that has ended, or a dated budget whose dates are over, was true
  /// of that period and stays; only its entry goes. Rewrites [showing] in
  /// place and in prefs when it changed.
  Future<void> _withdrawStale(
    SharedPreferences prefs,
    FinanceProvider finance,
    List<String> showing,
    List<_BudgetCheck> checks,
    DateTime now,
  ) async {
    final ym = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    var changed = false;
    for (final entry in [...showing]) {
      final (:id, :level, :key) = _parseShowing(entry);
      final c = checks.where((c) => c.key == key).firstOrNull;
      if (c != null && c.cap > 0 && c.spent / c.cap * 100 >= level) continue;
      final ended = key.startsWith(kRangeBudgetAlertPrefix)
          ? finance.budgets.any(
              (b) =>
                  b.range != null &&
                  rangeBudgetAlertKey(b.id) == key &&
                  b.stageOn(now) != TripStage.running,
            )
          : !key.endsWith(ym);
      if (!ended) await notifications.cancelId(id);
      showing.remove(entry);
      changed = true;
    }
    if (changed) await prefs.setStringList(showingKey, showing);
    _mayBeShowing = showing.isNotEmpty;
  }

  Future<void> check(FinanceProvider finance, SettingsProvider settings) async {
    if (_busy) {
      _rerunRequested = true;
      return;
    }
    final now = clock();
    final hasCap = settings.monthlyBudget > 0;
    // A dated budget alerts only while its dates run.
    final customBudgets = finance.budgets
        .where(
          (b) =>
              b.limit > 0 &&
              (b.range == null || b.stageOn(now) == TripStage.running),
        )
        .toList();
    if (!settings.budgetAlerts) return;
    // With every threshold switched off no check can fire — skip the spend
    // computation entirely (this runs on every provider notification).
    if (!settings.alert80 && !settings.alert90 && !settings.alertOver) return;
    // No budget left to alert on: only an alert still up for one that went
    // (the cap cleared, the last budget deleted) needs this run.
    if (!hasCap && customBudgets.isEmpty && !_mayBeShowing) return;
    _busy = true;
    try {
      final month = DateTime(now.year, now.month);
      final prefs = await SharedPreferences.getInstance();

      if (!_sweptOldMarkers) {
        _sweptOldMarkers = true;
        // Both marker formats end in "yyyy-MM"; anything not from the
        // current month is dead weight.
        final ym = '${now.year}-${now.month.toString().padLeft(2, '0')}';
        for (final k in prefs.getKeys().toList()) {
          if (k.startsWith('budget_alert_fired_') && !k.endsWith(ym)) {
            await prefs.remove(k);
          }
        }
      }

      // Each entry: spend, cap, dedup key, notification id, an optional
      // budget name for the alert text, and the card a tap opens. Spend on
      // a guessed category ([Tx.categoryGuessed]) waits until the user
      // confirms it: a wrong guess must not fire an alert.
      final checks = <_BudgetCheck>[
            if (hasCap)
              (
                spent:
                    finance.budgetSpentInMonth(month) -
                    finance.guessedSpendInMonth(month),
                cap: settings.monthlyBudget,
                key: budgetAlertMonthKey(now),
                id: NotificationIds.cap(now.month), // stable per month
                name: null,
                payload: kBudgetPayload,
              ),
            for (final b in customBudgets)
              (
                spent:
                    finance.budgetSpentFor(b, month) -
                    finance.guessedSpendFor(b, month),
                cap: b.limit,
                key: budgetAlertKeyFor(b, now),
                // Stable per budget, in its own 300000 range: the old
                // 92000-based range ran over every fixed id from 93000 up.
                id: NotificationIds.customBudget(b.id),
                name: b.name,
                payload: kBudgetsPayload,
              ),
          ];

      final showing = [...?prefs.getStringList(showingKey)];
      _mayBeShowing = showing.isNotEmpty;
      // A ledger that failed to load cannot show a budget is back under.
      if (showing.isNotEmpty && finance.loadWarnings.isEmpty) {
        await _withdrawStale(prefs, finance, showing, checks, now);
      }
      if (!hasCap && customBudgets.isEmpty) return;

      for (final c in checks) {
        final lastNotified = prefs.getInt(c.key) ?? 0;
        final level = budgetLevelToNotify(
          spent: c.spent,
          cap: c.cap,
          lastNotified: lastNotified,
          en80: settings.alert80,
          en90: settings.alert90,
          enOver: settings.alertOver,
        );
        if (level == null) continue;

        // Without notification permission a show() is silently dropped —
        // bail WITHOUT recording the level, so the alert still fires once
        // the user grants permission.
        if (!await notifications.areEnabled) return;

        final text = budgetAlertText(
          level: level,
          spent: c.spent,
          cap: c.cap,
          money: fmtMoney,
          name: c.name,
        );
        await notifications.show(
          id: c.id,
          title: text.title,
          body: text.body,
          payload: c.payload,
        );
        await prefs.setInt(c.key, level);
        // The new alert replaced any other under its id in the shade.
        showing
          ..removeWhere((e) => _parseShowing(e).id == c.id)
          ..add('${c.id}|$level|${c.key}');
        await prefs.setStringList(showingKey, showing);
        _mayBeShowing = true;
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
