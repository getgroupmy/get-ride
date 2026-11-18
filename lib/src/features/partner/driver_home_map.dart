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

  /// The device heading (the GPS course while moving, the compass while stopped;
  /// data/compass.dart), null until a sensor answers. The arrow on the location
  /// dot (below) turns to it. The map itself stays north-up.
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
    // Debug-only: redraw when the tester locks/clears the diagnostic reference
    // marker (its button lives in the overlay, not this widget).
    if (driverMapDiagnosticsEnabled) driverMapReference.addListener(_diagRefChanged);
  }

  @override
  void dispose() {
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

  /// Where the driver's dot sits on screen: a little above the sheet. The
  /// heading-arrow overlay (below) is placed over the same spot.
  Offset get _offset => Offset(0, -MapBottomInset.of(context) / 2);

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

  void _recenter() {
    setState(() => _follow = true);
    _glide.stop();
    _from = _to = null;
    if (driverMapDiagnosticsEnabled) {
      driverMapLive
        ..gesture = false
        ..follow = true
        ..touch();
      _diagRecord(DriverMapEventKind.recenterTap, zoom: _safeZoom());
      _diagRecord(DriverMapEventKind.followChanged);
    }
    final me = widget.me;
    if (me == null) return;
    try {
      // Resume following at the zoom the driver left the map at, not back at
      // street level — jumping the zoom on recentre is a surprise when they
      // had zoomed out to look around. The map is already north-up.
      _map.move(me, _map.camera.zoom, offset: _offset);
    } catch (_) {}
  }

  /// A fresh heading: remember it so the arrow on the dot turns to it. The map
  /// stays north-up — only the arrow moves.
  void _onHeading(double h) {
    if (_heading == h || !mounted) return;
    setState(() => _heading = h);
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
    // The device heading turns the arrow over the driver's dot (the map stays
    // north-up). Only this map listens, so the sensor runs while the driver
    // waits and stops when they leave.
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
      // The location dot is the map's own: the native base draws it (locked to
      // its tiles, continuously tracking), and a flutter_map dot elsewhere. The
      // heading arrow over it is a screen-fixed overlay (below), so it needs no
      // dot of its own here.
      me: me,
      nativeMe: true,
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
        // The heading arrow over the location dot: a chevron on the driver's
        // dot that turns to the way they face/drive. Drawn screen-fixed over the
        // dot's spot — while following, the dot sits at the map centre plus
        // [_offset] — so it never drifts off the native dot and its rotation is
        // a plain Transform (no map-rotation sign to get wrong). Clockwise from
        // north matches the heading, since the map is north-up. Hidden when
        // panned (the dot is no longer under this spot) or before a heading.
        if (_follow && heading != null && me != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Transform.translate(
                  offset: _offset,
                  child: Transform.rotate(
                    angle: heading * math.pi / 180,
                    child: const _HeadingArrow(key: ValueKey('driver-heading-arrow')),
                  ),
                ),
              ),
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
        // Debug-only diagnostic overlay (opt-in; never in a release build).
        if (driverMapDiagnosticsEnabled) const DriverMapDiagnosticsOverlay(),
      ],
    );
  }
}

/// The heading arrow over the driver's location dot: a soft beam fanning up
/// from the dot with a crisp chevron, pointing the way the driver faces/drives.
/// It is drawn pointing straight up and turned to the heading by a Transform in
/// the caller, so it pivots around the dot at its centre. The native map draws
/// the blue dot itself underneath; this only shows the direction.
class _HeadingArrow extends StatelessWidget {
  const _HeadingArrow({super.key});

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
