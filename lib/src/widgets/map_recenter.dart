import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'focus_order.dart';
import 'map_brightness.dart';

/// Street zoom a recentred map lands on (Expo's recenter animates to 16).
const recenterZoom = 16.0;

/// Moves [map] onto [at] at [zoom] ([recenterZoom] unless given), [offset]
/// from the map's centre ([MapBottomInset.focusOffset]). False when there
/// is nowhere to go yet, or the map is not drawn yet (a controller can't
/// move a map before its first frame).
bool recenterMap(MapController map, LatLng? at, {double zoom = recenterZoom, Offset offset = Offset.zero}) {
  if (at == null) return false;
  try {
    return map.move(at, zoom, offset: offset);
  } catch (_) {
    return false;
  }
}

/// The round recenter (my location) button the maps share: a white disc
/// with a black outline arrow on a light map, a charcoal disc with a white
/// one on a dark map.
class RecenterButton extends StatelessWidget {
  const RecenterButton({super.key, required this.onPressed, this.tooltip = 'My location', this.headingUp = false});

  final VoidCallback? onPressed;
  final String tooltip;

  /// Following with the map turned to the heading (heading-up): the icon fills
  /// in and goes blue to show navigation is on, like Apple/Google Maps.
  final bool headingUp;

  /// The disc's diameter.
  static const size = 52.0;
  static const lightFill = Colors.white;
  static const darkFill = Color(0xFF262626);

  // Floats over the map: reached after the page's own content
  // ([FocusLast], on wide layouts).
  @override
  Widget build(BuildContext context) => FocusLast(child: _build(context));

  Widget _build(BuildContext context) {
    final dark = mapIsDark(context);
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
            // An outline arrow pointing up and to the right, as the reference;
            // a filled blue navigation arrow while heading-up is engaged.
            child: Icon(
              headingUp ? Icons.navigation : Icons.near_me_outlined,
              key: const ValueKey('map-recenter-icon'),
              size: 28,
              color: onPressed == null
                  ? ink.withValues(alpha: 0.38)
                  : (headingUp ? const Color(0xFF1A73E8) : ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// The compass (Apple/Google Maps'): a disc with a red-north needle turned to
/// the map's current [bearing] (degrees, 0 = north-up), so it always points to
/// true north. Tapping it returns the map to north-up. Shown only while the map
/// is turned away from north.
class CompassButton extends StatelessWidget {
  const CompassButton({super.key, required this.bearing, required this.onPressed, this.tooltip = 'Point north'});

  /// The map camera's rotation in degrees (0 = north-up).
  final double bearing;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => FocusLast(child: _build(context));

  Widget _build(BuildContext context) {
    final dark = mapIsDark(context);
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('map-compass'),
        color: dark ? RecenterButton.darkFill : RecenterButton.lightFill,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: Colors.black45,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: RecenterButton.size,
            // The needle turns with the map so its red half always points to
            // geographic north (the base rotates by the camera rotation).
            child: Transform.rotate(
              angle: bearing * math.pi / 180,
              child: Center(child: CompassNeedle(color: ink)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compass needle: a red half pointing one way (north) and a muted [color]
/// half the other, on a 24-unit grid scaled to [size].
class CompassNeedle extends StatelessWidget {
  const CompassNeedle({super.key, required this.color, this.size = 26});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('compass-needle'),
    size: Size.square(size),
    painter: _CompassPainter(color),
  );
}

class _CompassPainter extends CustomPainter {
  const _CompassPainter(this.color);

  final Color color;
  static const _red = Color(0xFFE53935);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final w = size.width * 0.24; // half-width of the needle at the centre
    final h = size.height * 0.42; // tip distance from the centre
    final north = Path()
      ..moveTo(c.dx, c.dy - h)
      ..lineTo(c.dx - w, c.dy)
      ..lineTo(c.dx + w, c.dy)
      ..close();
    canvas.drawPath(north, Paint()..color = _red);
    final south = Path()
      ..moveTo(c.dx, c.dy + h)
      ..lineTo(c.dx - w, c.dy)
      ..lineTo(c.dx + w, c.dy)
      ..close();
    canvas.drawPath(south, Paint()..color = color.withValues(alpha: 0.55));
  }

  @override
  bool shouldRepaint(_CompassPainter old) => old.color != color;
}

/// "Show whole route" (inDrive's): the [RecenterButton]'s disc holding a
/// winding route from a ringed start to a pin ([RouteIcon]).
class RouteFitButton extends StatelessWidget {
  const RouteFitButton({super.key, required this.onPressed, this.tooltip = 'Show whole route'});

  final VoidCallback? onPressed;
  final String tooltip;

  // Floats over the map: reached after the page's own content
  // ([FocusLast], on wide layouts).
  @override
  Widget build(BuildContext context) => FocusLast(child: _build(context));

  Widget _build(BuildContext context) {
    final dark = mapIsDark(context);
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
