import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../utils/contrast.dart';
import 'color_picker_dialog.dart';

/// Human name of a palette colour: [noneLabel] for [none], "Teal",
/// "Iris, light", "Rose, deep", or "Custom" for anything off the palette.
String hueColorName(
  Color c, {
  Color none = kNoCategoryColor,
  String noneLabel = 'None',
}) {
  if (c == none) return noneLabel;
  final i = kCategoryColorChoices.indexOf(c);
  if (i < 0) return 'Custom';
  final hue = kCategoryHueNames[i % kCategoryHueNames.length];
  return switch (i ~/ kCategoryHueNames.length) {
    0 => '$hue, light',
    1 => hue,
    _ => '$hue, deep',
  };
}

/// Colour picker over [kCategoryColorChoices]: a "none" choice and Custom on
/// top, then the palette as hue columns in light / base / deep rows. The
/// label names the current pick.
///
/// Categories use the defaults: "None" is the neutral grey chip. The accent
/// setting passes its theme's own accent as [none], labelled "Theme".
class HueColorPicker extends StatelessWidget {
  final Color value;
  final ValueChanged<Color> onChanged;
  final String title;
  final Color none;
  final String noneLabel;

  /// True draws [none] as the neutral chip it renders as on a category;
  /// false draws it filled, like a palette swatch.
  final bool noneIsNeutral;
  final String customTitle;

  /// Grid cell size; the grid scales down (never up) to fit its width.
  final double cell;

  const HueColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.title = 'Colour',
    this.none = kNoCategoryColor,
    this.noneLabel = 'None',
    this.noneIsNeutral = true,
    this.customTitle = 'Category colour',
    this.cell = 32,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNone = value == none;
    final isCustom = !isNone && !kCategoryColorChoices.contains(value);
    final columns = kCategoryHueNames.length;
    String name(Color c) => hueColorName(c, none: none, noneLabel: noneLabel);

    Widget swatch(Color c) => SizedBox(
      width: cell,
      height: cell,
      child: Center(
        child: _Swatch(
          size: cell - 6,
          // Always the hue's own name, even when it equals [none].
          label: hueColorName(c),
          // When the none choice is itself a palette colour (a theme accent
          // that is Coral), only the none swatch shows as selected.
          selected: !isNone && c == value,
          onTap: () => onChanged(c),
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          checkColor: onSwatch(c),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$title · ${name(value)}',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _Swatch(
              size: 36,
              label: noneLabel,
              selected: isNone,
              onTap: () => onChanged(none),
              decoration: BoxDecoration(
                color: noneIsNeutral
                    ? Color.alphaBlend(
                        none.withValues(alpha: 0.15),
                        scheme.surface,
                      )
                    : none,
                shape: BoxShape.circle,
              ),
              icon: noneIsNeutral
                  ? Icons.format_color_reset_outlined
                  : Icons.palette_outlined,
              iconColor: noneIsNeutral ? none : onSwatch(none),
              checkColor: noneIsNeutral ? none : onSwatch(none),
            ),
            const SizedBox(width: 12),
            _Swatch(
              size: 36,
              label: 'Custom colour',
              selected: isCustom,
              onTap: () async {
                final c = await showColorPickerDialog(
                  context,
                  initial: isCustom ? value : none,
                  title: customTitle,
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
        // Fixed cells, scaled down on narrow widths. Not a LayoutBuilder:
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
                      swatch(kCategoryColorChoices[row * columns + col]),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
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
