// Regenerates all launcher-icon artwork:
//   - Default icon (assets/icon/icon.png + icon_foreground.png) from the
//     provided artwork at "suggested logo/logo.png" (do NOT redraw the mark —
//     Sandy supplied this file specifically). Applied via flutter_launcher_icons.
//   - Alternate icons (swoosh / classic / midnight) written straight into
//     android res mipmaps; they back the activity-aliases used by the
//     in-app icon switcher.
//   - 256px previews for the Settings UI under assets/icon_previews/.
//
// Run with: flutter test tool/generate_icons_test.dart
// then:     dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = 1024.0;
const _sourcePath = 'suggested logo/logo.png';
const _previewDir = 'assets/icon_previews';
const _mipmapDir = 'android/app/src/main/res/mipmap-xxxhdpi';

// ── Shared helpers ───────────────────────────────────────────────────────────

Future<void> _loadFont() async {
  final data = File('assets/fonts/NotoSans-Bold.ttf').readAsBytesSync();
  final loader = FontLoader('NotoSansBold')
    ..addFont(Future.value(ByteData.view(data.buffer)));
  await loader.load();
}

Future<ui.Image> _render(void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  return recorder.endRecording().toImage(1024, 1024);
}

Future<void> _writeImage(ui.Image img, String path, {int? size}) async {
  ui.Image out = img;
  if (size != null && size != img.width) {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    out = await recorder.endRecording().toImage(size, size);
  }
  final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
  debugPrint('wrote $path');
}

RRect _squircle() => RRect.fromRectAndRadius(
  const Rect.fromLTWH(0, 0, _size, _size),
  const Radius.circular(236),
);

/// Soft top glass band, clipped to the squircle.
void _glassBand(Canvas canvas) {
  canvas.save();
  canvas.clipRRect(_squircle());
  final band = Path()
    ..moveTo(0, 0)
    ..lineTo(_size, 0)
    ..lineTo(_size, 300)
    ..quadraticBezierTo(_size * 0.45, 470, 0, 380)
    ..close();
  canvas.drawPath(
    band,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 470), [
        Colors.white.withValues(alpha: 0.16),
        Colors.white.withValues(alpha: 0.02),
      ]),
  );
  canvas.restore();
}

void _paintRupee(
  Canvas canvas, {
  required Offset center,
  required double fontSize,
  required Color color,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: '₹',
      style: TextStyle(
        fontFamily: 'NotoSansBold',
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
}

// ── The provided logo (default icon) ─────────────────────────────────────────

Future<ui.Image> _loadSource() async {
  final bytes = File(_sourcePath).readAsBytesSync();
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

/// Bounding box of the squircle. The artwork has a real alpha channel (the
/// glow backdrop is transparency, the glass paper is translucent), and the
/// squircle's teal frame is solid — so bounds are rows/columns containing a
/// substantial run of near-opaque pixels.
Future<Rect> _detectMarkBounds(ui.Image img) async {
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final px = data.buffer.asUint8List();
  final w = img.width, h = img.height;

  bool solid(int x, int y) => px[(y * w + x) * 4 + 3] > 200;

  int countRow(int y) {
    var c = 0;
    for (var x = 0; x < w; x++) {
      if (solid(x, y)) c++;
    }
    return c;
  }

  int countCol(int x) {
    var c = 0;
    for (var y = 0; y < h; y++) {
      if (solid(x, y)) c++;
    }
    return c;
  }

  const minRun = 60;
  var top = 0, bottom = h - 1, left = 0, right = w - 1;
  while (top < h && countRow(top) < minRun) {
    top++;
  }
  while (bottom > top && countRow(bottom) < minRun) {
    bottom--;
  }
  while (left < w && countCol(left) < minRun) {
    left++;
  }
  while (right > left && countCol(right) < minRun) {
    right--;
  }

  final rect = Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    (right + 1).toDouble(),
    (bottom + 1).toDouble(),
  ).inflate(12);
  final side = rect.longestSide;
  return Rect.fromCenter(center: rect.center, width: side, height: side);
}

// ── Alternate icon drawings ──────────────────────────────────────────────────

/// The purple/blue swoosh mark (previous default, kept as an option).
void _drawSwoosh(Canvas canvas) {
  canvas.drawRRect(
    _squircle(),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(_size, _size), [
        const Color(0xFF8B7CF0),
        const Color(0xFF4F63E8),
      ]),
  );
  _glassBand(canvas);

  const c = Offset(_size * 0.5, _size * 0.52);
  const s = 1.35;
  Offset p(double x, double y) => c + Offset(x * s, y * s);
  final path = Path()
    ..moveTo(p(-190, 150).dx, p(-190, 150).dy)
    ..quadraticBezierTo(
        p(-90, -70).dx, p(-90, -70).dy, p(20, -200).dx, p(20, -200).dy)
    ..quadraticBezierTo(
        p(120, -70).dx, p(120, -70).dy, p(250, 175).dx, p(250, 175).dy)
    ..quadraticBezierTo(
        p(120, 20).dx, p(120, 20).dy, p(35, -60).dx, p(35, -60).dy)
    ..quadraticBezierTo(
        p(-40, 10).dx, p(-40, 10).dy, p(-190, 150).dx, p(-190, 150).dy)
    ..close();
  canvas.drawPath(path, Paint()..color = Colors.white);
}

/// The original ₹ + rising spark on mint→teal (the app's first icon).
void _drawClassic(Canvas canvas) {
  canvas.drawRRect(
    _squircle(),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(_size, _size), [
        const Color(0xFF35C69F),
        const Color(0xFF0E3D33),
      ]),
  );
  _glassBand(canvas);
  _paintRupee(
    canvas,
    center: const Offset(_size * 0.45, _size * 0.41),
    fontSize: 520,
    color: Colors.white,
  );

  const area = Rect.fromLTRB(280, 680, 810, 830);
  final spark = Path()
    ..moveTo(area.left, area.bottom)
    ..lineTo(area.left + area.width * 0.34, area.bottom - area.height * 0.52)
    ..lineTo(area.left + area.width * 0.60, area.bottom - area.height * 0.30)
    ..lineTo(area.right, area.top);
  canvas.drawPath(
    spark,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 42
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF8CEBD1),
  );
  canvas.drawCircle(
    Offset(area.right, area.top),
    36,
    Paint()..color = Colors.white,
  );
}

