import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/format.dart';
import 'budget.dart';
import 'notification_service.dart';

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

  BudgetMonitor({NotificationService? notifications})
    : notifications = notifications ?? NotificationService.instance;

  Future<void> check(FinanceProvider finance, SettingsProvider settings) async {
    if (_busy) {
      _rerunRequested = true;
      return;
    }
    final hasCap = settings.monthlyBudget > 0;
    final customBudgets = finance.budgets.where((b) => b.limit > 0).toList();
    if (!settings.budgetAlerts || (!hasCap && customBudgets.isEmpty)) return;
    // With every threshold switched off no check can fire — skip the spend
    // computation entirely (this runs on every provider notification).
    if (!settings.alert80 && !settings.alert90 && !settings.alertOver) return;
    _busy = true;
    try {
      final now = DateTime.now();
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

      // Each entry: spend, cap, dedup key, notification id, and an optional
      // budget name for the alert text.
      final checks =
          <({double spent, double cap, String key, int id, String? name})>[
            if (hasCap)
              (
                spent: finance.budgetSpentInMonth(month),
                cap: settings.monthlyBudget,
                key: budgetAlertMonthKey(now),
                id: 90000 + now.month, // stable per month
                name: null,
              ),
            for (final b in customBudgets)
              (
                spent: finance.budgetSpentFor(b, month),
                cap: b.limit,
                key: customBudgetAlertKey(b.id, now),
                // Stable per budget (Dart string hashes are content-derived);
                // distinct from the cap's 90000-range ids. Masked, not .abs():
                // abs() of the minimum int is still negative, and a wider range
                // makes two budgets colliding on one notification id unlikely.
                id: 92000 + ((b.id.hashCode & 0x7fffffff) % 100000),
                name: b.name,
              ),
          ];

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
        await notifications.show(id: c.id, title: text.title, body: text.body);
        await prefs.setInt(c.key, level);
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
