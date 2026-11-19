import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/compass.dart';
import '../../data/models.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/map_tiles.dart' show appleRouteBaseActive, googleNativeBaseActive;
import '../../widgets/map_traffic.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/road_info_layers.dart';
import 'driver_map_diagnostics.dart';
import 'driver_map_diagnostics_overlay.dart';

/// The driver's home map (Expo `partner-ehailing`): where they are and,
/// while online, where each open request is waiting, with its fare. Tapping
/// a pin opens that request in [onSelect].
///
/// It opens at street level ([driverHomeZoom]) on the driver and follows them
/// as they move. The locate button cycles like Apple/Google Maps: recentre
/// north-up, then heading-up (the map turns so the driver's direction of travel
/// is up), then back. The map turns freely by hand (two fingers); a gesture
/// stops the following, and the compass button (shown once the map is turned)
/// snaps it back to north-up.
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

/// The next follow / heading-up state when the locate button is tapped, cycling
/// like Apple/Google Maps: (paused) → follow north-up → follow heading-up →
/// follow north-up → … Pure.
({bool follow, bool headingMode}) nextLocateMode({required bool follow, required bool headingMode}) {
  if (!follow) return (follow: true, headingMode: false);
  return (follow: true, headingMode: !headingMode);
}

class _DriverHomeMapState extends ConsumerState<DriverHomeMap> with SingleTickerProviderStateMixin {
  final _map = MapController();
  bool _ready = false;
  bool _follow = true;

  /// Whether, while following, the map turns so the driver's heading is up
  /// (heading-up navigation). Off is north-up. Toggled by the locate button.
  bool _headingMode = false;

  /// The map's current rotation in degrees (0 = north-up), tracked from the map
  /// events so the compass button turns with it.
  double _bearing = 0;
  StreamSubscription<MapEvent>? _mapEvents;

  /// The device heading (the GPS course while moving, the compass while stopped;
  /// data/compass.dart), null until a sensor answers. While following it turns
  /// the arrow over the driver's dot, and in heading-up mode it turns the map.
  double? _heading;

  /// The camera's glide from where it is to the driver.
  late final _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
    ..addListener(_glideTick);
  LatLng? _from, _to;
  double _zoom = driverHomeZoom;

  /// The live traffic tiles over the map, and the source they were made for.
  List<Widget> _overlays = const [];
  (String?, bool, String?)? _trafficFor;

  @override
  void initState() {
    super.initState();
    // Keep the compass button turned to the map: watch the camera's rotation.
    _mapEvents = _map.mapEventStream.listen((_) {
      if (!mounted) return;
      final double r;
      try {
        r = _map.camera.rotation;
      } catch (_) {
        return;
      }
      if ((r - _bearing).abs() > 0.1) setState(() => _bearing = r);
    });
    // Debug-only: redraw when the tester locks/clears the diagnostic reference
    // marker (its button lives in the overlay, not this widget).
    if (driverMapDiagnosticsEnabled) driverMapReference.addListener(_diagRefChanged);
  }

