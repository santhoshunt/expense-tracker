import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// One row of a list drawn as a single card: the first row rounds the top
/// corners, the last the bottom, and a hairline separates the rows. Lets a
/// flat list (transactions of a day, accounts of a type) read as one group
/// instead of a stack of separate cards, without restructuring the list.
class GroupedSurface extends StatelessWidget {
  final bool first;
  final bool last;
  final Widget child;

  const GroupedSurface({
    super.key,
    required this.first,
    required this.last,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    const r = Radius.circular(AppRadius.card);
    final outline = colors.cardOutline;
    return Container(
      // Flutter draws rounded corners only with one border on every side, so
      // an outlined palette outlines each row whole; the touching edges then
      // stand in for the hairline.
      decoration: BoxDecoration(
        color: colors.cardFill ?? scheme.surface,
        borderRadius: BorderRadius.vertical(
          top: first ? r : Radius.zero,
          bottom: last ? r : Radius.zero,
        ),
        border: outline == null ? null : Border.all(color: outline),
      ),
      clipBehavior: Clip.antiAlias,
      // Ink from a row's InkWell paints on this Material, above the fill.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!first && outline == null)
              Divider(
                height: 1,
                thickness: 1,
                indent: 14,
                endIndent: 14,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            child,
          ],
        ),
      ),
    );
  }
}
