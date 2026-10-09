import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The "currently unavailable" picture: someone shading their eyes under a
/// palm tree on a little island, looking out for a ride that can't reach
/// them. Drawn in code (an original illustration, no image asset), on a
/// 300 × 260 canvas scaled to fit. Its colours are its own and read on a
/// light or a dark sheet alike.
class CastawayIllustration extends StatelessWidget {
  const CastawayIllustration({super.key, this.height = 230});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: AspectRatio(
      aspectRatio: 300 / 260,
      child: CustomPaint(key: const ValueKey('castaway-illustration'), painter: CastawayPainter()),
    ),
  );
}

class CastawayPainter extends CustomPainter {
  static const _waterDeep = Color(0xFF1B4F8C);
  static const _waterMid = Color(0xFF2F7FD0);
  static const _waterLight = Color(0xFF8CC8F2);
  static const _sand = Color(0xFFE0BF8E);
  static const _sandLight = Color(0xFFF2DBB3);
  static const _sandDark = Color(0xFFB8925E);
  static const _trunk = Color(0xFFC59A6B);
  static const _trunkDark = Color(0xFF8E6740);
  static const _leaf = Color(0xFF2FA38C);
  static const _leafDark = Color(0xFF1E7A68);
  static const _coconut = Color(0xFF8A4535);
  static const _coconutLight = Color(0xFFB0644F);
  static const _shirt = Color(0xFF2E9E57);
  static const _shirtDark = Color(0xFF1F7A42);
  static const _trousers = Color(0xFF26262E);
  static const _skin = Color(0xFFF1C39C);
  static const _hair = Color(0xFFE6B443);
  static const _shoe = Color(0xFFF7F7F7);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 300, size.height / 260);
    _sea(canvas);
    _island(canvas);
    _palm(canvas);
    _person(canvas);
    canvas.restore();
  }

  Paint _fill(Color c) => Paint()
    ..color = c
    ..isAntiAlias = true;

  void _sea(Canvas canvas) {
    const rect = Rect.fromLTWH(28, 214, 244, 40);
    canvas.drawOval(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_waterMid, _waterDeep],
        ).createShader(rect),
    );
    // Little waves catching the light.
    final wave = Paint()
      ..color = _waterLight.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (final (x, y, w) in const [
      (52.0, 236.0, 26.0),
      (214.0, 240.0, 30.0),
      (238.0, 228.0, 18.0),
      (96.0, 246.0, 22.0),
    ]) {
      canvas.drawArc(Rect.fromLTWH(x, y - 3, w, 8), math.pi, math.pi, false, wave);
    }
  }

  void _island(Canvas canvas) {
    canvas.drawOval(const Rect.fromLTWH(56, 206, 188, 30), _fill(_sandDark));
    canvas.drawOval(const Rect.fromLTWH(58, 202, 184, 28), _fill(_sand));
    canvas.drawOval(const Rect.fromLTWH(84, 204, 120, 12), _fill(_sandLight));
    final pebble = _fill(_sandDark);
    for (final (x, y, r) in const [(92.0, 220.0, 2.4), (208.0, 216.0, 2.0), (118.0, 224.0, 1.6), (224.0, 222.0, 1.8)]) {
      canvas.drawCircle(Offset(x, y), r, pebble);
    }
  }

  /// A trunk of stacked rings leaning gently, its crown of fronds and three
  /// coconuts.
  void _palm(Canvas canvas) {
    const base = Offset(176, 214), control = Offset(192, 120), top = Offset(176, 46);
    Offset at(double t) => Offset(
      (1 - t) * (1 - t) * base.dx + 2 * (1 - t) * t * control.dx + t * t * top.dx,
      (1 - t) * (1 - t) * base.dy + 2 * (1 - t) * t * control.dy + t * t * top.dy,
    );
    const rings = 18;
    for (var i = 0; i < rings; i++) {
      final t0 = i / rings, t1 = (i + 1) / rings;
      final a = at(t0), b = at(t1);
      final w0 = 9.0 - 3.5 * t0, w1 = 9.0 - 3.5 * t1;
      final ring = Path()
        ..moveTo(a.dx - w0, a.dy)
        ..lineTo(b.dx - w1 - 1.5, b.dy + 1)
        ..quadraticBezierTo(b.dx, b.dy - 3, b.dx + w1 + 1.5, b.dy + 1)
        ..lineTo(a.dx + w0, a.dy)
        ..quadraticBezierTo(a.dx, a.dy - 3, a.dx - w0, a.dy)
        ..close();
      canvas.drawPath(ring, _fill(i.isEven ? _trunk : const Color(0xFFD1A877)));
      canvas.drawPath(
        ring,
        Paint()
          ..color = _trunkDark
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
    }

    // Fronds: (angle in degrees, length, droop).
    const fronds = [
      (200.0, 82.0, 26.0),
      (232.0, 62.0, 14.0),
      (268.0, 46.0, 8.0),
      (305.0, 60.0, -14.0),
      (338.0, 80.0, -26.0),
      (180.0, 58.0, 30.0),
      (8.0, 56.0, -30.0),
    ];
    for (final (deg, len, droop) in fronds) {
      _frond(canvas, top, deg * math.pi / 180, len, droop);
    }

    for (final (dx, dy) in const [(-11.0, 10.0), (2.0, 14.0), (12.0, 6.0)]) {
      final c = top + Offset(dx, dy);
      canvas.drawCircle(c, 9, _fill(_coconut));
      canvas.drawCircle(c + const Offset(-3, -3), 3.2, _fill(_coconutLight));
    }
  }

  void _frond(Canvas canvas, Offset from, double angle, double length, double droop) {
    final dir = Offset(math.cos(angle), math.sin(angle));
    final normal = Offset(-dir.dy, dir.dx);
    final tip = from + dir * length + const Offset(0, 1) * droop.abs() * 0.9;
    final mid = from + dir * (length * 0.55) + normal * (droop * 0.35);
    final width = length * 0.17;
    final leaf = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(mid.dx + normal.dx * width, mid.dy + normal.dy * width - width * 0.6, tip.dx, tip.dy)
      ..quadraticBezierTo(mid.dx - normal.dx * width, mid.dy - normal.dy * width + width * 0.6, from.dx, from.dy)
      ..close();
    canvas.drawPath(leaf, _fill(_leaf));
    final rib = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(mid.dx, mid.dy, tip.dx, tip.dy);
    canvas.drawPath(
      rib,
      Paint()
        ..color = _leafDark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
  }

  /// Leaning on the trunk, one hand shading the eyes.
  void _person(Canvas canvas) {
    final stroke = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Shoes and legs.
    canvas.drawRRect(RRect.fromLTRBR(131, 206, 143, 214, const Radius.circular(3)), _fill(_shoe));
    canvas.drawRRect(RRect.fromLTRBR(147, 206, 159, 214, const Radius.circular(3)), _fill(_shoe));
    canvas.drawRRect(RRect.fromLTRBR(133, 148, 143, 208, const Radius.circular(4)), _fill(_trousers));
    canvas.drawRRect(RRect.fromLTRBR(147, 148, 157, 208, const Radius.circular(4)), _fill(_trousers));
    canvas.drawRRect(RRect.fromLTRBR(132, 144, 158, 162, const Radius.circular(5)), _fill(_trousers));

    // Shirt.
    final shirt = Path()
      ..moveTo(130, 116)
      ..quadraticBezierTo(145, 104, 160, 116)
      ..lineTo(160, 150)
      ..quadraticBezierTo(145, 154, 130, 150)
      ..close();
    canvas.drawPath(shirt, _fill(_shirt));
    canvas.drawLine(
      const Offset(145, 112),
      const Offset(145, 150),
      stroke
        ..color = _shirtDark
        ..strokeWidth = 1.2,
    );

    // The arm resting on the trunk.
    canvas.drawLine(
      const Offset(158, 118),
      const Offset(168, 136),
      stroke
        ..color = _shirt
        ..strokeWidth = 8,
    );
    canvas.drawCircle(const Offset(170, 139), 4, _fill(_skin));

    // The arm raised to shade the eyes.
    canvas.drawLine(
      const Offset(132, 118),
      const Offset(122, 100),
      stroke
        ..color = _shirt
        ..strokeWidth = 8,
    );
    canvas.drawLine(
      const Offset(122, 100),
      const Offset(136, 90),
      stroke
        ..color = _shirt
        ..strokeWidth = 7,
    );

    // Head, ponytail and the shading hand over the brow.
    canvas.drawCircle(const Offset(152, 87), 6, _fill(_hair));
    canvas.drawRect(const Rect.fromLTWH(143, 98, 5, 6), _fill(_skin));
    canvas.drawCircle(const Offset(145, 90), 10.5, _fill(_skin));
    final hair = Path()
      ..moveTo(135, 88)
      ..quadraticBezierTo(137, 76, 147, 77)
      ..quadraticBezierTo(156, 79, 155, 89)
      ..quadraticBezierTo(147, 82, 135, 88)
      ..close();
    canvas.drawPath(hair, _fill(_hair));
    canvas.drawRRect(RRect.fromLTRBR(134, 85, 148, 90, const Radius.circular(2.5)), _fill(_skin));
    canvas.drawCircle(const Offset(141, 93), 1.2, _fill(_trousers));
  }

  @override
  bool shouldRepaint(CastawayPainter oldDelegate) => false;
}
