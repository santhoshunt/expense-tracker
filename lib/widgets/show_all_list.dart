import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'animated_fold.dart';
import 'dashboard_fold.dart';

/// Rows a capped list shows before "Show all".
const int kRowsShown = 5;

/// A card's rows capped at [shown], with a "Show all N [noun]" toggle that
/// folds the rest open. The folded rows are built only while they show
/// ([AnimatedFold.lazy]). Short lists get no toggle.
class ShowAllList extends StatefulWidget {
  final List<Widget> rows;

  /// Plural, lower case: "categories", "tags".
  final String noun;
  final int shown;

  const ShowAllList({
    super.key,
    required this.rows,
    required this.noun,
    this.shown = kRowsShown,
  });

  @override
  State<ShowAllList> createState() => _ShowAllListState();
}

class _ShowAllListState extends State<ShowAllList> {
  /// Where a dashboard fold keeps Show all while it is folded: the list is
  /// not built then, and would come back showing five.
  (Type, String) get _slot => (ShowAllList, widget.noun);

  late bool _expanded = DashboardFoldScope.memoryOf(context)?[_slot] == true;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    DashboardFoldScope.memoryOf(context)?[_slot] = _expanded;
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    if (rows.length <= widget.shown) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...rows.take(widget.shown),
        AnimatedFold.lazy(
          collapsed: !_expanded,
          builder: (_) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows.skip(widget.shown).toList(),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            // Flush with the rows above it.
            style: flushTextButtonStyle,
            onPressed: _toggle,
            child: Text(
              _expanded
                  ? 'Show less'
                  : 'Show all ${rows.length} ${widget.noun}',
            ),
          ),
        ),
      ],
    );
  }
}
