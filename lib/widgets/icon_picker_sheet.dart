import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';

/// The budget dialog's icon grid: Automatic first, then every
/// [kCategoryIconChoices] icon. Returns '' for Automatic, the picked key
/// for an icon, and null when dismissed. [selected] is the current key
/// (null for Automatic); [automaticIcon] is what Automatic shows now.
Future<String?> showIconPickerSheet(
  BuildContext context, {
  required String? selected,
  required IconData automaticIcon,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      final text = Theme.of(sheetCtx).textTheme;
      final accent = scheme.primary;

      Widget tile({
        required String key,
        required IconData icon,
        required String label,
        required bool isSelected,
      }) => Semantics(
        button: true,
        selected: isSelected,
        label: label,
        // The InkWell's tap, exposed past excludeSemantics.
        onTap: () => Navigator.pop(sheetCtx, key),
        excludeSemantics: true,
        // A 40dp tile in a 48dp tap target. The InkWell fills the 48dp
        // square: inside a Center only the 40dp tile would take the tap.
        child: SizedBox(
          width: 48,
          height: 48,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.control),
            onTap: () => Navigator.pop(sheetCtx, key),
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isSelected
                      ? accent.withValues(alpha: 0.15)
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: isSelected
                      ? Border.all(color: accent, width: 2)
                      : null,
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: isSelected
                      ? categoryGlyphColor(sheetCtx, accent)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );

      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Budget icon', style: text.titleLarge),
            const SizedBox(height: 16),
            // Automatic on a row of its own, with what it does: inside the
            // grid it read as one more icon, next to a near-identical one.
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.control),
              onTap: () => Navigator.pop(sheetCtx, ''),
              child: Row(
                children: [
                  tile(
                    key: '',
                    icon: automaticIcon,
                    label: 'Automatic',
                    isSelected: selected == null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Automatic', style: text.bodyLarge),
                        Text(
                          "The category's icon for an Only these budget with "
                          'one category, otherwise a general one',
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in kCategoryIconChoices.entries)
                  tile(
                    key: entry.key,
                    icon: entry.value,
                    label: entry.key,
                    isSelected: entry.key == selected,
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
