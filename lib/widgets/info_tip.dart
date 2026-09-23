import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import 'motion.dart';

/// The outlined "i" that explains the label next to it. A tap opens an
/// anchored bubble: [title], [message], and — for computed figures — an
/// [example] line worked with the user's own numbers. Tapping outside, the
/// back gesture or "Got it" closes it.
///
/// [example] runs when the bubble opens, so it reads the figures of that
/// moment; returning null (no data yet) leaves the line out. [link] adds a
/// question and a link that closes the bubble and goes somewhere useful.
class InfoTip extends StatelessWidget {
  final String title;
  final String message;
  final String? Function()? example;
  final InfoLink? link;

  const InfoTip({
    super.key,
    required this.title,
    required this.message,
    this.example,
    this.link,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Its own node, with its own tap: otherwise the label merges into the
    // heading beside it and TalkBack cannot reach the tip.
    return Semantics(
      container: true,
      button: true,
      label: 'About $title',
      onTap: () => _open(context),
      excludeSemantics: true,
      // Its own ink surface: the ripple paints on the nearest Material, and
      // inside a text field that one lies beneath the field's fill, so the
      // splash animated hidden behind it.
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          radius: 18,
          onTap: () => _open(context),
          // 32dp target around a 16dp glyph: sits inside a heading row
          // without pushing its height.
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              Icons.info_outline,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final exampleText = example?.call();
    showAnchoredBubble(
      context,
      anchor: anchor,
      content: (ctx) => _TipContent(
        title: title,
        message: message,
        example: exampleText,
        link: link,
        // The link runs from the screen that owns the tip, not from the
        // bubble's own route, which is gone by then.
        host: context,
      ),
    );
  }
}

/// A tooltip's way out: an optional [prompt] question and a [label]ed link.
/// [onTap] receives the context of the screen that shows the tip, after the
/// bubble has closed.
class InfoLink {
  final String? prompt;
  final String label;
  final void Function(BuildContext context) onTap;

  const InfoLink({this.prompt, required this.label, required this.onTap});
}

/// A label followed by its [InfoTip], for heading rows. The label may
/// shrink (ellipsis) but the tip never wraps below it.
class InfoLabel extends StatelessWidget {
  final Widget label;
  final InfoTip tip;

  const InfoLabel({super.key, required this.label, required this.tip});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: label),
      tip,
    ],
  );
}

/// Opens [content] in a card pointing at [anchor] (global coordinates),
/// under it or, without room, above it. Tapping outside or the back gesture
/// closes it; the future completes once it is gone. [content] supplies its
/// own padding.
Future<void> showAnchoredBubble(
  BuildContext context, {
  required Rect anchor,
  required WidgetBuilder content,
  double maxWidth = 340,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: Colors.transparent,
  transitionDuration: motionDuration(
    context,
    const Duration(milliseconds: 150),
  ),
  pageBuilder: (ctx, _, _) =>
      _AnchoredBubble(anchor: anchor, maxWidth: maxWidth, child: content(ctx)),
  transitionBuilder: (ctx, animation, _, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween(begin: 0.96, end: 1.0).animate(curved),
        child: child,
      ),
    );
  },
);

/// The accent "label →" link row, closing the bubble before [InfoLink.onTap]
/// runs from [host] (the screen that opened it).
class InfoLinkRow extends StatelessWidget {
  final InfoLink link;
  final BuildContext host;

