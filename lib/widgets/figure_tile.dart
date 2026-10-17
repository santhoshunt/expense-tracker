import 'package:flutter/material.dart';

/// How many lines each [FigureTile] title below it keeps, for tiles side
/// by side; one when none is set.
class FigureTileTitleLines extends InheritedWidget {
  final int lines;

  const FigureTileTitleLines({
    super.key,
    required this.lines,
    required super.child,
  });

  static int of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FigureTileTitleLines>()
          ?.lines ??
      1;

  @override
  bool updateShouldNotify(FigureTileTitleLines old) => old.lines != lines;
}

/// One figure on a plain surface card: a muted [title], the figure, and an
/// optional muted [note] under it. Shared by the spend history sheet and
/// the weekly digest.
class FigureTile extends StatelessWidget {
  final String title;

  /// The figure; null shows [none] instead.
  final String? value;

  /// The figure's colour; null keeps the default text colour.
  final Color? color;
  final String none;
  final String? note;

  const FigureTile({
    super.key,
    required this.title,
    this.value,
    this.color,
    this.none = '',
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final titleLines = FigureTileTitleLines.of(context);
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final value = this.value;
    final note = this.note;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // In a row of tiles every title keeps the same lines, so the
            // figures under them share one line.
            if (titleLines > 1)
              Stack(
                children: [
                  Visibility(
                    visible: false,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: Text('\n' * (titleLines - 1), style: muted),
                  ),
                  Text(
                    title,
                    style: muted,
                    maxLines: titleLines,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              )
            else
              Text(title, style: muted),
            const SizedBox(height: 4),
            if (value != null)
              // FittedBox, not Flexible: a long figure shrinks rather than
              // breaking mid-number (transaction-tile pattern).
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              )
            else
              Text(none, style: text.bodyMedium),
            if (note != null) ...[
              const SizedBox(height: 2),
              Text(note, style: muted),
            ],
          ],
        ),
      ),
    );
  }
}
