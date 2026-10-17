import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import 'motion.dart';

/// A category's rounded-square tile: its glyph over a tint of its colour.
/// The ledger rows and the review sheet rows lead with it, and so does any
/// row the user acts on. While [selected] the tile fills with the accent and
/// shows a check, the fill easing over and the glyphs swapping with a small
/// pop.
class CategoryTileIcon extends StatelessWidget {
  const CategoryTileIcon({
    super.key,
    required this.category,
    this.size = 40,
    this.selected = false,
    this.icon,
  });

  final TxCategory category;

  /// The tile's side; the glyph is half of it.
  final double size;

  final bool selected;

  /// A glyph in place of the category's, as a linked refund shows.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyphSize = size / 2;
    // One timing for every selection change, so the fill and the icon swap
    // move together.
    final selectMotion = motionDuration(
      context,
      const Duration(milliseconds: 160),
    );
    return AnimatedContainer(
      duration: selectMotion,
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : category.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: AnimatedSwitcher(
        duration: selectMotion,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.6, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        // categoryGlyphColor: the raw dark-kit hue washed out to 1.6 to
        // 2.4:1 over its own tint on light surfaces.
        child: selected
            ? Icon(
                Icons.check,
                key: const ValueKey(true),
                color: scheme.onPrimary,
                size: glyphSize,
              )
            : Icon(
                icon ?? category.icon,
                key: const ValueKey(false),
                color: categoryGlyphColor(context, category.color),
                size: glyphSize,
              ),
      ),
    );
  }
}
