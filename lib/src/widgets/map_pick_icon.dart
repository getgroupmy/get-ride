// "Choose on map": a rounded tile holding a folded paper map with a blue pin
// on it. Drawn here (no image asset), light and dark.
import 'dart:math' as math;

import 'package:flutter/material.dart';

class MapPickIcon extends StatelessWidget {
  const MapPickIcon({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MapPickPainter(dark: dark)),
    );
  }
}

class _MapPickPainter extends CustomPainter {
  _MapPickPainter({required this.dark});

  final bool dark;

  static const _pin = Color(0xFF2D7FF9);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // The tile.
    final tile = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(s * 0.2));
    canvas.drawRRect(tile, Paint()..color = dark ? const Color(0xFF3A3F45) : const Color(0xFFE9EBEE));
    canvas.drawRRect(
      tile.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark ? const Color(0xFF4A5057) : const Color(0xFFD5D8DC),
    );

    // The map: three panels folded in a zigzag, the middle one in shade.
    final top = s * 0.24, bottom = s * 0.80, left = s * 0.14, right = s * 0.86;
    final w = (right - left) / 3;
    final lift = s * 0.06;
    final light = dark ? const Color(0xFFDCE0E5) : Colors.white;
    final shade = dark ? const Color(0xFFB9C0C8) : const Color(0xFFE2E6EA);
    Path panel(double x0, double y0Top, double y1Top) => Path()
      ..moveTo(x0, top + y0Top)
      ..lineTo(x0 + w, top + y1Top)
      ..lineTo(x0 + w, bottom + y1Top)
      ..lineTo(x0, bottom + y0Top)
      ..close();
    final panels = [panel(left, 0, lift), panel(left + w, lift, 0), panel(left + 2 * w, 0, lift)];
    for (var i = 0; i < 3; i++) {
      canvas.drawPath(panels[i], Paint()..color = i == 1 ? shade : light);
    }
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.02
      ..strokeJoin = StrokeJoin.round
      ..color = dark ? const Color(0xFF8A939D) : const Color(0xFFB4BBC3);
    for (final p in panels) {
      canvas.drawPath(p, edge);
    }

    // A road across the map.
    final road = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.035
      ..strokeCap = StrokeCap.round
      ..color = dark ? const Color(0xFF9AA3AD) : const Color(0xFFC9CED4);
    canvas.drawPath(
      Path()
        ..moveTo(left + s * 0.04, bottom - s * 0.12)
        ..quadraticBezierTo(left + w * 1.4, top + s * 0.18, right - s * 0.04, top + s * 0.2),
      road,
    );

    // The pin: a drop pointing down, a white dot in its head.
    final cx = s * 0.56, headY = s * 0.40, r = s * 0.17, tipY = s * 0.74;
    final drop = Path()
      ..moveTo(cx, tipY)
      ..cubicTo(cx - r * 0.35, tipY - r * 0.9, cx - r, headY + r * 0.7, cx - r, headY)
      ..arcTo(Rect.fromCircle(center: Offset(cx, headY), radius: r), math.pi, math.pi, false)
      ..cubicTo(cx + r, headY + r * 0.7, cx + r * 0.35, tipY - r * 0.9, cx, tipY)
      ..close();
    canvas.drawShadow(drop, Colors.black, s * 0.03, false);
    canvas.drawPath(drop, Paint()..color = _pin);
    canvas.drawCircle(Offset(cx, headY), r * 0.42, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_MapPickPainter old) => old.dark != dark;
}
