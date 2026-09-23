import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colour picker sheet: a shade square (saturation across, brightness
/// down) under a hue slider, a hex field that can be typed or pasted, and a
/// row of saved colours. Returns the chosen colour, or null when dismissed.
///
/// Any colour can be chosen. One that is hard to read as text (the accent
/// is used for headline figures) gets a warning line, never a disabled
/// button.
Future<Color?> showColorPickerDialog(
  BuildContext context, {
  required Color initial,
  String title = 'Pick a colour',
}) => showModalBottomSheet<Color>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  // Only the handle drags the sheet: a vertical drag on the shade square
  // must change brightness, not pull the sheet down.
  enableDrag: false,
  builder: (_) => _ColorPickerSheet(initial: initial, title: title),
);

/// Saved colours are shared by every picker (accent and categories) and
/// kept on this device.
const _kSavedColors = 'saved_colours_v1';
const _maxSaved = 12;

class _ColorPickerSheet extends StatefulWidget {
  final Color initial;
  final String title;

  const _ColorPickerSheet({required this.initial, required this.title});

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial.withValues(alpha: 1));
  late final _hex = TextEditingController(text: _hexOf(_hsv.toColor()));
  final _hexFocus = FocusNode();
  List<Color> _saved = const [];

  @override
  void initState() {
    super.initState();
    _loadSaved();
    // Typing leaves the field showing what was typed; once it lets go, it
    // shows the colour actually chosen (a drag may have changed it).
    _hexFocus.addListener(() {
      if (!_hexFocus.hasFocus) _hex.text = _hexOf(_hsv.toColor());
    });
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kSavedColors) ?? const [];
      final saved = [
        for (final s in raw)
          if (int.tryParse(s, radix: 16) case final v?) Color(0xFF000000 | v),
      ];
      if (mounted) setState(() => _saved = saved);
    } catch (_) {
      // No saved colours is a fine fallback.
    }
  }

  Future<void> _storeSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kSavedColors, [
        for (final c in _saved) _hexOf(c),
      ]);
    } catch (_) {}
  }

  /// Sets the colour from a drag or a swatch; the hex field follows unless
  /// it is being typed in.
  void _set(HSVColor hsv) {
    setState(() => _hsv = hsv);
    if (!_hexFocus.hasFocus) _hex.text = _hexOf(hsv.toColor());
  }

  /// A drag on the square or slider ends any typing, so the field follows.
  void _drag(HSVColor hsv) {
    if (_hexFocus.hasFocus) _hexFocus.unfocus();
    _set(hsv);
  }

  void _pick(Color c) {
    final hsv = HSVColor.fromColor(c);
    // A grey has no hue of its own: keep the slider where it was.
    _set(hsv.saturation == 0 ? hsv.withHue(_hsv.hue) : hsv);
    _hex.text = _hexOf(c);
  }

  void _onHexChanged(String text) {
    final clean = text.replaceAll('#', '').trim();
    if (clean.length != 6) return;
    final v = int.tryParse(clean, radix: 16);
    if (v == null) return;
    final hsv = HSVColor.fromColor(Color(0xFF000000 | v));
    setState(() => _hsv = hsv.saturation == 0 ? hsv.withHue(_hsv.hue) : hsv);
  }

  void _save() {
    final c = _hsv.toColor();
    setState(() {
      _saved = [
        c,
        for (final s in _saved)
          if (s.toARGB32() != c.toARGB32()) s,
      ].take(_maxSaved).toList();
    });
    _storeSaved();
  }

  void _unsave(Color c) {
    setState(() {
      _saved = [
        for (final s in _saved)
          if (s.toARGB32() != c.toARGB32()) s,
      ];
    });
    _storeSaved();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _hsv.toColor();
    // The accent is drawn as text on both light and dark surfaces; the
    // extremes are worth a word, but the choice stays the user's.
    final luminance = color.computeLuminance();
    final warning = luminance < 0.05
        ? 'Very dark: figures in this colour may be hard to read on the '
              'dark theme.'
        : luminance > 0.62
        ? 'Very light: figures in this colour may be hard to read on the '
              'light theme.'
        : null;
    final current = color.toARGB32();

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            _ShadeSquare(hsv: _hsv, onChanged: _drag),
            const SizedBox(height: 16),
            _HueSlider(hue: _hsv.hue, onChanged: (h) => _drag(_hsv.withHue(h))),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.outlineVariant, width: 2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    focusNode: _hexFocus,
                    decoration: const InputDecoration(
                      labelText: 'Hex',
                      prefixText: '#',
                      counterText: '',
                    ),
                    maxLength: 7,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F#]')),
                    ],
                    onChanged: _onHexChanged,
                    onSubmitted: (_) => _hex.text = _hexOf(_hsv.toColor()),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy hex',
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: '#${_hexOf(color)}'),
                  ),
                ),
              ],
            ),
            if (warning != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      warning,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Saved', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_saved.isEmpty)
              Text(
                'Add keeps this colour here for next time.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in _saved)
                    _SavedSwatch(
                      color: c,
                      selected: c.toARGB32() == current,
                      onTap: () => _pick(c),
                      onRemove: () => _unsave(c),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Long-press a saved colour to remove it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, color),
                  child: const Text('Select'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Saturation left to right, brightness top to bottom, in the current hue.
class _ShadeSquare extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  const _ShadeSquare({required this.hsv, required this.onChanged});

  String _describe(HSVColor c) =>
      'saturation ${(c.saturation * 100).round()}%, brightness '
      '${(c.value * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final up = hsv.withValue(math.min(1, hsv.value + 0.05));
    final down = hsv.withValue(math.max(0, hsv.value - 0.05));
    return Semantics(
      slider: true,
      label: 'Shade',
      value: _describe(hsv),
      increasedValue: _describe(up),
      decreasedValue: _describe(down),
      // Steps brightness, the axis that matters most for readability.
      onIncrease: () => onChanged(up),
      onDecrease: () => onChanged(down),
      child: SizedBox(
        height: 200,
        child: LayoutBuilder(
          builder: (context, box) {
            void at(Offset p) => onChanged(
              hsv
                  .withSaturation((p.dx / box.maxWidth).clamp(0.0, 1.0))
                  .withValue(1 - (p.dy / box.maxHeight).clamp(0.0, 1.0)),
            );
            return _Drag(
              onPosition: at,
              child: CustomPaint(
                size: Size.infinite,
                painter: _ShadePainter(hsv),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ShadePainter extends CustomPainter {
  final HSVColor hsv;

  _ShadePainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    canvas.save();
    canvas.clipRRect(rrect);
    final pure = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, pure],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    canvas.restore();
    final at = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      at,
      10,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(
      at,
      10,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_ShadePainter old) => old.hsv != hsv;
}

class _HueSlider extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HueSlider({required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      label: 'Hue',
      value: '${hue.round()} degrees',
      increasedValue: '${((hue + 5) % 360).round()} degrees',
      decreasedValue: '${((hue - 5) % 360).round()} degrees',
      onIncrease: () => onChanged((hue + 5) % 360),
      onDecrease: () => onChanged((hue - 5) % 360),
      child: SizedBox(
        height: 32,
        child: LayoutBuilder(
          builder: (context, box) {
            void at(Offset p) =>
                onChanged((p.dx / box.maxWidth).clamp(0.0, 1.0) * 359.9);
            return _Drag(
              onPosition: at,
              child: CustomPaint(
                size: Size.infinite,
                painter: _HuePainter(hue),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  final double hue;

  _HuePainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    const track = 12.0;
    final rect = Rect.fromLTWH(0, (size.height - track) / 2, size.width, track);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(track / 2)),
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var h = 0; h <= 360; h += 60)
              HSVColor.fromAHSV(1, h % 360, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    final at = Offset(hue / 360 * size.width, size.height / 2);
    canvas.drawCircle(
      at,
      12,
      Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
    canvas.drawCircle(
      at,
      12,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}

class _SavedSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _SavedSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Saved colour #${_ColorPickerSheetState._hexOf(color)}',
      onLongPressHint: 'remove',
      child: InkResponse(
        onTap: onTap,
        onLongPress: onRemove,
        radius: 22,
        child: Container(
          width: 34,
          height: 34,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

/// Claims a drag the moment the finger lands, so a vertical drag moves the
/// colour instead of losing out to the sheet's scrolling. Hidden from
/// TalkBack, which gets the adjust actions on the Semantics around it: a
/// scroll gesture there used to snap the colour to the middle.
class _Drag extends StatelessWidget {
  final ValueChanged<Offset> onPosition;
  final Widget child;

  const _Drag({required this.onPosition, required this.child});

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    gestures: {
      _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
        _EagerPan.new,
        (r) => r
          ..onDown = ((d) => onPosition(d.localPosition))
          ..onUpdate = ((d) => onPosition(d.localPosition)),
      ),
    },
    child: child,
  );
}

class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
