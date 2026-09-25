import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import 'dispose_scope.dart';

/// Gives a payee a readable name. Parsed identities can be a VPA fragment
/// or an FD reference ("Fd No"), and the alias follows the identity into
/// Top merchants, Upcoming, Subscriptions and search. Shared by the
/// dashboard's merchant rows and the Subscriptions tab.
///
/// [identity] is the normalized merchant identity (merchantIdentityOf);
/// [currentLabel] fills the field.
Future<void> showRenameMerchantDialog(
  BuildContext context, {
  required String identity,
  required String currentLabel,
}) async {
  final finance = context.read<FinanceProvider>();
  final existing = finance.merchantAlias(identity);
  final ctrl = TextEditingController(text: currentLabel);
  final result = await showDialog<String?>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: AlertDialog(
        title: const Text('Rename merchant'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Display name',
            helperText: 'Detected as "$identity"',
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          if (existing != null)
            TextButton(
              // Empty string = clear the alias (distinct from Cancel's null).
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Reset'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (result == null) return;
  await finance.setMerchantAlias(identity, result);
}
