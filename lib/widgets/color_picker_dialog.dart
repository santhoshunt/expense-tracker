import 'package:flutter/material.dart';

/// HSV colour picker dialog with a live preview. Returns the chosen colour,
/// or null when cancelled.
Future<Color?> showColorPickerDialog(
  BuildContext context, {
  required Color initial,
  String title = 'Pick a colour',
}) {
  var hsv = HSVColor.fromColor(initial);

  return showDialog<Color>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final color = hsv.toColor();

        Widget slider({
          required String label,
          required String name,
          required double value,
          required double max,
          required ValueChanged<double> onChanged,
        }) => Row(
          children: [
            SizedBox(
              width: 28,
              // FittedBox: the single-letter label clipped at large scale.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(label, style: Theme.of(ctx).textTheme.bodySmall),
              ),
            ),
            Expanded(
              // Named for TalkBack — three bare percentages were
              // indistinguishable.
              child: Semantics(
                label: name,
                child: Slider(
                  value: value,
                  max: max,
                  onChanged: (v) => setState(() => onChanged(v)),
                ),
              ),
            ),
          ],
        );

        // The accent is used as TEXT (34px balance headline, per-account
        // figures) on both light and dark surfaces — an unconstrained pick
        // can render the app unreadable with no way back into this dialog's
        // own state. Block the extremes.
        final luminance = color.computeLuminance();
        final tooDark = luminance < 0.05;
        final tooLight = luminance > 0.62;

        return AlertDialog(
          title: Text(title),
          // Preview + three sliders overflow in landscape.
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(ctx).colorScheme.outlineVariant,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              slider(
                label: 'H',
                name: 'Hue',
                value: hsv.hue,
                max: 360,
                onChanged: (v) => hsv = hsv.withHue(v),
              ),
              slider(
                label: 'S',
                name: 'Saturation',
                value: hsv.saturation,
                max: 1,
                onChanged: (v) => hsv = hsv.withSaturation(v),
              ),
              slider(
                label: 'B',
                name: 'Brightness',
                value: hsv.value,
                max: 1,
                onChanged: (v) => hsv = hsv.withValue(v),
              ),
              if (tooDark || tooLight) ...[
                const SizedBox(height: 8),
                Text(
                  tooDark
                      ? 'Too dark to read as text — raise the brightness.'
                      : 'Too light to read as text — lower the brightness '
                            'or add saturation.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: tooDark || tooLight
                  ? null
                  : () => Navigator.pop(ctx, color),
              child: const Text('Select'),
            ),
          ],
        );
      },
    ),
  );
}
