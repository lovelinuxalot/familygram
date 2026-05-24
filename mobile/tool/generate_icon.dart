// Generates the app icon at assets/icon/icon.png (1024×1024).
// Run with:  dart run tool/generate_icon.dart
// Then run:  dart run flutter_launcher_icons   (emits the iOS icon set)
//
// Design: three rotated polaroid frames stacked at different angles. Each
// polaroid is drawn off-canvas onto a transparent stamp, rotated, then
// composited onto the navy background. The order in `_polaroids` is back →
// front (later entries are drawn on top).

import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  const size = 1024;
  final canvas = img.Image(width: size, height: size);

  final navy = img.ColorRgb8(0x1E, 0x3A, 0x5F);
  img.fill(canvas, color: navy);

  // Three "memories" in distinct warm-ish tones so the stack feels like
  // different days, not just three copies of the same photo.
  final polaroids = <_PolaroidSpec>[
    // Back-left, leaning left.
    _PolaroidSpec(
      centerX: 420, centerY: 480, angle: -16,
      photoColor: img.ColorRgb8(0xB7, 0xD0, 0xE0),     // sky blue
    ),
    // Back-right, leaning right.
    _PolaroidSpec(
      centerX: 612, centerY: 460, angle: 12,
      photoColor: img.ColorRgb8(0xF3, 0xD1, 0x97),     // warm sand
    ),
    // Front-centre, very slight tilt — this is the "newest" memory.
    _PolaroidSpec(
      centerX: 512, centerY: 580, angle: -3,
      photoColor: img.ColorRgb8(0xBE, 0xDC, 0xC3),     // sage
    ),
  ];

  for (final p in polaroids) {
    _stamp(canvas, p);
  }

  final bytes = img.encodePng(canvas);
  const path = 'assets/icon/icon.png';
  File(path).writeAsBytesSync(bytes);
  // ignore: avoid_print  -- this script is a dev CLI tool, not app code.
  print('Wrote $path (${bytes.length} bytes)');
}

class _PolaroidSpec {
  final int centerX, centerY;
  final double angle; // degrees, positive = clockwise
  final img.Color photoColor;
  _PolaroidSpec({required this.centerX, required this.centerY, required this.angle, required this.photoColor});
}

// Draws a single polaroid offscreen, rotates it, composites onto the canvas.
void _stamp(img.Image canvas, _PolaroidSpec spec) {
  const w = 460;
  const h = 540;
  // Pad so rotation doesn't clip the corners.
  const pad = 140;
  final stamp = img.Image(width: w + pad * 2, height: h + pad * 2, numChannels: 4);

  // Light off-white polaroid frame.
  final paper = img.ColorRgba8(0xFA, 0xFB, 0xFD, 0xFF);
  _drawRoundedRect(stamp, pad, pad, pad + w, pad + h, 28, paper);

  // Photo area: top-and-sides 28 px inset, wider strip on the bottom (the
  // polaroid signature "label" area).
  const inset = 28;
  const photoBottom = 410; // local stamp y
  final pc = spec.photoColor;
  final photo = img.ColorRgba8(pc.r.toInt(), pc.g.toInt(), pc.b.toInt(), 0xFF);
  img.fillRect(stamp,
      x1: pad + inset, y1: pad + inset,
      x2: pad + w - inset, y2: pad + photoBottom,
      color: photo);

  // Rotate. image's copyRotate returns an enlarged transparent-background
  // image that contains the rotated content.
  final rotated = img.copyRotate(stamp, angle: spec.angle);

  // Composite at the requested centre. The rotation pivots around the
  // stamp's centre, so subtracting half the new dimensions aligns it.
  img.compositeImage(canvas, rotated,
      dstX: spec.centerX - rotated.width ~/ 2,
      dstY: spec.centerY - rotated.height ~/ 2);
}

void _drawRoundedRect(img.Image image, int x1, int y1, int x2, int y2, int r, img.Color color) {
  img.fillRect(image, x1: x1 + r, y1: y1,     x2: x2 - r, y2: y2,     color: color);
  img.fillRect(image, x1: x1,     y1: y1 + r, x2: x2,     y2: y2 - r, color: color);
  img.fillCircle(image, x: x1 + r, y: y1 + r, radius: r, color: color);
  img.fillCircle(image, x: x2 - r, y: y1 + r, radius: r, color: color);
  img.fillCircle(image, x: x1 + r, y: y2 - r, radius: r, color: color);
  img.fillCircle(image, x: x2 - r, y: y2 - r, radius: r, color: color);
}
