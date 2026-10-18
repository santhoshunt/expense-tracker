import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import 'animated_fold.dart';
import 'motion.dart';

/// A closed row in a dialog that opens onto options most entries never
/// need: the category dialog's Transfer options, the rule dialog's other
/// direction. The folded [child] stays mounted at zero height.
class DialogExpander extends StatelessWidget {
  final String title;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  const DialogExpander({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      // The accent as text: lifted on the light theme so it
                      // stays readable on a white dialog.
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: accentTextColor(context),
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: motionDuration(context, AnimatedFold.duration),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // A gap under the header, so a field's floating label below it is
        // never tucked under the header's highlight.
        AnimatedFold(
          collapsed: !open,
          child: Padding(padding: const EdgeInsets.only(top: 12), child: child),
        ),
      ],
    );
  }
}
