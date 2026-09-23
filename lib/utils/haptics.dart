import 'package:flutter/services.dart';

/// Touch feedback in two strengths. Needs no permission: Android plays it
/// through the view's haptic feedback, which also follows the system's
/// touch-vibration setting.
abstract final class Haptics {
  /// A light tick: a selection changed (tab, segment, chart part, entering
  /// selection mode).
  static void tick() => HapticFeedback.selectionClick();

  /// A firmer bump: something was deleted.
  static void thud() => HapticFeedback.mediumImpact();
}
