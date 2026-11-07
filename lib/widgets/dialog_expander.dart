import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import 'animated_fold.dart';
import 'motion.dart';

/// A closed row in a dialog that opens onto options most entries never
/// need: the category dialog's Transfer options, the rule dialog's other
/// direction. The folded [child] stays mounted at zero height.
///
/// With [value], it is an editor sheet's folded group: the closed line
/// shows the title and what is set inside ("Categories · Food & Dining").
/// With [keepClosed] false, a closed group builds nothing, so its fields
/// are neither found nor validated until it opens.
class DialogExpander extends StatelessWidget {
  final String title;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  /// The folded line's value, shown after the title.
  final String? value;

  /// Keeps the closed [child] mounted at zero height (the default).
  final bool keepClosed;

  const DialogExpander({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.child,
    this.value,
    this.keepClosed = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final duration = motionDuration(context, AnimatedFold.duration);
    final value = this.value;
    final chevron = AnimatedRotation(
      turns: open ? 0.5 : 0,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: Icon(Icons.expand_more, size: 20, color: scheme.onSurfaceVariant),
    );
    final Widget label;
    if (value == null) {
      // The accent as text: lifted on the light theme so it stays readable
      // on a white dialog.
      label = Text(
        title,
        style: text.labelLarge?.copyWith(color: accentTextColor(context)),
      );
    } else {
      final titleStyle = text.bodyLarge?.copyWith(color: scheme.onSurface);
      final titleText = Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      );
      final valueStyle = text.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      );
      // Large text (1.3x, Android's Large, and up): the value drops under
      // the title, so neither is cut to a few letters or mid-word.
      label = MediaQuery.textScalerOf(context).scale(1) >= 1.3
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleText,
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: valueStyle,
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, box) {
                // The title takes what the value leaves. The value gets
                // 45% of the row, or more when the title fits on one line
                // in the rest, so a short value never halves the title.
                final painter = TextPainter(
                  text: TextSpan(text: title, style: titleStyle),
                  textScaler: MediaQuery.textScalerOf(context),
                  textDirection: Directionality.of(context),
                  maxLines: 1,
                )..layout();
                // Rounded up, plus 1dp, so a title given exactly its own
                // width does not wrap on a rounding error.
                final titleWidth = painter.width.ceilToDouble() + 1;
                painter.dispose();
                final cap = math.max(
                  box.maxWidth * 0.45,
                  box.maxWidth - titleWidth - 12,
                );
                return Row(
                  children: [
                    Expanded(child: titleText),
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: math.max(0, cap)),
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: valueStyle,
                      ),
                    ),
                  ],
                );
              },
            );
    }
    Widget header = Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onToggle,
        // 48dp, Material's minimum tap target.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          // The fields' own 16dp text inset, so the title lines up with
          // their labels and the tap highlight frames it.
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: value == null ? 0 : 8,
            ),
            child: Row(
              children: [
                Expanded(child: label),
                if (value != null) const SizedBox(width: 8),
                chevron,
              ],
            ),
          ),
        ),
      ),
    );
    // Title, value, button and state read as one node.
    if (value != null) header = MergeSemantics(child: header);
    // A gap under the header, so a field's floating label below it is
    // never tucked under the header's highlight.
    final body = Padding(padding: const EdgeInsets.only(top: 12), child: child);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (keepClosed)
          AnimatedFold(collapsed: !open, child: body)
        else
          AnimatedSize(
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open ? body : const SizedBox(width: double.infinity),
          ),
      ],
    );
  }
}
