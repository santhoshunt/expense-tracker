/// Pure budget-threshold logic, separated from the notification plumbing so
/// it can be unit-tested.
///
/// Thresholds are the integers 80, 90 and 100 (100 = "over budget"). Given the
/// spend so far, the cap, which thresholds are enabled, and the highest level
/// already notified this month, [budgetLevelToNotify] returns the single next
/// level to alert on (the highest newly-crossed enabled threshold), or null
/// when there is nothing new to say.
int? budgetLevelToNotify({
  required double spent,
  required double cap,
  required int lastNotified,
  required bool en80,
  required bool en90,
  required bool enOver,
}) {
  if (cap <= 0) return null;
  final pct = spent / cap * 100;
  // Highest crossed level first; only fire if enabled and not already sent.
  if (pct >= 100 && enOver && lastNotified < 100) return 100;
  if (pct >= 90 && en90 && lastNotified < 90) return 90;
  if (pct >= 80 && en80 && lastNotified < 80) return 80;
  return null;
}

/// SharedPreferences key holding the highest budget level already notified
/// for [month]. Cleared when the cap changes so thresholds re-evaluate
/// against the new cap.
String budgetAlertMonthKey(DateTime month) =>
    'budget_alert_fired_${month.year}-${month.month.toString().padLeft(2, '0')}';

/// Same, but for one custom [SpendBudget] (keyed by its id). Cleared when
/// that budget is edited so thresholds re-evaluate against the new limit.
String customBudgetAlertKey(String budgetId, DateTime month) =>
    'budget_alert_fired_${budgetId}_${month.year}-'
    '${month.month.toString().padLeft(2, '0')}';

/// Human-readable alert text for a crossed [level] (80 / 90 / 100).
/// Pass [name] for a custom budget; without it the text describes the
/// overall monthly budget.
({String title, String body}) budgetAlertText({
  required int level,
  required double spent,
  required double cap,
  required String Function(double) money,
  String? name,
}) {
  final spentStr = money(spent);
  final capStr = money(cap);
  if (name != null) {
    return (
      title: level >= 100 ? '"$name" over budget' : '$level% of "$name" used',
      body: 'You have spent $spentStr of the $capStr "$name" budget.',
    );
  }
  if (level >= 100) {
    return (
      title: 'Over budget',
      body: 'You have spent $spentStr of your $capStr monthly budget.',
    );
  }
  return (
    title: '$level% of budget used',
    body: 'You have spent $spentStr of your $capStr monthly budget.',
  );
}
