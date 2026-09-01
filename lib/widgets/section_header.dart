import 'package:flutter/material.dart';

import '../utils/contrast.dart';

/// The app's uppercase micro-header ("YOUR RULES", "BUILT-IN", …) — one
/// widget instead of the six hand-copied TextStyles that had already
/// drifted apart in colour and padding.
class UppercaseSectionHeader extends StatelessWidget {
  final String label;

  /// Defaults to the accent; pass e.g. `onSurfaceVariant` for muted headers.
  final Color? color;
  final EdgeInsetsGeometry padding;

  const UppercaseSectionHeader(
    this.label, {
    super.key,
    this.color,
    this.padding = const EdgeInsets.fromLTRB(20, 20, 20, 6),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        label.toUpperCase(),
        // accentTextColor, not scheme.primary: 11px text needs 4.5:1, and
        // the raw accent measured ~2.5:1 on the light background.
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
          color: color ?? accentTextColor(context),
        ),
      ),
    );
  }
}
