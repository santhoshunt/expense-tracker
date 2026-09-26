import 'package:flutter/material.dart';

import 'animated_fold.dart';

/// Rows a capped list shows before "Show all".
const int kRowsShown = 5;

/// A card's rows capped at [shown], with a "Show all N [noun]" toggle that
/// folds the rest open. The folded rows stay mounted at zero height, as in
/// [AnimatedFold]. Short lists get no toggle.
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
  bool _expanded = false;

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
        AnimatedFold(
          collapsed: !_expanded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows.skip(widget.shown).toList(),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
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
