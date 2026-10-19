import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Something outside the app asked it to open a particular place: a
/// launcher shortcut, the Quick Settings tile, a notification tap, or a
/// home-screen widget (each widget opens its own part of the app).
enum LaunchAction {
  addExpense,
  importSms,
  openRecap,

  /// The "Transactions to review" notification and the This week widget's
  /// review count: the review sheet over Transactions.
  openReview,
  openBudget,
  openBudgets,
  openPace,
  openUpcoming,
  openToday,
  openBreakdown,

  /// An unusual spending alert: the category's history sheet, for the
  /// category and month [LaunchActions.takeHistory] hands over.
  openCategoryHistory,

  /// The Quick actions widget's Income button: the add sheet as Income.
  addIncome,

  /// The Recent widget: the Transactions tab.
  openTransactions,

  /// The Monday note: the weekly digest sheet, on the week
  /// [LaunchActions.takeWeek] hands over.
  openWeeklyDigest,

  /// The Big bills widgets: the Big bills ahead sheet.
  openBigBills,

  /// The This week widgets: the weekly digest sheet on the current week.
  openThisWeek,
}

/// Receives [LaunchAction]s from Android and holds the newest one in
/// [pending] until Home can act on it (loaded, unlocked, mounted).
///
/// A single instance, like AppNav: the native side reaches it through a
/// method channel before any screen exists, and Home consumes it later.
class LaunchActions {
  LaunchActions._();
  static final LaunchActions instance = LaunchActions._();

  static const channel = MethodChannel('expense_tracker/launch');

  /// The action waiting to run. Home clears it before running it, so a
  /// rebuild or a second listener call can never run it twice.
  final ValueNotifier<LaunchAction?> pending = ValueNotifier(null);

  /// The category and month an [LaunchAction.openCategoryHistory] is about.
  /// Set before [pending], so a listener never sees the action without it.
  ({String categoryId, DateTime month})? _history;

  /// The category and month for a pending
  /// [LaunchAction.openCategoryHistory], once.
  ({String categoryId, DateTime month})? takeHistory() {
    final h = _history;
    _history = null;
    return h;
  }

  /// The Monday an [LaunchAction.openWeeklyDigest] is about. Set before
  /// [pending], as [_history] is.
  DateTime? _week;

  /// The week for a pending [LaunchAction.openWeeklyDigest], once.
  DateTime? takeWeek() {
    final w = _week;
    _week = null;
    return w;
  }

  bool _initialised = false;

  /// Native action names, as MainActivity puts them in the intent extra.
  static LaunchAction? fromName(String? name) => switch (name) {
    'add_expense' => LaunchAction.addExpense,
    'import_sms' => LaunchAction.importSms,
    'open_budget' => LaunchAction.openBudget,
    'open_budgets' => LaunchAction.openBudgets,
    'open_pace' => LaunchAction.openPace,
    'open_upcoming' => LaunchAction.openUpcoming,
    'open_today' => LaunchAction.openToday,
    'open_breakdown' => LaunchAction.openBreakdown,
    'add_income' => LaunchAction.addIncome,
    'open_transactions' => LaunchAction.openTransactions,
    'open_big_bills' => LaunchAction.openBigBills,
    'open_review' => LaunchAction.openReview,
    // The widget names no week: it always opens the current one.
    'open_weekly_digest' => LaunchAction.openThisWeek,
    _ => null,
  };

