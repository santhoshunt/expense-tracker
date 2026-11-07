import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../screens/app_nav.dart';
import '../screens/transactions_screen.dart' show TxFilterRequest;
import 'dispose_scope.dart';
import 'hue_color_picker.dart';
import 'undo_snackbar.dart';

/// Edits one tag everywhere it is used: its name (renaming to an existing
/// tag merges the two), its colour, or deletes it; it also opens the tag's
/// transactions. Opened from the Tags tab and a By tags row on Breakdown.
/// Not from the edit sheet: its Undo toast would sit under the sheet, out
/// of reach.
///
/// Every change applies to all rows at once and offers one Undo that puts
/// back both the rows and the colours. [onEdited] reports the tag's name
/// after each change: the new name after a rename (the same one when only
/// the colour changed), null after a delete, and the original after an
/// Undo, so an open edit sheet can follow along.
Future<void> showTagEditor(
  BuildContext context,
  String tag, {
  ValueChanged<String?>? onEdited,
}) async {
  final finance = context.read<FinanceProvider>();
  final existing = [
    for (final u in finance.allTags) u.tag,
    ...finance.emptyTags,
  ];
  final startColour = finance.tagColor(tag) ?? kNoCategoryColor;
  final ctrl = TextEditingController(text: tag);
  var colour = startColour;
  final count =
      finance.tagSummaries.where((s) => s.tag == tag).firstOrNull?.count ?? 0;
  // The budgets deleteTag takes with the tag.
  final budgets = finance.budgets
      .where((x) => x.tag != null && tagKey(x.tag!) == tagKey(tag))
      .length;
  final rowsText = count == 1 ? '1 transaction' : '$count transactions';
  final budgetsText = budgets == 1 ? '1 budget' : '$budgets budgets';
  // "On 3 transactions · 1 budget" and what Delete does, each part left
  // out at 0.
  final usedOn = [if (count > 0) rowsText, if (budgets > 0) budgetsText];
  final deletes = [
    if (count > 0) 'removes it from $rowsText',
    if (budgets > 0) 'deletes $budgetsText',
  ];

  final result = await showDialog<({String? name, Color colour})>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final name = normalizeTags([ctrl.text]).firstOrNull;
          final merges = name == null || tagKey(name) == tagKey(tag)
              ? null
              : existing.where((e) => tagKey(e) == tagKey(name)).firstOrNull;
          final changed =
              name != null && (name != tag || colour != startColour);
          final theme = Theme.of(ctx);
          final quiet = theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          );
          return AlertDialog(
            title: const Text('Edit tag'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Where the tag is used, under the title.
                if (count > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.list_alt),
                      label: Text('See $rowsText'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        AppNav.instance.openTransactions(
                          context,
                          TxFilterRequest(tag: tag),
                        );
                      },
                    ),
                  ),
                if (usedOn.isNotEmpty)
                  Text('On ${usedOn.join(' · ')}', style: quiet),
                // Keeps the floating "Name" label inside the dialog.
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLength: kMaxTagLength,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    // A name that normalises to nothing (blank, or only
                    // "|") says why Save is off.
                    helperText: name == null
                        ? 'Enter a name'
                        : merges == null
                        ? null
                        : 'Merges with the existing tag "$merges"',
                    helperMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
                  // The keyboard's done key saves, as Save would.
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (changed) {
                      Navigator.pop(ctx, (name: name, colour: colour));
                    }
                  },
                ),
                const SizedBox(height: 8),
                HueColorPicker(
                  value: colour,
                  noneLabel: 'Default',
                  customTitle: 'Tag colour',
                  onChanged: (c) => setState(() => colour = c),
                ),
                // Delete acts at once, with Undo: say what it takes first.
                if (deletes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Delete ${deletes.join(' and ')}', style: quiet),
                ],
              ],
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () =>
                    Navigator.pop(ctx, (name: null, colour: colour)),
                child: const Text('Delete'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: changed
                    ? () => Navigator.pop(ctx, (name: name, colour: colour))
                    : null,
                child: Text(merges == null ? 'Save' : 'Merge'),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (result == null || !context.mounted) return;

  final colours = finance.tagColorSnapshot;
  final savedBefore = finance.savedTags;
  final budgetsBefore = finance.budgets;
  final name = result.name;
  if (name == null) {
    final before = await finance.deleteTag(tag);
    onEdited?.call(null);
    if (!context.mounted) return;
    final budgetsGone = budgetsBefore.length - finance.budgets.length;
    final budgetText = budgetsGone <= 0
        ? ''
        : budgetsGone == 1
        ? ' and its budget'
        : ' and its $budgetsGone budgets';
    showUndoSnackBar(
      context,
      before.isEmpty
          ? 'Deleted tag "$tag"$budgetText'
          : 'Deleted tag "$tag" from ${before.length} '
                '${before.length == 1 ? 'transaction' : 'transactions'}'
                '$budgetText',
      () async {
        await finance.restoreEditedTransactions(before);
        await finance.restoreTagColors(colours);
        await finance.restoreSavedTags(savedBefore);
        await finance.restoreBudgets(budgetsBefore);
        onEdited?.call(tag);
      },
      icon: Icons.delete_outline,
      tone: AppToastTone.removal,
    );
    return;
  }

  final merged =
      name != tag &&
      tagKey(name) != tagKey(tag) &&
      existing.any((e) => tagKey(e) == tagKey(name));
  final before = name == tag
      ? const <Tx>[]
      : await finance.renameTag(tag, name);
  if (result.colour != startColour) {
    await finance.setTagColor(
      name,
      result.colour == kNoCategoryColor ? null : result.colour,
    );
  }
  onEdited?.call(name);
  if (!context.mounted) return;
  showUndoSnackBar(
    context,
    name == tag
        ? 'Changed the colour of "$tag"'
        : merged
        ? 'Merged "$tag" into "$name"'
        : 'Renamed "$tag" to "$name"',
    () async {
      await finance.restoreEditedTransactions(before);
      await finance.restoreTagColors(colours);
      await finance.restoreSavedTags(savedBefore);
      await finance.restoreBudgets(budgetsBefore);
      onEdited?.call(tag);
    },
    icon: Icons.edit_outlined,
  );
}

