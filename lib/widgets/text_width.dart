import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

/// The width of [text] laid out on one line in [style], as a `TextPainter`
/// measures it. Measured once per text, style, text scale and direction:
/// rows that measure the same strings on every build (a review row's
/// facts, a ledger row's " · new") then cost a map lookup, not a paragraph
/// layout.
///
/// The store is dropped whole once it passes [_limit] entries, so it cannot
/// grow without end, and when the system fonts change, which changes every
/// width in it.
double measuredTextWidth(
  String text,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
) {
  final key = (text, style, scaler, direction);
  final known = _widths[key];
  if (known != null) return known;
  if (!_listening) {
    PaintingBinding.instance.systemFonts.addListener(_widths.clear);
    _listening = true;
  }
  if (_widths.length >= _limit) _widths.clear();
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return _widths[key] = width;
}

const _limit = 400;
final _widths = <(String, TextStyle, TextScaler, TextDirection), double>{};
var _listening = false;

/// How many widths are stored now.
@visibleForTesting
int get measuredTextWidthEntries => _widths.length;
