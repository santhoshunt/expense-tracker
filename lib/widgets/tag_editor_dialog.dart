import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'dispose_scope.dart';
import 'hue_color_picker.dart';
import 'undo_snackbar.dart';

/// Edits one tag everywhere it is used: its name (renaming to an existing
/// tag merges the two), its colour, or deletes it. Opened from the Tags
/// tab and a By tags row on Breakdown. Not from the edit sheet: its Undo
/// toast would sit under the sheet, out of reach.
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
  final existing = [for (final u in finance.allTags) u.tag];
  final startColour = finance.tagColor(tag) ?? kNoCategoryColor;
  final ctrl = TextEditingController(text: tag);
  var colour = startColour;

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
          return AlertDialog(
            title: const Text('Edit tag'),
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
                    helperText: merges == null
                        ? null
                        : 'Merges with the existing tag "$merges"',
                    helperMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
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
  final name = result.name;
  if (name == null) {
    final before = await finance.deleteTag(tag);
    onEdited?.call(null);
    if (!context.mounted) return;
    showUndoSnackBar(
      context,
      before.isEmpty
          ? 'Deleted tag "$tag"'
          : 'Deleted tag "$tag" from ${before.length} '
                '${before.length == 1 ? 'transaction' : 'transactions'}',
      () async {
        await finance.restoreEditedTransactions(before);
        await finance.restoreTagColors(colours);
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
      onEdited?.call(tag);
    },
    icon: Icons.edit_outlined,
  );
}
