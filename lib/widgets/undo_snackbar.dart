import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// Tones for [showAppToast]: each picks the leading icon and its tint.
enum AppToastTone { success, undo, error, info }

/// The app's toast: a floating pill (shape and colours come from the theme's
/// snackBarTheme) led by a tinted status icon, so the outcome reads at a
/// glance before the words do.
///
/// A newer toast replaces the current one rather than stacking.
void showAppToast(
  BuildContext context,
  String message, {
  AppToastTone tone = AppToastTone.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) => showAppToastOn(
  ScaffoldMessenger.of(context),
  message,
  tone: tone,
  actionLabel: actionLabel,
  onAction: onAction,
  duration: duration,
);

/// [showAppToast] for call sites that captured the messenger before an
/// await, where the original context may be gone by the time the outcome is
/// known. Colours resolve inside the snackbar's own context, so no theme is
/// read through the stale one.
void showAppToastOn(
  ScaffoldMessengerState messenger,
  String message, {
  AppToastTone tone = AppToastTone.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: duration,
        content: Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            final (icon, color) = switch (tone) {
              AppToastTone.success => (
                Icons.check,
                AppColors.of(context).green,
              ),
              AppToastTone.undo => (Icons.undo, scheme.primary),
              AppToastTone.error => (Icons.error_outline, scheme.error),
              AppToastTone.info => (
                Icons.info_outline,
                scheme.onSurfaceVariant,
              ),
            };
            return Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(message)),
              ],
            );
          },
        ),
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
}

/// The app's delete model: destructive taps act immediately and offer a
/// short Undo window here, instead of interrupting with a confirmation
/// dialog. Confirmation dialogs are reserved for bulk or truly
/// unrecoverable actions (confirm-all, delete-all, merge).
///
/// A newer snackbar replaces the current one, which simply forfeits that
/// undo window — acceptable, and far less intrusive than stacking them.
void showUndoSnackBar(
  BuildContext context,
  String message,
  VoidCallback onUndo,
) => showAppToast(
  context,
  message,
  tone: AppToastTone.undo,
  actionLabel: 'Undo',
  onAction: onUndo,
  duration: const Duration(seconds: 5),
);
