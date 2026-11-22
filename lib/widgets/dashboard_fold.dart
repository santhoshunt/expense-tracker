import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'animated_fold.dart';
import 'grouped_surface.dart';
import 'info_tip.dart';
import 'motion.dart';

/// One Trends or Breakdown section: a heading row that folds its cards
/// away and, while folded, says in a line or two what they hold ("Swiggy
/// ₹4.2K"), so a long page reads at a glance and opens where wanted.
///
/// Folded sections are rows of one card shared with their folded neighbours
/// ([first] and [last] round its ends), the summary under the title.
/// An open section is a card of its own (both set), its cards lying flat
/// inside it, with [gapAbove] over it; the run after it starts with that
/// gap too.
///
/// The cards are built only while the section shows them: open, opening or
/// closing. A folded section at rest builds none of them.
class DashboardFold extends StatefulWidget {
  final String title;

  /// Shown under the title while folded, up to two lines; null shows the
  /// title alone.
  final String? summary;

  /// The section's info tip, beside the title, only while open: the folded
  /// rows stay quiet.
  final Widget? tip;
  final bool open;
  final ValueChanged<bool> onChanged;

  /// The section's cards, called only when they are to be built.
  final List<Widget> Function() body;

  /// What the cards' kept state belongs to, such as the month shown. A new
  /// value forgets that state ([DashboardFoldScope.memory]), as a new month
  /// used to rebuild the cards afresh.
  final Object? memoryFor;
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
    required this.body,
    this.memoryFor,
    this.first = true,
    this.last = true,
    this.gapAbove = AppSpace.gap + 6,
  });

  @override
  State<DashboardFold> createState() => _DashboardFoldState();
}

class _DashboardFoldState extends State<DashboardFold> {
  /// What the section's cards keep while it is folded ([DashboardFoldScope]).
  final Map<Object, Object?> _memory = {};

  @override
  void didUpdateWidget(DashboardFold old) {
    super.didUpdateWidget(old);
    if (widget.memoryFor != old.memoryFor) _memory.clear();
  }

  /// The cards' theme and the theme it was made from. Made once per parent
  /// theme: a new one on every build never equalled the last, so everything
  /// under the fold that reads the theme rebuilt with each dashboard build.
  ThemeData? _parentTheme;
  ThemeData? _cardsTheme;

  ThemeData _themeFor(BuildContext context) {
    final parent = Theme.of(context);
    if (!identical(parent, _parentTheme) || _cardsTheme == null) {
      final c = AppColors.of(context);
      _parentTheme = parent;
      _cardsTheme = parent.copyWith(
        cardTheme: parent.cardTheme.copyWith(
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
      );
    }
    return _cardsTheme!;
  }

  @override
  Widget build(BuildContext context) => _grouped(context);

  Widget _chevron(BuildContext context, double size) => AnimatedRotation(
    turns: widget.open ? 0 : 0.5,
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
    final DashboardFold(
      :title,
      :tip,
      :open,
      :onChanged,
      :first,
      :last,
      :gapAbove,
    ) = widget;
    final line = widget.summary;
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
                  // 2dp above and below: an open heading's 48dp tip keeps the
                  // row at 52dp.
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.card,
                      2,
                      AppSpace.card - 4,
                      2,
                    ),
                    child: Row(
                      children: [
                        // The title on its line, the summary under it: each
                        // gets the row's whole width.
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
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
                                  // A near miss on the "i" would fold the
                                  // section: 48dp here.
                                  if (open && tip != null)
                                    InfoTipTarget(size: 48, child: tip),
                                ],
                              ),
                              if (!open && line != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    line,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
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
            AnimatedFold.lazy(
              collapsed: !open,
              builder: (context) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                // The row is the card: the section's own cards lie flat in
                // it, with no second fill, outline or margin.
                child: Theme(
                  data: _themeFor(context),
                  child: DashboardFoldScope(
                    memory: _memory,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: widget.body(),
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
///
/// [memory] holds what a card must keep while its section is folded, such
/// as a list's Show all: a folded section's cards are not built, so their
/// own state goes with each fold. It lasts as long as the fold, which the
/// page disposes as it disposed those cards before.
class DashboardFoldScope extends InheritedWidget {
  final Map<Object, Object?>? memory;

  const DashboardFoldScope({super.key, this.memory, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DashboardFoldScope>() != null;

  /// The enclosing fold's [memory]; null outside a fold.
  static Map<Object, Object?>? memoryOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DashboardFoldScope>()?.memory;

  @override
  bool updateShouldNotify(DashboardFoldScope oldWidget) => false;
}
