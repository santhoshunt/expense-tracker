import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/finance_provider.dart';
import '../services/backup_service.dart';
import 'undo_snackbar.dart';

/// The PDF report export, shared by Settings, Backup and the Accounts ⋮
/// menu: asks which dates (all, or a picked range), shows a spinner while
/// the report builds, then a toast with where it was saved, or why it
/// failed. Cancelling at either question exports nothing.
Future<void> exportPdfWithRange(
  BuildContext context,
  FinanceProvider finance,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Export which dates?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, 'all'),
          child: const Text('All transactions'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, 'range'),
          child: const Text('Choose dates…'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  DateTimeRange? range;
  if (choice == 'range') {
    final now = DateTime.now();
    range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (range == null || !context.mounted) return;
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
