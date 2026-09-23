import 'package:flutter/material.dart';

import 'info_tip.dart';

/// Popups for a tapped chart part open this narrow.
const double kChartPopupWidth = 260;

/// The figures of one tapped chart part (a donut slice, a month's bars),
/// shown in [showAnchoredBubble]: a [title] (with a colour [swatch] when the
/// part has one), an optional big [headline] figure, label/value [rows], a
/// muted [footnote], and an optional [link] out.
class ChartPopup extends StatelessWidget {
  final String title;
  final Color? swatch;
  final String? headline;
  final List<(String, String)> rows;
  final String? footnote;
  final Color? footnoteColor;
  final InfoLink? link;

  /// The screen that opened the popup; [link] runs from it.
  final BuildContext host;

  const ChartPopup({
    super.key,
    required this.title,
    this.swatch,
    this.headline,
    this.rows = const [],
    this.footnote,
    this.footnoteColor,
    this.link,
    required this.host,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 12, 14, link == null ? 12 : 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (swatch != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: swatch,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (headline != null) ...[
            const SizedBox(height: 4),
            Text(
              headline!,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ],
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ),
                  Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          if (footnote != null) ...[
            const SizedBox(height: 6),
            Text(
              footnote!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: footnoteColor ?? muted,
                fontWeight: footnoteColor == null ? null : FontWeight.w600,
              ),
            ),
          ],
          if (link case final link?) InfoLinkRow(link: link, host: host),
        ],
      ),
    );
  }
}

/// A small square around [local] in [context]'s box, in global coordinates:
/// where a chart popup points.
Rect chartAnchor(BuildContext context, Offset local) {
  final box = context.findRenderObject()! as RenderBox;
  return Rect.fromCenter(
    center: box.localToGlobal(local),
    width: 16,
    height: 16,
  );
}
