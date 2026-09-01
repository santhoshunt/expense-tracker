import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

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
    } on PlatformException {
      return false;
    }
  }

  /// Shows the system unlock prompt; true only on success. Biometric with
  /// device-credential (PIN/pattern) fallback. Any platform error counts as
  /// a failed attempt — the gate stays locked and offers retry.
  Future<bool> authenticate() async {
    if (!_supported) return false;
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Expense Tracker',
        options: const AuthenticationOptions(
          biometricOnly: false,
          // The prompt itself backgrounds the app; stickyAuth resumes the
          // authentication instead of failing it.
          stickyAuth: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }
}
