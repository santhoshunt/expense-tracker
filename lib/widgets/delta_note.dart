import 'package:flutter/material.dart';

import '../services/spend_comparison.dart' show negligibleDelta;
import '../utils/app_theme.dart';

/// A spending change: a trend arrow, then [text] in the plain text colour.
/// The arrow carries the colour, red up for more and green down for less;
/// under a rupee either way ([negligibleDelta]) it is a blue = mark. Amounts
/// are never coloured. Shared by the monthly recap and the weekly digest.
class DeltaNote extends StatelessWidget {
  final String text;

  /// Spent minus what it is measured against.
  final double delta;
  final TextStyle? style;

  /// Two by default, as the recap's tight stat column needs; null lets a
  /// longer line wrap freely (the digest's, at large text).
  final int? maxLines;

  const DeltaNote({
    super.key,
    required this.text,
    required this.delta,
    this.style,
    this.maxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final negligible = negligibleDelta(delta);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          negligible
              ? Icons.drag_handle
              : delta > 0
              ? Icons.trending_up
              : Icons.trending_down,
          size: 14,
          color: negligible
              ? AppColors.of(context).blue
              : delta > 0
              ? scheme.error
              : AppColors.of(context).green,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: maxLines,
            style: style?.copyWith(color: scheme.onSurface),
          ),
        ),
      ],
    );
  }
}