  const InfoLinkRow({super.key, required this.link, required this.host});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Divider(height: 1, color: scheme.outlineVariant),
        const SizedBox(height: 8),
        if (link.prompt case final prompt?)
          Text(
            prompt,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            Navigator.pop(context);
            if (host.mounted) link.onTap(host);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '${link.label} →',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accentTextColor(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const _gutter = 16.0;
const _gap = 4.0;
const _arrow = 12.0;

class _TipContent extends StatelessWidget {
  final String title;
  final String message;
  final String? example;
  final InfoLink? link;
  final BuildContext host;

  const _TipContent({
    required this.title,
    required this.message,
    required this.example,
    required this.link,
    required this.host,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.45,
              color: scheme.onSurface,
            ),
          ),
          if (example != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                example!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (link case final link?) InfoLinkRow(link: link, host: host),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                foregroundColor: accentTextColor(context),
              ),
              child: const Text('Got it'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnchoredBubble extends StatelessWidget {
  final Rect anchor;
  final double maxWidth;
  final Widget child;

  const _AnchoredBubble({
    required this.anchor,
    required this.maxWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHigh;
    final border = scheme.outlineVariant;
    // A diamond with borders on two sides; its outer half pokes out of the
    // bubble and its inner half covers the bubble's own border there.
    Widget arrow(double angle) => Transform.rotate(
      angle: angle,
      child: Container(
        width: _arrow,
        height: _arrow,
        decoration: BoxDecoration(
          color: fill,
          border: Border(
            left: BorderSide(color: border),
            top: BorderSide(color: border),
          ),
        ),
      ),
    );
    final card = Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );

    return CustomMultiChildLayout(
      delegate: _BubbleLayout(anchor, MediaQuery.paddingOf(context), maxWidth),
      children: [
        // Scrolls rather than overflows on a short screen; unclipped so
        // the shadow still shows.
        LayoutId(
          id: _Slot.bubble,
          child: SingleChildScrollView(clipBehavior: Clip.none, child: card),
        ),
        // Both arrows are laid out; the delegate parks the unused one off
        // screen (it cannot restyle a child once it knows which side fits).
        LayoutId(id: _Slot.arrowUp, child: arrow(math.pi / 4)),
        LayoutId(id: _Slot.arrowDown, child: arrow(math.pi * 5 / 4)),
      ],
    );
  }
}

enum _Slot { bubble, arrowUp, arrowDown }

/// Places the bubble under the anchor (above it when there is no room
/// below), clamped to the screen gutters, and points the arrow at the
/// anchor's centre.
class _BubbleLayout extends MultiChildLayoutDelegate {
  final Rect anchor;

  /// Status and gesture bars: the bubble stays clear of both.
  final EdgeInsets safe;
  final double maxWidth;
  _BubbleLayout(this.anchor, this.safe, this.maxWidth);

  @override
  void performLayout(Size size) {
    final width = math.min(maxWidth, size.width - 2 * _gutter);
    final bubble = layoutChild(
      _Slot.bubble,
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: size.height - safe.vertical - 2 * _gutter,
      ),
    );
    for (final slot in [_Slot.arrowUp, _Slot.arrowDown]) {
      layoutChild(slot, BoxConstraints.tight(const Size.square(_arrow)));
    }

    final below = anchor.bottom + _gap + _arrow / 2;
    final fitsBelow =
        below + bubble.height <= size.height - safe.bottom - _gutter;
    final top = fitsBelow
        ? below
        : math.max(
            safe.top + _gutter,
            anchor.top - _gap - _arrow / 2 - bubble.height,
          );
    final left = (anchor.center.dx - width / 2).clamp(
      _gutter,
      size.width - _gutter - width,
    );
    positionChild(_Slot.bubble, Offset(left, top));

    final arrowX = anchor.center.dx
        .clamp(left + 16, left + width - 16)
        .toDouble();
    const offscreen = Offset(-100, -100);
    positionChild(
      _Slot.arrowUp,
      fitsBelow ? Offset(arrowX - _arrow / 2, top - _arrow / 2) : offscreen,
    );
    positionChild(
      _Slot.arrowDown,
      fitsBelow
          ? offscreen
          : Offset(arrowX - _arrow / 2, top + bubble.height - _arrow / 2),
    );
  }

  @override
  bool shouldRelayout(_BubbleLayout old) =>
      old.anchor != anchor || old.safe != safe || old.maxWidth != maxWidth;
}
