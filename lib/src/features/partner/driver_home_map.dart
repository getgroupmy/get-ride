import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/compass.dart';
import '../../data/models.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/map_traffic.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/road_info_layers.dart';

/// The driver's home map (Expo `partner-ehailing`): where they are and,
/// while online, where each open request is waiting, with its fare. Tapping
/// a pin opens that request in [onSelect].
///
/// It opens at street level ([driverHomeZoom]) on the driver and follows
/// them as they move, keeping them in the middle of the map above the
/// sheet. Moving the map by hand — panning, zooming or turning it (two
/// fingers; the idle home map rotates freely) — stops the following; the
/// recenter button recentres on the driver and straightens it north-up.
class DriverHomeMap extends ConsumerStatefulWidget {
  const DriverHomeMap({super.key, required this.me, required this.requests, this.onSelect});

  final LatLng? me;

  /// The requests to pin (those on the driver's queue).
  final List<RideRequest> requests;
  final void Function(RideRequest)? onSelect;

  @override
  ConsumerState<DriverHomeMap> createState() => _DriverHomeMapState();
}

/// Street level: the roads and buildings around the driver.
const driverHomeZoom = 18.0;

class _DriverHomeMapState extends ConsumerState<DriverHomeMap> with SingleTickerProviderStateMixin {
  final _map = MapController();
  bool _ready = false;
  bool _follow = true;

  /// The device's compass heading, null where the phone has no compass. When
  /// known and following, the map turns so the heading is up (Expo's idle map);
  /// without it the map stays north-up as before.
  double? _heading;

  /// Following the driver with a known heading: the driver sits dead-centre and
  /// the map turns under them so the way the phone points is up.
  bool get _headingUp => _follow && _heading != null;

  /// The camera's glide from where it is to the driver.
  late final _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
    ..addListener(_glideTick);
  LatLng? _from, _to;
  double _zoom = driverHomeZoom;

  /// The live traffic tiles over the map, and the source they were made for.
  List<Widget> _overlays = const [];
  (String?, bool, String?)? _trafficFor;

  @override
  void dispose() {
    _glide.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DriverHomeMap old) {
    super.didUpdateWidget(old);
    if (widget.me != old.me) WidgetsBinding.instance.addPostFrameCallback((_) => _center());
  }

  /// Where the driver sits: dead-centre in heading-up mode (so the map turns
  /// cleanly around them), else a little above the sheet.
  Offset get _offset => _headingUp ? Offset.zero : Offset(0, -MapBottomInset.of(context) / 2);

  /// Turn the map so the compass [h] points up (north-up when null). Rotating
  /// around the camera's centre — where the driver sits in heading-up mode —
  /// keeps the driver fixed while the map turns.
  void _face(double? h) {
    try {
      _map.rotate(h == null ? 0 : -h);
    } catch (_) {}
  }

  /// Glides the camera onto the driver, at the zoom the map is at.
  void _center({bool jump = false}) {
    final me = widget.me;
    if (!mounted || !_follow || !_ready || me == null) return;
    final MapCamera camera;
    try {
      camera = _map.camera;
    } catch (_) {
      return;
    }
    _zoom = camera.zoom;
    if (jump) {
      _map.move(me, _zoom, offset: _offset);
      return;
    }
    _from = _to ?? camera.center;
    _to = me;
    _glide.forward(from: 0);
  }

