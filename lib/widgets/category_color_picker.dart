import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../utils/contrast.dart';
import '../utils/figma_palette.dart';
import 'color_picker_dialog.dart';

/// Human name of a category colour: "None", "Teal", "Iris, light",
/// "Rose, deep", or "Custom" for anything off the palette.
String categoryColorName(Color c) {
  if (c == kNoCategoryColor) return 'None';
  final i = kCategoryColorChoices.indexOf(c);
  if (i < 0) return 'Custom';
  final hue = kCategoryHueNames[i % kCategoryHueNames.length];
  return switch (i ~/ kCategoryHueNames.length) {
    0 => '$hue, light',
    1 => hue,
    _ => '$hue, deep',
  };
}

/// Colour picker for categories and groups: None and Custom on top, then
/// the palette as hue columns in light / base / deep rows. The label names
/// the current pick.
class CategoryColorPicker extends StatelessWidget {
  final Color value;
  final ValueChanged<Color> onChanged;

  const CategoryColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCustom =
        value != kNoCategoryColor && !kCategoryColorChoices.contains(value);
    final columns = kCategoryHueNames.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Colour · ${categoryColorName(value)}',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _Swatch(
              size: 36,
              label: 'None',
              selected: value == kNoCategoryColor,
              onTap: () => onChanged(kNoCategoryColor),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  kNoCategoryColor.withValues(alpha: 0.15),
                  scheme.surface,
                ),
                shape: BoxShape.circle,
              ),
              icon: Icons.format_color_reset_outlined,
              iconColor: kNoCategoryColor,
            ),
            const SizedBox(width: 12),
            _Swatch(
              size: 36,
              label: 'Custom colour',
              selected: isCustom,
              onTap: () async {
                final c = await showColorPickerDialog(
                  context,
                  initial: isCustom ? value : FigmaPalette.primary,
                  title: 'Category colour',
                );
                if (c != null) onChanged(c);
              },
              decoration: isCustom
                  ? BoxDecoration(color: value, shape: BoxShape.circle)
                  : const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(colors: _rainbow),
                    ),
              icon: isCustom ? null : Icons.colorize,
              iconColor: Colors.white,
              checkColor: isCustom ? onSwatch(value) : null,
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Fixed cells, scaled down on narrow dialogs. Not a LayoutBuilder:
        // AlertDialog sizes its content with IntrinsicWidth, which a
        // LayoutBuilder cannot answer.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Column(
            children: [
              for (var row = 0; row < 3; row++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var col = 0; col < columns; col++)
                      _cell(kCategoryColorChoices[row * columns + col]),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(Color c) => SizedBox(
    width: 32,
    height: 32,
    child: Center(
      child: _Swatch(
        size: 26,
        label: categoryColorName(c),
        selected: c == value,
        onTap: () => onChanged(c),
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        checkColor: onSwatch(c),
      ),
    ),
  );
}

const _rainbow = [
  Color(0xFFF2635B),
  Color(0xFFF5C04E),
  Color(0xFF50D1AA),
  Color(0xFF65B0F6),
  Color(0xFF9290FE),
  Color(0xFFFF7CA3),
  Color(0xFFF2635B),
];

/// One round swatch: its [decoration] fill, an optional [icon], and when
/// selected a ring plus a check in [checkColor] (or [iconColor]).
class _Swatch extends StatelessWidget {
  final double size;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final BoxDecoration decoration;
  final IconData? icon;
  final Color? iconColor;
  final Color? checkColor;

  const _Swatch({
    required this.size,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.decoration,
    this.icon,
    this.iconColor,
    this.checkColor,
  });

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.onSurface;
    final glyph = selected ? Icons.check : icon;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: decoration.copyWith(
              border: Border.all(
                color: selected ? ring : Colors.transparent,
                width: 2,
              ),
            ),
            child: glyph == null
                ? null
                : Icon(
                    glyph,
                    size: size * 0.5,
                    color: (selected ? checkColor : null) ?? iconColor,
                  ),
          ),
        ),
      ),
    );
  }
}
