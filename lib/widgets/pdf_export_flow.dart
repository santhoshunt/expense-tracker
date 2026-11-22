import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/finance_provider.dart';
import '../services/backup_service.dart';
import 'export_sheet.dart';
import 'undo_snackbar.dart';

/// The PDF report export, shared by Settings and the Accounts ⋮ menu: asks
/// which dates on the export sheet, shows a spinner while the report
/// builds, then a toast with where it was saved, or why it failed.
/// Dismissing the sheet exports nothing. With [rangeChosen] the caller's
/// own sheet already asked (Settings' Export), so [range] is used as given
/// (null for all).
Future<void> exportPdfWithRange(
  BuildContext context,
  FinanceProvider finance, {
  DateTimeRange? range,
  bool rangeChosen = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!rangeChosen) {
    final picked = await showExportSheet(context, pdfOnly: true);
    if (picked == null || !context.mounted) return;
    range = picked.range;
  }
  String? path;
  Object? error;
  try {
    // A barrier: a full-ledger report takes a moment, and no second tap may
    // start another.
    path = await withBusySpinner(
      context,
      'Building PDF report…',
      () => BackupService.exportPdf(finance, range: range),
    );
  } catch (e) {
    error = e;
  }
  if (error != null) {
    showAppToastOn(
      messenger,
      'Export failed: $error',
      tone: AppToastTone.error,
    );
  } else if (path != null && path.isNotEmpty) {
    showAppToastOn(
      messenger,
      'Saved to $path',
      tone: AppToastTone.success,
      icon: Icons.download_done,
    );
  }
}

/// Runs [work] behind a spinner dialog that no tap or back press closes,
/// and closes that dialog when [work] ends, however it ends.
///
/// The dialog's own route is removed, never the top one: a page pushed over
/// the spinner meanwhile (a home-screen widget opening Cockpit) stays, and
/// the spinner does not outlive its work.
Future<T> withBusySpinner<T>(
  BuildContext context,
  String label,
  Future<T> Function() work,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // As showDialog builds it, kept so this exact route can be removed.
  final route = DialogRoute<void>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Flexible(child: Text(label)),
            ],
          ),
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    return await work();
  } finally {
    if (route.isCurrent) {
      navigator.pop();
    } else if (route.isActive) {
      navigator.removeRoute(route);
    }
  }
}
