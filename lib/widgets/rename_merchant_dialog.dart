import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import 'info_tip.dart';
import 'one_field_dialog.dart';
import 'undo_snackbar.dart';

/// Gives a payee a readable name. Parsed identities can be a VPA fragment
/// or an FD reference ("Fd No"), and the alias follows the identity into
/// Top merchants, Upcoming, Subscriptions and search. Shared by the
/// dashboard's merchant rows and the Subscriptions tab.
///
/// [identity] is the normalized merchant identity (merchantIdentityOf);
/// [currentLabel] fills the field. A blank name cannot be saved: Reset is
/// the one way to clear a name, and either offers Undo.
Future<void> showRenameMerchantDialog(
  BuildContext context, {
  required String identity,
  required String currentLabel,
}) async {
  final finance = context.read<FinanceProvider>();
  final existing = finance.merchantAlias(identity);
  final result = await showOneFieldDialog(
    context,
    title: 'Rename merchant',
    label: 'Display name',
    tip: InfoTip(
      title: 'Display name',
      message:
          'Detected as "$identity". The name shows wherever this merchant '
          'appears.',
    ),
    keyboard: TextInputType.text,
    capitalization: TextCapitalization.words,
    initial: currentLabel,
    problem: (text) => text.trim().isEmpty ? 'Enter a name' : null,
    extraAction: existing == null
        ? null
        // Its own context: the dialog's navigator, which may not be the
        // caller's (a sheet's nested one).
        : Builder(
            builder: (ctx) => TextButton(
              // Empty string = clear the alias (distinct from Cancel's null).
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Reset'),
            ),
          ),
  );
  if (result == null) return;
  await finance.setMerchantAlias(identity, result);
  if (!context.mounted) return;
  final name = result.trim();
  showUndoSnackBar(
    context,
    name.isEmpty ? 'Name reset to "$identity"' : 'Renamed to "$name"',
    () => finance.setMerchantAlias(identity, existing),
    icon: Icons.edit_outlined,
  );
}
