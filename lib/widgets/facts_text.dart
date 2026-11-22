import 'package:flutter/material.dart';

import '../utils/format.dart';
import 'text_width.dart';

/// Facts on a line that may wrap, joined by " · " as [joinFacts] joins
/// them: each fact keeps its words together and a line breaks only after a
/// dot, so no line starts with a dot or splits "3 days ago". A fact wider
/// than the line keeps its ordinary spaces: held together it would be cut
/// inside a word. One fact alone is shown as it is.
///
/// One [Text], so finders by text still land on it: where every fact fits
/// the line, its text is `joinFacts(facts)`.
class FactsText extends StatelessWidget {
  final List<String> facts;

  /// The first fact's own style, such as a review row's amount in its
  /// money colour. It must not change the text's size.
  final TextStyle? firstStyle;

  /// Cut with an ellipsis after this many lines; null for no limit.
  final int? maxLines;

  const FactsText(this.facts, {super.key, this.firstStyle, this.maxLines});

  @override
  Widget build(BuildContext context) {
    final overflow = maxLines == null ? null : TextOverflow.ellipsis;
    if (facts.length < 2 && firstStyle == null) {
      return Text(facts.join(), maxLines: maxLines, overflow: overflow);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style;
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        bool fits(String words) =>
            measuredTextWidth(words, style, scaler, direction) <=
            constraints.maxWidth;

        // A no-break space, then the dot: the dot after a fact stays on
        // its line, so it is measured with the fact.
        const dot = '\u{00A0}·';
        final held = [
          for (final (i, f) in facts.indexed)
            !f.contains(' ') || fits(i < facts.length - 1 ? '$f$dot' : f)
                ? joinFacts([f])
                : f,
        ];
        final line = held.join('$dot ');
        if (firstStyle == null) {
          return Text(line, maxLines: maxLines, overflow: overflow);
        }
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: held.first, style: firstStyle),
              TextSpan(text: line.substring(held.first.length)),
            ],
          ),
          maxLines: maxLines,
          overflow: overflow,
        );
      },
    );
  }
}
