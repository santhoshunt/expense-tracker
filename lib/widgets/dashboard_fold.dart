import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'animated_fold.dart';
import 'grouped_surface.dart';
import 'motion.dart';

/// One Trends or Breakdown section: a heading row that folds its cards
/// away and, while folded, says in one line what they hold ("Swiggy
/// ₹4.2K"), so a long page reads at a glance and opens where wanted.
///
/// Folded sections are rows of one card shared with their folded neighbours
/// ([first] and [last] round its ends), the summary at the heading's right.
/// An open section is a card of its own (both set), its cards lying flat
/// inside it, with [gapAbove] over it; the run after it starts with that
/// gap too.
class DashboardFold extends StatelessWidget {
  final String title;

  /// Shown at the heading's right while folded; null shows the title alone.
  final String? summary;

  /// The section's info tip, beside the title, only while open: the folded
  /// rows stay quiet.
  final Widget? tip;
  final bool open;
  final ValueChanged<bool> onChanged;
  final List<Widget> children;
  final bool first;
  final bool last;

  /// The space above a [first] row: the page's gap at the top of the page,
  /// [AppSpace.gap] between one card and the next.
  final double gapAbove;

  const DashboardFold({
    super.key,
    required this.title,
    this.summary,
    this.tip,
    required this.open,
    required this.onChanged,
    required this.children,
    this.first = true,
    this.last = true,
    this.gapAbove = AppSpace.gap + 6,
  });

  @override
  Widget build(BuildContext context) => _grouped(context);

  Widget _chevron(BuildContext context, double size) => AnimatedRotation(
    turns: open ? 0 : 0.5,
    duration: motionDuration(context, const Duration(milliseconds: 250)),
    curve: Curves.easeOutCubic,
    child: Icon(
      Icons.expand_less,
      size: size,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  Widget _grouped(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final line = summary;
    final c = AppColors.of(context);
    return Padding(
      // A card's first row keeps its gap above it.
      padding: EdgeInsets.only(top: first ? gapAbove : 0),
      child: GroupedSurface(
        first: first,
        last: last,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              // Its own node: an open body's text must not merge into it.
              container: true,
              button: true,
              expanded: open,
              child: InkWell(
                onTap: () => onChanged(!open),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.card,
                      6,
                      AppSpace.card - 4,
                      6,
                    ),
                    child: Row(
                      children: [
                        // Title left, summary right: each may take up to
                        // half and the rest of the row falls between them,
                        // so a short title leaves the summary its room.
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (open) ?tip,
                                  ],
                                ),
                              ),
                              if (!open && line != null) ...[
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    line,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: text.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        _chevron(context, 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            AnimatedFold(
              collapsed: !open,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                // The row is the card: the section's own cards lie flat in
                // it, with no second fill, outline or margin.
                child: Theme(
                  data: Theme.of(context).copyWith(
                    cardTheme: Theme.of(context).cardTheme.copyWith(
                      color: Colors.transparent,
                      margin: EdgeInsets.zero,
                      shape: const RoundedRectangleBorder(),
                    ),
                    extensions: [
                      AppColors(
                        green: c.green,
                        orange: c.orange,
                        blue: c.blue,
                        purple: c.purple,
                        cardFill: Colors.transparent,
                      ),
                    ],
                  ),
                  child: DashboardFoldScope(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
