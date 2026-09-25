import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Something outside the app asked it to open a particular place: a
/// launcher shortcut, the Quick Settings tile, or a notification tap.
enum LaunchAction { addExpense, importSms, openRecap }

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
      final payload = await coldNotificationPayload?.call();
      if (payload == kRecapPayload) pending.value = LaunchAction.openRecap;
    } catch (e) {
      debugPrint('Notification launch details failed: $e');
    }
  }

  /// A tapped notification's payload, delivered while the app runs.
  void onNotificationPayload(String? payload) {
    if (payload == kRecapPayload) pending.value = LaunchAction.openRecap;
  }

  @visibleForTesting
  void resetForTest() {
    _initialised = false;
    pending.value = null;
  }
}

/// Payload on the monthly recap notification.
const String kRecapPayload = 'recap';
