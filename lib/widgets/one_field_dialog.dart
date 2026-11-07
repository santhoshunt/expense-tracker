import 'package:flutter/material.dart';

import 'dispose_scope.dart';
import 'info_tip.dart';

/// A one-field editor (Set balance, Credit limit, Rename…): what the value
/// is now and where it came from ([nowLine]), the field with its [tip] at
/// its end, a live helper and error, and Cancel and Save. Save stays
/// disabled until the text reads ([problem] null) and differs from
/// [initial]; Done on the keyboard saves under the same rule. With
/// [requireChange] false an unchanged value saves too (Set balance: saving
/// the same figure again makes it newer than the last alert).
///
/// Returns the text on Save, null on Cancel or dismissal. The caller
/// parses, saves and offers the Undo.
Future<String?> showOneFieldDialog(
  BuildContext context, {
  required String title,
  String? nowLine,
  required String label,
  required InfoTip tip,
  String? Function(String text)? helperOf,
  String? prefix,
  TextInputType keyboard = const TextInputType.numberWithOptions(decimal: true),
  TextCapitalization capitalization = TextCapitalization.none,
  required String initial,
  required String? Function(String text) problem,
  String saveLabel = 'Save',
  Widget? extraAction,
  bool requireChange = true,
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [ctrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final theme = Theme.of(ctx);
          final text = ctrl.text;
          final changed = text.trim() != initial.trim() || !requireChange;
          final error = changed ? problem(text) : null;
          final canSave = changed && error == null;
          void save() => Navigator.pop(ctx, ctrl.text);
          return AlertDialog(
            // The keyboard and a two-line helper overflow a small
            // landscape screen without it.
            scrollable: true,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (nowLine != null) ...[
                  Text(
                    nowLine,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                ] else
                  // Keeps the floating label inside the dialog.
                  const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: keyboard,
                  textCapitalization: capitalization,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (canSave) save();
                  },
                  decoration: InputDecoration(
                    labelText: label,
                    // At the field's end, not in its label: a floating
                    // label is painted where it is not hit-tested, so an
                    // "i" there could not be tapped.
                    suffixIcon: tip,
                    prefixText: prefix,
                    helperText: helperOf?.call(text),
                    helperMaxLines: 2,
                    errorText: error,
                  ),
                ),
              ],
            ),
            actions: [
              ?extraAction,
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: canSave ? save : null,
                child: Text(saveLabel),
              ),
            ],
          );
        },
      ),
    ),
  );
}
