/// Every local notification id the app posts, in one table, so no two
/// alerts can land on the same id (a shared id replaces the earlier note in
/// the shade, or cancels the scheduled recap).
///
/// `NotificationService.reviewNotificationId` (93000),
/// `NotificationService.recapNotificationId` (97000) and
/// `NotificationService.weeklyDigestNotificationId` (98000) stay declared in
/// notification_service.dart; [review], [recap] and [weeklyDigest] here must
/// equal them, and the tests check that they do.
///
/// Hashed ids mask the hash (`& 0x7fffffff`) rather than call abs(): abs()
/// of the minimum int is still negative.
abstract final class NotificationIds {
  /// Monthly cap alerts, one per calendar month: 90001 to 90012
  /// (BudgetMonitor).
  static const capStart = 90001;
  static const capEnd = 90012;

  /// The "imports to review" note (NotificationService.showReview).
  static const review = 93000;

  /// Card bill due alerts (UpcomingMonitor).
  static const cardBillStart = 94000;
  static const cardBillEnd = 94999;

  /// Recurring payment expected alerts (UpcomingMonitor).
  static const recurringStart = 95000;
  static const recurringEnd = 95999;

  /// Manual reminder alerts (UpcomingMonitor).
  static const reminderStart = 96000;
  static const reminderEnd = 96999;

  /// The scheduled monthly recap (NotificationService.scheduleRecap).
  static const recap = 97000;

  /// The scheduled Monday digest note
  /// (NotificationService.scheduleWeeklyDigest).
  static const weeklyDigest = 98000;

  /// Unusual spending alerts, one per category (UnusualSpendMonitor).
  static const unusualStart = 200000;
  static const unusualEnd = 299999;

  /// Custom budget alerts, one per budget (BudgetMonitor). Until v1.38.1
  /// they used 92000 plus a hash below 100000, which overlapped review,
  /// card bills, recurring, reminders and the recap.
  static const customBudgetStart = 300000;
  static const customBudgetEnd = 399999;

  /// Every range with its owner, for the overlap test. A fixed id is a
  /// range of one.
  static const ranges = <({int start, int end, String owner})>[
    (start: capStart, end: capEnd, owner: 'Monthly cap'),
    (start: review, end: review, owner: 'Imports to review'),
    (start: cardBillStart, end: cardBillEnd, owner: 'Card bills'),
    (start: recurringStart, end: recurringEnd, owner: 'Upcoming recurring'),
    (start: reminderStart, end: reminderEnd, owner: 'Reminders'),
    (start: recap, end: recap, owner: 'Monthly recap'),
    (start: weeklyDigest, end: weeklyDigest, owner: 'Weekly digest'),
    (start: unusualStart, end: unusualEnd, owner: 'Unusual spending'),
    (start: customBudgetStart, end: customBudgetEnd, owner: 'Custom budgets'),
  ];

  static int _hashed(int start, int end, String key) =>
      start + ((key.hashCode & 0x7fffffff) % (end - start + 1));

  /// The monthly cap alert for [month] (1 to 12).
  static int cap(int month) => 90000 + month;

  /// Stable per budget: Dart string hashes are content-derived.
  static int customBudget(String budgetId) =>
      _hashed(customBudgetStart, customBudgetEnd, budgetId);

  static int cardBill(String accountId) =>
      _hashed(cardBillStart, cardBillEnd, accountId);

  static int recurring(String hitKey) =>
      _hashed(recurringStart, recurringEnd, hitKey);

  static int reminder(String reminderId) =>
      _hashed(reminderStart, reminderEnd, reminderId);

  static int unusual(String categoryId) =>
      _hashed(unusualStart, unusualEnd, categoryId);
}
