import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// inDrive's "looking for drivers" pulse: soft white rings that grow out of
/// a point and fade, one after another, for as long as it is shown.
class RadarPulse extends StatefulWidget {
  const RadarPulse({
    super.key,
    this.size = radarPulseSize,
    this.rings = 3,
    this.period = const Duration(milliseconds: 2400),
  });

  /// The widest a ring grows, edge to edge.
  final double size;
  final int rings;

  /// How long one ring takes to grow out and fade.
  final Duration period;

  @override
  State<RadarPulse> createState() => _RadarPulseState();
}

/// The widest the pickup's pulse grows, in logical pixels.
const radarPulseSize = 260.0;

class _RadarPulseState extends State<RadarPulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        key: const ValueKey('radar-pulse'),
        size: Size.square(widget.size),
        painter: _RadarPainter(_c, widget.rings),
      ),
    ),
  );
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.rings) : super(repaint: t);

  final Animation<double> t;
  final int rings;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final max = size.shortestSide / 2;
    for (var i = 0; i < rings; i++) {
      // Each ring a step behind the last, so one is always on its way out.
      final p = (t.value + i / rings) % 1;
      final r = max * Curves.easeOut.transform(p);
      final a = (1 - p) * (1 - p);
      // A white disc with a glow round its rim: bright near the point,
      // gone by the time it reaches its widest.
      canvas.drawCircle(c, r, Paint()..color = Colors.white.withValues(alpha: 0.35 * a));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.9 * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    // A steady glow at the centre, under the pin.
    canvas.drawCircle(
      c,
      14,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.rings != rings;
}

/// The pulse as a map layer, centred on [at] (drawn under the pins).
Widget radarPulseLayer(LatLng at, {double size = radarPulseSize}) => MarkerLayer(
  markers: [
    Marker(
      point: at,
      width: size,
      height: size,
      child: RadarPulse(size: size),
    ),
  ],
);