  @override
  void dispose() {
    _mapEvents?.cancel();
    if (driverMapDiagnosticsEnabled) driverMapReference.removeListener(_diagRefChanged);
    _glide.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DriverHomeMap old) {
    super.didUpdateWidget(old);
    if (widget.me != old.me) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _center());
      final me = widget.me;
      if (driverMapDiagnosticsEnabled && me != null) {
        driverMapNoteRawFix(me.latitude, me.longitude);
        _diagRecord(DriverMapEventKind.gpsFix, gpsLat: me.latitude, gpsLng: me.longitude);
      }
    }
  }

  /// Heading-up and actually following with a heading to turn to.
  bool get _headingUp => _follow && _headingMode && _heading != null;

  /// Where the driver's dot sits on screen: dead-centre in heading-up mode (so
  /// the map turns cleanly around them), else a little above the sheet.
  Offset get _offset => _headingUp ? Offset.zero : Offset(0, -MapBottomInset.of(context) / 2);

  /// Turn the map so heading [h] points up (north-up when null). The native
  /// Apple/Google base rotates with the flutter_map camera, so tiles and
  /// overlays turn together.
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
    // Start the glide from where the camera actually is now, not from the last
    // glide's destination (_to): a fresh fix often lands before the 600 ms
    // glide has finished, and starting at the old target snapped the camera
    // forward to it before interpolating (the jitter while following). With
    // the live centre each restart continues smoothly from the visible spot.
    _from = camera.center;
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
    if (driverMapDiagnosticsEnabled) _diagSampleCamera(animating: _glide.isAnimating);
  }

  /// A hand on the map: stop following until the recenter button.
  void _onGesture() {
    if (!_follow) return;
    _glide.stop();
    _from = _to = null;
    setState(() => _follow = false);
    if (driverMapDiagnosticsEnabled) {
      driverMapLive
        ..gesture = true
        ..follow = false
        ..animationActive = false
        ..touch();
      _diagRecord(DriverMapEventKind.gestureStart, gesture: true);
      _diagRecord(DriverMapEventKind.followChanged);
    }
  }

  /// The locate button: cycle (paused) → follow north-up → follow heading-up →
  /// follow north-up, recentring and re-orienting the map to match.
  void _onLocate() {
    final next = nextLocateMode(follow: _follow, headingMode: _headingMode);
    setState(() {
      _follow = next.follow;
      _headingMode = next.headingMode;
    });
    _glide.stop();
    _from = _to = null;
    if (driverMapDiagnosticsEnabled) {
      driverMapLive
        ..gesture = false
        ..follow = _follow
        ..touch();
      _diagRecord(DriverMapEventKind.recenterTap, zoom: _safeZoom());
      _diagRecord(DriverMapEventKind.followChanged);
    }
    final me = widget.me;
    if (me == null) return;
    try {
      // Resume at the zoom the driver left the map at, not back at street level,
      // and orient it: heading-up turns to the heading, north-up straightens.
      _map.move(me, _map.camera.zoom, offset: _offset);
      _face(_headingUp ? _heading : null);
    } catch (_) {}
  }

  /// The compass button: snap back to north-up and leave heading-up mode, but
  /// keep following. Shown only once the map is turned away from north.
  void _onCompass() {
    setState(() => _headingMode = false);
    try {
      _face(null);
      final me = widget.me;
      if (_follow && me != null) _map.move(me, _map.camera.zoom, offset: _offset);
    } catch (_) {}
  }

  /// A fresh heading: remember it, turn the arrow over the dot to it, and in
  /// heading-up mode turn the map so the heading is up.
  void _onHeading(double h) {
    if (_heading == h || !mounted) return;
    setState(() => _heading = h);
    if (_headingUp && _ready) _face(h);
    if (driverMapDiagnosticsEnabled) {
      driverMapLive
        ..headingDeg = h
        ..touch();
      _diagRecord(DriverMapEventKind.heading, headingDeg: h);
    }
  }

  // ---- Debug-only diagnostics (gated by driverMapDiagnosticsEnabled) --------

  void _diagRefChanged() {
    if (mounted) setState(() {});
  }

  double? _safeZoom() {
    try {
      return _map.camera.zoom;
    } catch (_) {
      return null;
    }
  }

  /// Append one event, stamping the monotonic clock, UTC wall clock and the
  /// current follow state so callers pass only what is special to the event.
  void _diagRecord(
    DriverMapEventKind kind, {
    bool? gesture,
    double? zoom,
    double? headingDeg,
    double? gpsLat,
    double? gpsLng,
  }) {
    driverMapLog.record(DriverMapEvent(
      kind: kind,
      elapsedMs: driverMapLog.elapsedMs,
      timestampUtc: DateTime.now().toUtc(),
      follow: _follow,
      gesture: gesture,
      zoom: zoom,
      headingDeg: headingDeg,
      gpsLat: gpsLat,
      gpsLng: gpsLng,
    ));
  }

  int? _lastCamSampleMs;

  /// Sample the live camera at ~10 Hz (never per frame) while it moves.
  void _diagSampleCamera({required bool animating}) {
    final now = driverMapLog.elapsedMs;
    if (!shouldSampleCamera(_lastCamSampleMs, now)) return;
    _lastCamSampleMs = now;
    final MapCamera cam;
    try {
      cam = _map.camera;
    } catch (_) {
      return;
    }
    driverMapLive
      ..cameraZoom = cam.zoom
      ..cameraRotationDeg = cam.rotation
      ..animationActive = animating
      ..touch();
    driverMapLog.record(DriverMapEvent(
      kind: DriverMapEventKind.cameraSample,
      elapsedMs: now,
      timestampUtc: DateTime.now().toUtc(),
      follow: _follow,
      animationActive: animating,
      zoom: cam.zoom,
      rotationDeg: cam.rotation,
      cameraLat: cam.center.latitude,
      cameraLng: cam.center.longitude,
    ));
  }

  DriverMapProvider? _diagProvider;
  bool _diagTouchScheduled = false;

  /// Refresh the overlay's live fields from this frame and log a
  /// `provider_changed` when the base map (or satellite) flips. Updates fields
  /// in build but defers the notifier bump to after the frame, so the overlay
  /// is never marked dirty mid-build.
  void _diagUpdate(BuildContext context, {required bool satellite, required LatLng? me}) {
    final provider = appleRouteBaseActive(context, satellite: satellite)
        ? DriverMapProvider.appleNative
        : googleNativeBaseActive(context, satellite: satellite)
            ? DriverMapProvider.googleNative
            : DriverMapProvider.flutterTiles;
    final nativeBase = provider != DriverMapProvider.flutterTiles;
    final hasFix = me != null;
    final dot = expectedDotRenderer(provider: provider, nativeMe: true, hasFix: hasFix);
    final flutterDotVisible = hasFix && !nativeBase;
    final nativeDotVisible = hasFix && nativeBase;
    // On a flutter tile base the dot is a flutter_map marker drawn with the same
    // projection as this computation, so the pixel error is ~0. On a native
    // base the SDK's dot position is not exposed, so pixel error is N/A (null).
    Offset? expectedPx;
    double? errPx;
    if (me != null && !nativeBase && _ready) {
      try {
        expectedPx = _map.camera.latLngToScreenOffset(me);
        errPx = 0;
      } catch (_) {}
    }
    driverMapLive
      ..provider = provider
      ..satellite = satellite
      ..mapReady = _ready
      ..follow = _follow
      ..dotRenderer = dot
      ..duplicateDotWarning = duplicateDot(nativeDotVisible: nativeDotVisible, flutterDotVisible: flutterDotVisible)
      ..errorPx = errPx;
    // Both the live-field notifier bump and the provider_changed record are
    // deferred to after this frame, so nothing is marked dirty mid-build.
    final providerChanged = _diagProvider != provider;
    _diagProvider = provider;
    if (!_diagTouchScheduled || providerChanged) {
      _diagTouchScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _diagTouchScheduled = false;
        if (!mounted) return;
        if (providerChanged) {
          driverMapLog.record(DriverMapEvent(
            kind: DriverMapEventKind.providerChanged,
            elapsedMs: driverMapLog.elapsedMs,
            timestampUtc: DateTime.now().toUtc(),
            follow: _follow,
            provider: provider,
            dotRenderer: dot,
            expectedDotPx: expectedPx,
            measuredDotPx: expectedPx,
            errorPx: errPx,
            notes: satellite ? 'satellite' : null,
          ));
        }
        driverMapLive.touch();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me, requests = widget.requests, onSelect = widget.onSelect;
    final heading = _heading;
    final t = Theme.of(context);
    // The device heading turns the arrow over the driver's dot, and in
    // heading-up mode turns the map. Only this map listens, so the sensor runs
    // while the driver waits and stops when they leave.
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
    final satellite = ref.watch(mapSatelliteProvider);
    if (driverMapDiagnosticsEnabled) _diagUpdate(context, satellite: satellite, me: me);
    final map = RideMap(
      controller: _map,
      // This map draws no location dot: the heading arrow (below) is the single
      // location indicator, so a native/flutter dot underneath would be a
      // double. `me` is still given for the opening camera; `showMeDot: false`
      // suppresses every dot.
      me: me,
      nativeMe: true,
      showMeDot: false,
      pointZoom: driverHomeZoom,
      // The camera follows the driver instead of framing the pins.
      autoFit: false,
      // The idle home map turns freely: two fingers rotate it (a gesture stops
      // the following; the compass button straightens it, the locate button
      // cycles north-up / heading-up).
      rotate: true,
      onGesture: _onGesture,
      onReady: () {
        _ready = true;
        _center(jump: true);
        _face(_headingUp ? _heading : null);
        if (driverMapDiagnosticsEnabled) _diagRecord(DriverMapEventKind.mapReady);
      },
      satellite: satellite,
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
        // Debug-only fixed reference marker: a magenta crosshair locked to a
        // chosen coordinate, so a tester can tell GPS wander (the blue dot
        // moving) from projection drift (this marker sliding off its feature).
        if (driverMapDiagnosticsEnabled && driverMapReference.value != null)
          Marker(
            point: LatLng(driverMapReference.value!.lat, driverMapReference.value!.lng),
            width: 44,
            height: 44,
            child: const IgnorePointer(child: _DiagReferenceMark(key: ValueKey('driver-map-diag-ref-mark'))),
          ),
      ],
    );
    return Stack(
      children: [
        map,
        // The heading arrow over the location dot, anchored to the driver's real
        // position so it stays on the dot while the map is panned, not only
        // while following. It projects the coordinate to the screen on each map
        // movement and turns to the heading relative to the map's rotation, so
        // heading-up keeps it pointing up. The native base draws the dot itself;
        // a small drift from it is possible when panned far / zoomed out.
        if (me != null && heading != null)
          _DriverLocationArrow(
            key: const ValueKey('driver-heading-arrow'),
            controller: _map,
            me: me,
            heading: heading,
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
              // The compass: only once the map is turned away from north. Tap to
              // straighten it (and leave heading-up).
              if (_bearing.abs() > 0.5) ...[
                CompassButton(bearing: _bearing, onPressed: _onCompass),
                const SizedBox(height: 8),
              ],
              // Traffic (when configured), then map view above the locate button.
              const TrafficButton(),
              const MapTypeButton(),
              const SizedBox(height: 8),
              // The locate button cycles recenter north-up → heading-up.
              RecenterButton(onPressed: me == null ? null : _onLocate, headingUp: _headingUp),
            ]),
          ),
        ),
        // Debug-only diagnostic overlay (opt-in; never in a release build).
        if (driverMapDiagnosticsEnabled) const DriverMapDiagnosticsOverlay(),
      ],
    );
  }
}

