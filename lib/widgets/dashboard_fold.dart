import 'package:flutter/material.dart';

import 'animated_fold.dart';
import 'motion.dart';

/// One Trends or Breakdown section: a heading row that folds its cards
/// away and, while folded, says in one line what they hold ("Swiggy
/// ₹4.2K"), so a long page reads at a glance and opens where wanted.
class DashboardFold extends StatelessWidget {
  final String title;

  /// Shown after the title while folded; null shows the title alone.
  final String? summary;

  /// The section's info tip, beside the title.
  final Widget? tip;
  final bool open;
  final ValueChanged<bool> onChanged;
  final List<Widget> children;

  const DashboardFold({
    super.key,
    required this.title,
    this.summary,
    this.tip,
    required this.open,
    required this.onChanged,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final line = summary;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            // Its own node: an open body's text must not merge into it.
            container: true,
            button: true,
            expanded: open,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onChanged(!open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.titleMedium,
                                ),
                              ),
                              ?tip,
                            ],
                          ),
                          if (!open && line != null)
                            Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0 : 0.5,
                      duration: motionDuration(
                        context,
                        const Duration(milliseconds: 250),
                      ),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_less,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedFold(
            collapsed: !open,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DashboardFoldScope(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Marks a card as sitting inside a [DashboardFold], whose heading already
/// names it: a card with its own heading then drops the repeated title and
/// top gap, keeping its tip and controls.
class DashboardFoldScope extends InheritedWidget {
  const DashboardFoldScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DashboardFoldScope>() != null;

  @override
  bool updateShouldNotify(DashboardFoldScope oldWidget) => false;
}
