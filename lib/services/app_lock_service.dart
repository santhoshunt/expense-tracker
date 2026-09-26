import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// How an unlock attempt ended, so the lock screen can say why it failed.
enum UnlockOutcome {
  success,

  /// The user (or the system) dismissed the prompt. Nothing to explain.
  cancelled,

  /// Too many failed attempts; the fingerprint is off for a while.
  lockedOut,

  /// The device no longer has any screen lock, so no prompt can succeed.
  noScreenLock,

  /// Anything else the prompt reported.
  failed,
}

/// Thin wrapper over local_auth so the lock gate and Settings can be tested
/// with a fake. Android needs FlutterFragmentActivity — see MainActivity.kt.
class AppLockService {
  final LocalAuthentication _auth = LocalAuthentication();

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether the device can show any unlock prompt (biometrics enrolled, or
  /// a PIN/pattern/password set). False on unsupported platforms.
  Future<bool> isSupported() async {
    if (!_supported) return false;
    try {
      return await _auth.isDeviceSupported();
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// [isSupported] for the turn-off path: null when the platform could not
  /// answer. Only a definite false (no screen lock at all) may skip the
  /// prompt; a passing error must not switch the lock off unasked.
  Future<bool?> canAuthenticate() async {
    if (!_supported) return false;
    try {
      return await _auth.isDeviceSupported();
    } on LocalAuthException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Shows the system unlock prompt: biometric with device-credential
  /// (PIN/pattern) fallback.
  Future<UnlockOutcome> unlock() async {
    if (!_supported) return UnlockOutcome.failed;
    return runUnlock(
      () => _auth.authenticate(
        localizedReason: 'Unlock Expense Tracker',
        biometricOnly: false,
        // The prompt itself backgrounds the app; this resumes the
        // authentication instead of failing it.
        persistAcrossBackgrounding: true,
      ),
    );
  }

  /// [unlock] for callers that only need yes or no (Settings).
  Future<bool> authenticate() async => await unlock() == UnlockOutcome.success;

  /// Runs [prompt] and sorts what it reported. From local_auth 3 a cancel or
  /// a lockout throws [LocalAuthException] rather than returning false; a
  /// channel error can still arrive as a [PlatformException].
  @visibleForTesting
  static Future<UnlockOutcome> runUnlock(Future<bool> Function() prompt) async {
    try {
      return await prompt() ? UnlockOutcome.success : UnlockOutcome.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => UnlockOutcome.lockedOut,
        LocalAuthExceptionCode.noCredentialsSet => UnlockOutcome.noScreenLock,
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.userRequestedFallback => UnlockOutcome.cancelled,
        _ => UnlockOutcome.failed,
      };
    } on PlatformException {
      return UnlockOutcome.failed;
    }
  }
}