/// Makes a tag before any payment carries it (Cockpit's New tag): a name
/// under the tag editor's rules and a colour. A name a tag already has,
/// ignoring case, cannot be saved.
Future<void> showNewTagDialog(BuildContext context) async {
  final finance = context.read<FinanceProvider>();
  final existing = [
    for (final u in finance.allTags) u.tag,
    ...finance.emptyTags,
  ];
  final ctrl = TextEditingController();
  var colour = kNoCategoryColor;
  final result = await showDialog<({String name, Color colour})>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final name = normalizeTags([ctrl.text]).firstOrNull;
          final taken = name == null
              ? null
              : existing.where((e) => tagKey(e) == tagKey(name)).firstOrNull;
          return AlertDialog(
            title: const Text('New tag'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLength: kMaxTagLength,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    // A name that normalises to nothing (blank, or only
                    // "|") says why Save is off.
                    helperText: name == null
                        ? 'Enter a name'
                        : taken == null
                        ? null
                        : 'A tag named "$taken" already exists',
                    helperMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
                  // The keyboard's done key saves, as Save would.
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (name != null && taken == null) {
                      Navigator.pop(ctx, (name: name, colour: colour));
                    }
                  },
                ),
                const SizedBox(height: 8),
                HueColorPicker(
                  value: colour,
                  noneLabel: 'Default',
                  customTitle: 'Tag colour',
                  onChanged: (c) => setState(() => colour = c),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: name != null && taken == null
                    ? () => Navigator.pop(ctx, (name: name, colour: colour))
                    : null,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (result == null) return;
  await finance.addSavedTag(
    result.name,
    result.colour == kNoCategoryColor ? null : result.colour,
  );
}
