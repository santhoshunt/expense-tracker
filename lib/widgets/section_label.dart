import 'package:flutter/material.dart';

import 'info_tip.dart';

/// A page section's name, small and muted, outside its card: one heading
/// style for the Overview's sections. With a [tip] the name is a
/// [TipTitle].
///
/// The name stays a plain [Text], so finders by text still land on it.
class SectionLabel extends StatelessWidget {
  final String text;
  final InfoTip? tip;

  const SectionLabel(this.text, {super.key, this.tip});

  /// The label's text style, for a header that builds its own row (the
  /// Upcoming fold) to match.
  static TextStyle? style(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      );

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style(context),
    );
    final tip = this.tip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Flexible(
            child: tip == null ? label : TipTitle(label: label, tip: tip),
          ),
        ],
      ),
    );
  }
}
