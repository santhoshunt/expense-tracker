import 'package:flutter/material.dart';

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
) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      ),
    );
}