  void _glideTick() {
    final a = _from, b = _to;
    if (a == null || b == null || !mounted) return;
    final t = Curves.easeInOut.transform(_glide.value);
    try {
      _map.move(
        LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t),
        _zoom,
        offset: _offset,
      );
    } catch (_) {}
  }

  /// A hand on the map: stop following until the recenter button.
  void _onGesture() {
    if (!_follow) return;
    _glide.stop();
    _from = _to = null;
    setState(() => _follow = false);
  }

  void _recenter() {
    setState(() => _follow = true);
    _glide.stop();
    _from = _to = null;
    final me = widget.me;
    if (me == null) return;
    try {
      // Centre on the driver and resume heading-up (north-up when there is no
      // compass). _offset reads _headingUp, so recentre after _follow is set.
      _map.move(me, driverHomeZoom, offset: _offset);
      _face(_heading);
    } catch (_) {}
  }

  /// A fresh compass heading: remember it and, while following, turn the map to
  /// it. Entering heading-up mode re-centres the driver (the offset changed);
  /// after that only the rotation moves.
  void _onHeading(double h) {
    final entering = _heading == null;
    _heading = h;
    if (!_follow || !_ready) {
      if (entering && mounted) setState(() {}); // nativeMe depends on _heading
      return;
    }
    final me = widget.me;
    try {
      if (entering && me != null) {
        _map.move(me, _map.camera.zoom, offset: Offset.zero);
      }
      _face(h);
    } catch (_) {}
    if (entering && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me, requests = widget.requests, onSelect = widget.onSelect;
    final t = Theme.of(context);
    // The device compass turns the map heading-up while following (Expo's idle
    // map). Only this map listens, so the sensor runs while the driver waits
    // and stops when they leave.
    ref.listen(deviceHeadingProvider, (_, next) {
      final h = next.value;
      if (h != null && mounted) _onHeading(h);
    });
    final trafficUrl = ref.watch(trafficTileUrlProvider);
    final trafficOn = trafficUrl != null && ref.watch(mapTrafficProvider);
    final trafficFallback = ref.watch(trafficFallbackTileUrlProvider);
    // Kept while its source is, so a new position does not redraw its tiles.
    final trafficFor = (trafficUrl, trafficOn, trafficFallback);
    if (_trafficFor != trafficFor) {
      _trafficFor = trafficFor;
      final layer = trafficTileLayer(trafficUrl, on: trafficOn, fallback: trafficFallback);
      _overlays = [?layer];
    }
    final map = RideMap(
      controller: _map,
      me: me,
      // Heading-up (following with a compass): the driver sits dead-centre, so
      // the flutter_map dot under the heading beam never drifts — keep it. Off
      // heading-up (panned, or no compass), let the native map draw the dot so
      // it stays put while the driver pans the map around.
      nativeMe: !_headingUp,
      pointZoom: driverHomeZoom,
      // The camera follows the driver instead of framing the pins.
      autoFit: false,
      // The idle home map turns freely: two fingers rotate it (a gesture
      // stops the following, as pan and zoom do; recenter straightens it).
      rotate: true,
      onGesture: _onGesture,
      onReady: () {
        _ready = true;
        _center(jump: true);
      },
      satellite: ref.watch(mapSatelliteProvider),
      // Live traffic, when a traffic tile source is configured and switched on.
      tileOverlays: _overlays,
      extraMarkers: [
        for (final r in requests)
          if (r.pickupLat != null && r.pickupLng != null)
            Marker(
              point: LatLng(r.pickupLat!, r.pickupLng!),
              width: 110,
              height: 34,
              child: GestureDetector(
                key: ValueKey('map-request-${r.id}'),
                onTap: onSelect == null ? null : () => onSelect(r),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.colorScheme.primary,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.hail, size: 14, color: t.colorScheme.onPrimary),
                        const SizedBox(width: 4),
                        Text(
                          r.fareText(r.effectiveFare),
                          style: TextStyle(color: t.colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
    return Stack(
      children: [
        map,
        // Heading-up: the driver sits dead-centre and the map turns under them,
        // so their facing is always the top of the screen. A beam fanning up
        // from the dot shows it, like a car sat-nav. Drawn screen-fixed (not a
        // map marker) so it never rotates with the map — it is always "up".
        if (_headingUp)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(child: _HeadingBeam()),
            ),
          ),
        // The road the driver is on: its limit, or its class as an estimate.
        // Below the page's menu button.
        Positioned(left: 12, top: 84, child: SafeArea(child: SpeedLimitBadge(at: me))),
        // Bottom right, above the sheet, as on the trip maps.
        MapBottomInset.listen(
          context,
          (inset) => Positioned(
            // Clear of the notch on a phone on its side.
            right: 12 + MediaQuery.paddingOf(context).right,
            // Clear of the sheet's rounded corner too, so the buttons never
            // tuck against it on a device whose sheet rests tight to them.
            bottom: mapAttributionClearance + MapBottomInset.cornerOf(context) + inset,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Traffic (when configured), then map view above recenter.
              const TrafficButton(),
              const MapTypeButton(),
              const SizedBox(height: 8),
              // Expo's driver map recenters on the driver.
              RecenterButton(onPressed: me == null ? null : _recenter),
            ]),
          ),
        ),
      ],
    );
  }
}

/// The heading beam over the driver's dot on the heading-up idle map: a
/// translucent cone fanning up from the dot, like a car sat-nav's position
/// marker. Screen-fixed and always pointing up — the map turns under it so the
/// top of the screen is always where the phone points.
class _HeadingBeam extends StatelessWidget {
  const _HeadingBeam();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(72, 72), painter: _HeadingBeamPainter());
  }
}

class _HeadingBeamPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // A cone opening upward from the dot, narrowing to the apex.
    final reach = size.height / 2;
    final apex = Offset(c.dx, c.dy - reach);
    final left = Offset(c.dx - reach * 0.55, c.dy - reach * 0.45);
    final right = Offset(c.dx + reach * 0.55, c.dy - reach * 0.45);
    final cone = ui.Path()
      ..moveTo(c.dx, c.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(apex.dx, apex.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    final beam = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00448AFF), Color(0x66448AFF)],
      ).createShader(Rect.fromPoints(apex, c));
    canvas.drawPath(cone, beam);
  }

  @override
  bool shouldRepaint(_HeadingBeamPainter oldDelegate) => false;
}
