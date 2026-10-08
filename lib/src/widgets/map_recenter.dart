import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

/// Street zoom a recentred map lands on (Expo's recenter animates to 16).
const recenterZoom = 16.0;

/// Moves [map] onto [at] at [zoom] ([recenterZoom] unless given). False
/// when there is nowhere to go yet, or the map is not drawn yet (a
/// controller can't move a map before its first frame).
bool recenterMap(MapController map, LatLng? at, {double zoom = recenterZoom}) {
  if (at == null) return false;
  try {
    return map.move(at, zoom);
  } catch (_) {
    return false;
  }
}

/// The round recenter (my location) button the maps share: a white disc
/// with a black outline arrow on a light map, a charcoal disc with a white
/// one on a dark map.
class RecenterButton extends StatelessWidget {
  const RecenterButton({super.key, required this.onPressed, this.tooltip = 'My location'});

  final VoidCallback? onPressed;
  final String tooltip;

  /// The disc's diameter.
  static const size = 52.0;
  static const lightFill = Colors.white;
  static const darkFill = Color(0xFF262626);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('map-recenter'),
        color: dark ? darkFill : lightFill,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: Colors.black45,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            // An outline arrow pointing up and to the right, as the reference.
            child: Icon(
              Icons.near_me_outlined,
              key: const ValueKey('map-recenter-icon'),
              size: 28,
              color: onPressed == null ? ink.withValues(alpha: 0.38) : ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Show whole route" (inDrive's): the [RecenterButton]'s disc holding a
/// winding route from a ringed start to a pin ([RouteIcon]).
class RouteFitButton extends StatelessWidget {
  const RouteFitButton({super.key, required this.onPressed, this.tooltip = 'Show whole route'});

  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: dark ? RecenterButton.darkFill : RecenterButton.lightFill,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: Colors.black45,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: RecenterButton.size,
            child: Center(child: RouteIcon(color: onPressed == null ? ink.withValues(alpha: 0.38) : ink)),
          ),
        ),
      ),
    );
  }
}

/// A route winding up from a ringed start (bottom left) to a location pin
/// (top right), drawn in [color] on a 24-unit grid scaled to [size].
class RouteIcon extends StatelessWidget {
  const RouteIcon({super.key, required this.color, this.size = 30});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('route-icon'),
    size: Size.square(size),
    painter: _RouteIconPainter(color),
  );
}

class _RouteIconPainter extends CustomPainter {
  const _RouteIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The start: a ring at the foot of the route.
    canvas.drawCircle(const Offset(5, 19), 2.3, stroke);
    // The road: right, round a bend up, back left, round again, out right.
    canvas.drawPath(
      Path()
        ..moveTo(7.3, 19)
        ..lineTo(15.5, 19)
        ..arcToPoint(const Offset(15.5, 12), radius: const Radius.circular(3.5), clockwise: false)
        ..lineTo(8.5, 12)
        ..arcToPoint(const Offset(8.5, 5), radius: const Radius.circular(3.5))
        ..lineTo(12, 5),
      stroke,
    );
    // The end: a pin standing on its point.
    const c = Offset(18.5, 5.2);
    const r = 3.2;
    final pin = Path()
      ..moveTo(c.dx, 11)
      ..lineTo(c.dx - 2.75, c.dy + 1.65)
      ..arcTo(Rect.fromCircle(center: c, radius: r), 2.6, 4.22, false)
      ..close();
    canvas.drawPath(pin, stroke);
    canvas.drawCircle(c, 0.9, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RouteIconPainter old) => old.color != color;
}