  /// Listens for warm launches and collects the cold-start action, if any.
  /// [coldNotificationPayload] is the payload of a notification that
  /// started the app. Android only; a no-op elsewhere.
  Future<void> init({
    Future<String?> Function()? coldNotificationPayload,
  }) async {
    if (_initialised) return;
    _initialised = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'launchAction') {
        final action = fromName(call.arguments as String?);
        if (action != null) pending.value = action;
      }
      return null;
    });
    try {
      final cold = fromName(
        await channel.invokeMethod<String>('takeLaunchAction'),
      );
      if (cold != null) pending.value = cold;
    } catch (e) {
      // A missing native side (tests, an old build) means no action.
      debugPrint('takeLaunchAction failed: $e');
    }
    try {
      final action = _fromPayload(await coldNotificationPayload?.call());
      if (action != null) pending.value = action;
    } catch (e) {
      debugPrint('Notification launch details failed: $e');
    }
  }

  /// A tapped notification's payload, delivered while the app runs.
  void onNotificationPayload(String? payload) {
    final action = _fromPayload(payload);
    if (action != null) pending.value = action;
  }

  /// Maps [payload] to its action. An unusual spending alert's category and
  /// month are also held for [takeHistory], and a digest note's week for
  /// [takeWeek].
  LaunchAction? _fromPayload(String? payload) {
    if (payload != null && payload.startsWith(kUnusualPayloadPrefix)) {
      final h = parseUnusualPayload(payload);
      if (h == null) return null;
      _history = h;
      return LaunchAction.openCategoryHistory;
    }
    if (payload != null && payload.startsWith(kWeeklyPayloadPrefix)) {
      final week = parseWeeklyPayload(payload);
      if (week == null) return null;
      _week = week;
      return LaunchAction.openWeeklyDigest;
    }
    return switch (payload) {
      kRecapPayload => LaunchAction.openRecap,
      kReviewPayload => LaunchAction.openReview,
      kUpcomingPayload => LaunchAction.openUpcoming,
      kBudgetPayload => LaunchAction.openBudget,
      kBudgetsPayload => LaunchAction.openBudgets,
      _ => null,
    };
  }

  @visibleForTesting
  void resetForTest() {
    _initialised = false;
    _history = null;
    _week = null;
    pending.value = null;
  }
}

/// Payload prefix on an unusual spending alert, followed by the alert's
/// month and the raw category id: `unusual:2025-12:food`. The month travels
/// with it, so a tap the next month still opens the month it was about.
const String kUnusualPayloadPrefix = 'unusual:';

/// [kUnusualPayloadPrefix]'s payload for [categoryId] in [month].
String unusualPayload(String categoryId, DateTime month) =>
    '$kUnusualPayloadPrefix${month.year}-'
    '${month.month.toString().padLeft(2, '0')}:$categoryId';

/// The category and month in an [unusualPayload]; null when malformed.
({String categoryId, DateTime month})? parseUnusualPayload(String payload) {
  if (!payload.startsWith(kUnusualPayloadPrefix)) return null;
  final rest = payload.substring(kUnusualPayloadPrefix.length);
  final m = RegExp(r'^(\d{4})-(\d{2}):(.+)$').firstMatch(rest);
  if (m == null) return null;
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12) return null;
  return (
    categoryId: m.group(3)!,
    month: DateTime(int.parse(m.group(1)!), month),
  );
}

/// Payload prefix on the weekly digest note, followed by the Monday of the
/// week it covers: `weekly:2026-10-12`. A tap days later still opens that
/// week.
const String kWeeklyPayloadPrefix = 'weekly:';

/// [kWeeklyPayloadPrefix]'s payload for the week starting [week].
String weeklyPayload(DateTime week) =>
    '$kWeeklyPayloadPrefix${week.year}-'
    '${week.month.toString().padLeft(2, '0')}-'
    '${week.day.toString().padLeft(2, '0')}';

/// The Monday in a [weeklyPayload]; null when malformed, not a real date
/// (2026-02-30 would roll into March) or not a Monday.
DateTime? parseWeeklyPayload(String payload) {
  if (!payload.startsWith(kWeeklyPayloadPrefix)) return null;
  final rest = payload.substring(kWeeklyPayloadPrefix.length);
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(rest);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final week = DateTime(year, month, day);
  if (week.year != year || week.month != month || week.day != day) {
    return null;
  }
  return week.weekday == DateTime.monday ? week : null;
}

/// Payload on the monthly recap notification.
const String kRecapPayload = 'recap';

/// Payload on the "transactions to review" notification.
const String kReviewPayload = 'review';

// The alerts below carry the launch name of the home-screen widget for the
// same card, so a tap lands where that widget's tap does.

/// Payload on card bill, recurring payment and reminder alerts: the Next 7
/// days card, as the Upcoming widget opens it.
const String kUpcomingPayload = 'open_upcoming';

/// Payload on a monthly budget alert: the Monthly budget card.
const String kBudgetPayload = 'open_budget';

/// Payload on a custom budget alert: the Budgets card.
const String kBudgetsPayload = 'open_budgets';