/// The driver's heading arrow, anchored to their real position so it stays on
/// the location dot while the map is panned, not only while following. It
/// projects the coordinate to the screen on every map movement and turns the
/// arrow to the heading relative to the map's current rotation — so heading-up
/// (the map turned to the heading) keeps it pointing up, and north-up turns it
/// to the heading. The native base draws the dot itself; a small drift from it
/// is possible when panned far / zoomed out (that is the accepted trade for
/// keeping the arrow anchored, like Apple Maps).
class _DriverLocationArrow extends StatefulWidget {
  const _DriverLocationArrow({super.key, required this.controller, required this.me, required this.heading});

  final MapController controller;
  final LatLng me;

  /// The device heading in degrees (0 = north).
  final double heading;

  @override
  State<_DriverLocationArrow> createState() => _DriverLocationArrowState();
}

class _DriverLocationArrowState extends State<_DriverLocationArrow> {
  StreamSubscription<MapEvent>? _sub;

  @override
  void initState() {
    super.initState();
    // Reposition on every map movement (pan, zoom, rotate), so the arrow tracks
    // the dot even when the map is not following the driver.
    _sub = widget.controller.mapEventStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Offset at;
    final double bearing;
    try {
      final camera = widget.controller.camera;
      at = camera.latLngToScreenOffset(widget.me);
      bearing = camera.rotation;
    } catch (_) {
      return const SizedBox.shrink();
    }
    // The chevron is drawn in a 96×96 box centred on it, so place the box so its
    // centre sits on the dot.
    return Positioned(
      left: at.dx - 48,
      top: at.dy - 48,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: (widget.heading + bearing) * math.pi / 180,
          child: const _HeadingArrow(),
        ),
      ),
    );
  }
}

