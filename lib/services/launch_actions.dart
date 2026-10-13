import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Something outside the app asked it to open a particular place: a
/// launcher shortcut, the Quick Settings tile, a notification tap, or a
/// home-screen widget (each widget opens its own part of the app).
enum LaunchAction {
  addExpense,
  importSms,
  openRecap,
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
  /// month are also held for [takeHistory].
  LaunchAction? _fromPayload(String? payload) {
    if (payload != null && payload.startsWith(kUnusualPayloadPrefix)) {
      final h = parseUnusualPayload(payload);
      if (h == null) return null;
      _history = h;
      return LaunchAction.openCategoryHistory;
    }
    return switch (payload) {
      kRecapPayload => LaunchAction.openRecap,
      kReviewPayload => LaunchAction.openReview,
      _ => null,
    };
  }

  @visibleForTesting
  void resetForTest() {
    _initialised = false;
    _history = null;
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

/// Payload on the monthly recap notification.
const String kRecapPayload = 'recap';

/// Payload on the "transactions to review" notification.
const String kReviewPayload = 'review';