/// Near-black glass with a neon-cyan ₹ — matches the app's default seed.
void _drawMidnight(Canvas canvas) {
  const cyan = Color(0xFF00E5FF);
  canvas.drawRRect(
    _squircle(),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(_size, _size), [
        const Color(0xFF15211F),
        const Color(0xFF090B0B),
      ]),
  );
  // Ambient glow behind the glyph.
  canvas.save();
  canvas.clipRRect(_squircle());
  canvas.drawCircle(
    const Offset(_size * 0.5, _size * 0.46),
    380,
    Paint()
      ..shader = ui.Gradient.radial(
        const Offset(_size * 0.5, _size * 0.46),
        380,
        [cyan.withValues(alpha: 0.35), cyan.withValues(alpha: 0)],
      ),
  );
  canvas.restore();
  _glassBand(canvas);
  _paintRupee(
    canvas,
    center: const Offset(_size * 0.5, _size * 0.48),
    fontSize: 560,
    color: cyan,
  );
  // Thin neon rim.
  canvas.drawRRect(
    _squircle().deflate(14),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = cyan.withValues(alpha: 0.55),
  );
}

// ── Generator ────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate launcher icons', () async {
    await _loadFont();
    final paint = Paint()..filterQuality = FilterQuality.high;

    // ---- Default icon, from the provided logo ----
    final src = await _loadSource();
    final mark = await _detectMarkBounds(src);
    debugPrint('detected mark bounds: $mark');

    final defaultIcon = await _render((canvas) {
      const rect = Rect.fromLTWH(0, 0, _size, _size);
      // The paper is translucent glass, so it needs a backdrop; a soft radial
      // glow echoes the original presentation.
      canvas.drawRect(rect, Paint()..color = const Color(0xFF06211B));
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            const Offset(_size * 0.55, _size * 0.4),
            _size * 0.75,
            [
              const Color(0xFF11493C).withValues(alpha: 0.9),
              const Color(0xFF06211B).withValues(alpha: 0),
            ],
          ),
      );
      canvas.drawImageRect(src, mark, rect, paint);
    });
    await _writeImage(defaultIcon, 'assets/icon/icon.png');
    await _writeImage(defaultIcon, '$_previewDir/receipt.png', size: 256);

    final foreground = await _render((canvas) {
      const inner = 690.0;
      canvas.drawImageRect(
        src,
        mark,
        Rect.fromCenter(
          center: const Offset(_size / 2, _size / 2),
          width: inner,
          height: inner,
        ),
        paint,
      );
    });
    await _writeImage(foreground, 'assets/icon/icon_foreground.png');

    // ---- Alternate icons: res mipmaps + previews ----
    final alternates = <String, void Function(Canvas)>{
      'swoosh': _drawSwoosh,
      'classic': _drawClassic,
      'midnight': _drawMidnight,
    };
    for (final e in alternates.entries) {
      final img = await _render(e.value);
      await _writeImage(img, '$_mipmapDir/ic_launcher_${e.key}.png', size: 192);
      await _writeImage(img, '$_previewDir/${e.key}.png', size: 256);
    }
  });
}