/// The heading arrow itself: a soft beam fanning up from the dot with a crisp
/// chevron, drawn pointing straight up (the caller turns it). The native map
/// draws the blue dot underneath; this only shows the direction.
class _HeadingArrow extends StatelessWidget {
  const _HeadingArrow();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(96, 96), painter: _HeadingArrowPainter());
  }
}

class _HeadingArrowPainter extends CustomPainter {
  // iOS location blue.
  static const _blue = Color(0xFF1A73E8);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    const reach = 42.0; // how far the beam fans up from the dot
    const half = 0.55; // half-angle of the beam, radians (~32°)
    const up = -math.pi / 2; // straight up

    // The beam: a wedge opening upward from the dot, brightest at the dot and
    // fading to nothing at its reach, with feathered edges.
    final wedge = ui.Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: reach), up - half, half * 2, false)
      ..close();
    canvas.drawPath(
      wedge,
      Paint()
        ..shader = RadialGradient(
          colors: [_blue.withValues(alpha: 0.5), _blue.withValues(alpha: 0.0)],
        ).createShader(Rect.fromCircle(center: c, radius: reach))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // A crisp chevron at the dot pointing up, white-outlined for contrast.
    final head = ui.Path()
      ..moveTo(c.dx, c.dy - 15) // tip
      ..lineTo(c.dx - 9, c.dy + 6) // left
      ..lineTo(c.dx, c.dy + 1) // notch
      ..lineTo(c.dx + 9, c.dy + 6) // right
      ..close();
    canvas.drawPath(
      head,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(head, Paint()..color = _blue);
  }

  @override
  bool shouldRepaint(_HeadingArrowPainter oldDelegate) => false;
}

/// Debug-only fixed reference marker (see [DriverMapReference]). A magenta
/// crosshair ring, visibly distinct from the blue location dot, locked to one
/// geographic coordinate so a tester can separate GPS wander from projection
/// drift. Never shown in a release build.
class _DiagReferenceMark extends StatelessWidget {
  const _DiagReferenceMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x33FF00FF),
        border: Border.all(color: const Color(0xFFFF00FF), width: 3),
      ),
      child: const Center(child: Icon(Icons.add, color: Color(0xFFFF00FF), size: 18)),
    );
  }
}
