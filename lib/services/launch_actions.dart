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

  static LaunchAction? _fromPayload(String? payload) => switch (payload) {
    kRecapPayload => LaunchAction.openRecap,
    kReviewPayload => LaunchAction.openReview,
    _ => null,
  };

  @visibleForTesting
  void resetForTest() {
    _initialised = false;
    pending.value = null;
  }
}

/// Payload on the monthly recap notification.
const String kRecapPayload = 'recap';

/// Payload on the "transactions to review" notification.
const String kReviewPayload = 'review';
