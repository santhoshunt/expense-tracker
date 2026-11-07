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
  // A barrier: a full-ledger report takes a moment, and no second tap may
  // start another.
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Dialog(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 16),
                Flexible(child: Text('Building PDF report…')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  String? path;
  Object? error;
  try {
    path = await BackupService.exportPdf(finance, range: range);
  } catch (e) {
    error = e;
  } finally {
    if (navigator.mounted) navigator.pop();
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
