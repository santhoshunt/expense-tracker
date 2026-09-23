import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// Tones for [showAppToast]: each picks the icon's tint and a fallback icon.
/// Call sites pass the operation's own icon; the tone says what kind of
/// outcome it was: [change] edits (accent), [removal] deletes and discards
/// (the destructive rose), [success] confirmations and saves (green).
enum AppToastTone { success, change, removal, error, info }

/// The app's toast: a floating pill (shape and colours come from the theme's
/// snackBarTheme) led by a tinted status icon, so the outcome reads at a
/// glance before the words do.
///
/// A newer toast replaces the current one rather than stacking.
void showAppToast(
  BuildContext context,
  String message, {
  AppToastTone tone = AppToastTone.info,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) => showAppToastOn(
  ScaffoldMessenger.of(context),
  message,
  tone: tone,
  icon: icon,
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
  IconData? icon,
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
            final (fallback, color) = switch (tone) {
              AppToastTone.success => (
                Icons.check,
                AppColors.of(context).green,
              ),
              AppToastTone.change => (Icons.edit_outlined, scheme.primary),
              AppToastTone.removal => (Icons.delete_outline, scheme.error),
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
                  child: Icon(icon ?? fallback, size: 16, color: color),
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
///
/// [icon] is required: it names the operation being undone (a bin for a
/// delete, a link for a pairing), so no two operations share a generic icon.
void showUndoSnackBar(
  BuildContext context,
  String message,
  VoidCallback onUndo, {
  required IconData icon,
  AppToastTone tone = AppToastTone.change,
}) => showAppToast(
  context,
  message,
  tone: tone,
  icon: icon,
  actionLabel: 'Undo',
  onAction: onUndo,
  duration: const Duration(seconds: 5),
);
