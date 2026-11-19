import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/compass.dart';
import '../../data/models.dart';
import '../../widgets/map_brightness.dart' show mapIsDark;
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
  const DriverHomeMap({
    super.key,
    required this.me,
    required this.requests,
    this.onSelect,
    this.speedMps,
    this.courseDeg,
  });

  final LatLng? me;

  /// The GPS velocity vector reported with the latest fix: ground speed (m/s)
  /// and course (bearing of travel, degrees), or null when the chip gives none.
  /// Used for dead reckoning and moving/stopped — cleaner than reconstructing
  /// them from how the fix moved.
  final double? speedMps;
  final double? courseDeg;

  /// The requests to pin (those on the driver's queue).
  final List<RideRequest> requests;
  final void Function(RideRequest)? onSelect;

  @override
  ConsumerState<DriverHomeMap> createState() => _DriverHomeMapState();
}

/// Street level: the roads and buildings around the driver.
const driverHomeZoom = 18.0;

/// The zoom the map pulls in to while the driver is moving — a navigation
/// level, like Apple/Google Maps when driving. The follow never sits more
/// zoomed-out than this while moving (it still allows zooming further in);
/// while stopped the zoom is left as the driver set it, so they can look
/// around.
const driverDrivingZoom = 18.0;

/// Whether the driver counts as moving, with hysteresis so a noisy GPS fix
/// near the threshold does not flip it: once moving it stays moving until the
/// speed drops below [exit] m/s, and only becomes moving again above [enter]
/// m/s. Pure; see test/driver_home_map_test.dart.
bool nextMoving({required bool moving, required double speed, double enter = 2.5, double exit = 1.0}) =>
    moving ? speed >= exit : speed >= enter;

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

  /// The camera's glide from where it is to the driver. Short, so following
  /// stays close to real time (a longer glide trailed the driver); still long
  /// enough to smooth the step between fixes. The dot overlay eases over the
  /// same time so the two move together.
  late final _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 400))
    ..addListener(_glideTick);
  LatLng? _from, _to;
  double _zoom = driverHomeZoom;
  double _zoomFrom = driverHomeZoom; // zoom at the start of the current glide

  /// Whether the driver is moving, so the map pulls in to [driverDrivingZoom].
  /// Derived from how far the fix moved between updates (no extra GPS stream),
  /// smoothed and held by [nextMoving].
  bool _moving = false;
  double? _speedEma; // smoothed speed, m/s
  LatLng? _lastFix;
  int? _lastFixMs;
  int _fixIntervalMs = 500; // smoothed gap between fixes
  int _followMs = 500; // how long the follow glide runs (a touch over the gap)
  LatLng? _displayTarget; // the fix projected forward (dead reckoning), or the fix

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
      _updateMoving(widget.me);
      final me = widget.me;
      // Project the fix forward along the speed and heading, so the dot sits
      // near where the driver actually is now instead of trailing the last
      // (already ~1 s old) fix. Recomputed only on a fix, so a heading-only
      // rebuild does not nudge the target.
      _displayTarget = me == null ? null : _leadTarget(me);
      WidgetsBinding.instance.addPostFrameCallback((_) => _center());
      if (driverMapDiagnosticsEnabled && me != null) {
        driverMapNoteRawFix(me.latitude, me.longitude);
        _diagRecord(DriverMapEventKind.gpsFix, gpsLat: me.latitude, gpsLng: me.longitude);
      }
    }
  }

  /// Update whether the driver is moving from how far this fix is from the last
  /// and how long since, smoothing the speed so GPS noise at a standstill does
  /// not read as movement. The map pulls in to the driving zoom while moving.
  void _updateMoving(LatLng? me) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastFix, lastMs = _lastFixMs;
    _lastFix = me;
    _lastFixMs = now;
    if (me == null || last == null || lastMs == null) return;
    final dt = (now - lastMs) / 1000.0;
    // Ignore a zero/near-zero gap (two fixes in the same tick) and a long gap
    // (app resumed) — neither is a trustworthy speed.
    if (dt < 0.1 || dt > 10) return;
    // Prefer the GPS velocity the chip measured (Doppler, clean even at a
    // crawl) over reconstructing speed from how far the fix moved.
    final speed = widget.speedMps ?? const Distance().as(LengthUnit.Meter, last, me) / dt;
    // Exponential smoothing, so one noisy fix cannot flip the state.
    _speedEma = _speedEma == null ? speed : _speedEma! * 0.6 + speed * 0.4;
    // Track the gap between fixes so the follow can glide for about that long
    // (a touch over it): the dot then moves at a steady speed between fixes and
    // arrives as the next lands, like a nav app, instead of easing to each fix
    // and pausing (which read as lag at ~1 fix/second).
    _fixIntervalMs = (_fixIntervalMs * 0.6 + (now - lastMs) * 0.4).round();
    final wasMoving = _moving;
    _moving = nextMoving(moving: _moving, speed: _speedEma!);
    // Starting to drive turns the map so the way they are going points up
    // (heading-up), like Apple/Google/Waze navigation. It is not un-done when
    // they stop (the map freezes at that orientation, no snap back to north);
    // tapping the compass straightens it, and a manual north-up resumes
    // heading-up only on the next stop → start.
    if (_moving && !wasMoving && !_headingMode) {
      setState(() => _headingMode = true);
      // Turn to the travel heading now rather than waiting for the next update.
      final h = _heading;
      if (h != null) WidgetsBinding.instance.addPostFrameCallback((_) => _faceWhileDriving(h));
    }
  }

  /// Turn the map to heading [h] only while actually driving in heading-up — a
  /// parked phone must not spin the map to wherever it happens to face.
  void _faceWhileDriving(double h) {
    if (mounted && _headingUp && _ready && _moving) _face(h);
  }

  /// The fix [me] projected forward along the current speed and heading, so the
  /// followed point is near where the driver is *now* rather than trailing the
  /// last fix — the dead reckoning every nav app does. Only while moving; the
  /// lead is capped in both time and distance so it never shoots far ahead on a
  /// bend or a sudden stop.
  LatLng _leadTarget(LatLng me) {
    // Lead along the GPS course when the chip gives one (measured bearing of
    // travel), else the blended heading; by speed, preferring the GPS speed.
    final sp = widget.speedMps ?? _speedEma;
    final course = widget.courseDeg ?? _heading;
    if (!_moving || sp == null || course == null || sp < 1.0) return me;
    final leadSec = (_followMs / 1000.0 * 0.8 + 0.3).clamp(0.3, 1.2).toDouble();
    final dist = (sp * leadSec).clamp(0.0, 40.0).toDouble();
    return const Distance().offset(me, dist, course);
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
    // While moving, pull in to the driving zoom (never sit more zoomed-out than
    // it); allow a driver who has zoomed further in to stay there. While
    // stopped, leave the zoom as they set it so they can look around.
    _zoomFrom = camera.zoom;
    _zoom = _moving ? math.max(camera.zoom, driverDrivingZoom) : camera.zoom;
    if (jump) {
      _map.move(me, _zoom, offset: _offset);
      return;
    }
    // Start the glide from where the camera actually is now, not from the last
    // glide's destination (_to): a fresh fix often lands before the glide
    // has finished, and starting at the old target snapped the camera
    // forward to it before interpolating (the jitter while following). With
    // the live centre each restart continues smoothly from the visible spot.
    _from = camera.center;
    // Glide to the projected point (dead reckoning), not the stale fix, so the
    // follow keeps up with the driver instead of trailing a beat behind.
    _to = _displayTarget ?? me;
    // Glide roughly over the gap between fixes, so a fresh fix lands about when
    // the glide ends and the motion stays continuous without trailing far.
    _followMs = (_fixIntervalMs * 1.1).round().clamp(250, 1400);
    _glide.duration = Duration(milliseconds: _followMs);
    _glide.forward(from: 0);
  }

  void _glideTick() {
    final a = _from, b = _to;
    if (a == null || b == null || !mounted) return;
    // Linear: a steady-speed glide between fixes (an ease curve crawled at the
    // start of each fix, which read as the lag/stutter).
    final t = _glide.value;
    try {
      _map.move(
        LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t),
        // Ease the zoom too, so a pull-in to the driving zoom glides rather
        // than snapping (usually a no-op: from and to are the same).
        _zoomFrom + (_zoom - _zoomFrom) * t,
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
    // Turn the map to the heading only while moving: in heading-up the map
    // follows the direction of travel, but a stationary phone must not spin it
    // to wherever it is held. When stopped the map stays at its last heading.
    if (_headingUp && _ready && _moving) _face(h);
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
      // The location dot is drawn by the heading overlay below, not by the map:
      // the overlay welds the dot and the heading cone into one unit so the two
      // can never drift apart. A separately-drawn native dot (continuous
      // CoreLocation) runs ahead of our fix during motion, so the cone trailed
      // it. showMeDot turns the map's own dot (native and flutter_map) off.
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
        // The location dot and its heading cone, drawn together as one overlay
        // anchored to the driver's real position: they project the same
        // coordinate to the screen on each map movement, so the cone is always
        // welded to the dot (a separately-drawn native dot ran ahead of it in
        // motion, detaching the cone). The dot shows whenever there is a fix;
        // the cone is added once there is a heading, turned to it relative to
        // the map's rotation so heading-up keeps it pointing up.
        if (me != null)
          _DriverLocationArrow(
            key: const ValueKey('driver-heading-arrow'),
            controller: _map,
            // The projected point the camera follows, so the dot sits where the
            // driver is now rather than on the stale fix.
            me: _displayTarget ?? me,
            heading: heading,
            followMs: _followMs,
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
  const _DriverLocationArrow({
    super.key,
    required this.controller,
    required this.me,
    required this.heading,
    required this.followMs,
  });

  final MapController controller;
  final LatLng me;

  /// The device heading in degrees (0 = north), or null when there is no
  /// sensor yet — then only the dot is drawn, with no direction cone.
  final double? heading;

  /// How long to glide to each new fix, in lockstep with the camera (the gap
  /// between fixes plus a little, so the dot moves at a steady speed).
  final int followMs;

  @override
  State<_DriverLocationArrow> createState() => _DriverLocationArrowState();
}

class _DriverLocationArrowState extends State<_DriverLocationArrow> with SingleTickerProviderStateMixin {
  StreamSubscription<MapEvent>? _sub;

  // The GPS stream delivers discrete fixes, so projecting the raw position made
  // the dot leap to each new fix (and then the camera glided to catch up — the
  // jumpy motion). Instead the drawn position glides from where the dot is to
  // each new fix at a steady speed over the gap between fixes, in lockstep with
  // the camera, so the two move together and the motion stays continuous like a
  // nav app rather than easing to each fix and pausing.
  late final AnimationController _glide =
      AnimationController(vsync: this, duration: Duration(milliseconds: widget.followMs))..addListener(_onGlide);
  LatLng _shown = const LatLng(0, 0); // the position actually drawn
  LatLng _from = const LatLng(0, 0); // where the current ease started

  @override
  void initState() {
    super.initState();
    _shown = widget.me;
    _from = widget.me;
    // Reposition on every map movement (pan, zoom, rotate), so the dot tracks
    // its spot even when the map is not following the driver.
    _sub = widget.controller.mapEventStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _DriverLocationArrow old) {
    super.didUpdateWidget(old);
    // A fresh fix: ease to it from where the dot visibly is now (not from the
    // last fix), so a fix landing mid-glide continues smoothly instead of
    // snapping — the same anti-snap the camera glide uses.
    if (widget.me != old.me) {
      _from = _shown;
      _glide.duration = Duration(milliseconds: widget.followMs);
      _glide.forward(from: 0);
    }
  }

  void _onGlide() {
    // Linear: a steady-speed glide between fixes, matching the camera.
    final t = _glide.value;
    _shown = LatLng(
      _from.latitude + (widget.me.latitude - _from.latitude) * t,
      _from.longitude + (widget.me.longitude - _from.longitude) * t,
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _glide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Offset at;
    final double bearing;
    try {
      final camera = widget.controller.camera;
      at = camera.latLngToScreenOffset(_shown);
      bearing = camera.rotation;
    } catch (_) {
      return const SizedBox.shrink();
    }
    // The dot and cone are drawn in a 96×96 box centred on the projected
    // position. The whole box turns to the heading relative to the map's
    // rotation (the dot is round, so only the cone turns visibly); with no
    // heading the box is upright and only the dot is drawn.
    final heading = widget.heading;
    // On a dark map the blue cone all but disappears, so draw it white there —
    // like Apple Maps' light heading beam in dark mode. The dot stays blue.
    final child = _HeadingArrow(cone: heading != null, dark: mapIsDark(context));
    final dot = heading == null
        ? child
        : Transform.rotate(angle: (heading + bearing) * math.pi / 180, child: child);
    // The overlay covers the whole map and the moving dot sits inside a
    // RepaintBoundary, so its per-fix repaints (and the dot's blurred shadow)
    // are isolated to their own layer: they no longer force the native map
    // (a platform view) underneath to re-composite, which flashed it on every
    // GPS update. The boundary also rasterises the dot once and just moves that
    // layer, rather than re-blurring it each frame.
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(left: at.dx - 48, top: at.dy - 48, child: dot),
            ],
          ),
        ),
      ),
    );
  }
}

/// The driver's location dot with Apple Maps' direction glow, drawn as one
/// unit: a blue dot (the same mark the map would draw) with a soft translucent
/// heading cone fanning from under it in the travel direction. Drawing both
/// here — rather than letting the native base draw the dot — welds the cone to
/// the dot so the two can never drift apart. The caller turns the whole thing
/// to the heading; [cone] is false before there is a heading (dot only).
class _HeadingArrow extends StatelessWidget {
  const _HeadingArrow({required this.cone, required this.dark});

  final bool cone;

  /// Whether the map is dark, so the cone is drawn white instead of blue.
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(96, 96), painter: _HeadingArrowPainter(cone: cone, dark: dark));
  }
}

class _HeadingArrowPainter extends CustomPainter {
  const _HeadingArrowPainter({required this.cone, required this.dark});

  /// Whether to draw the heading cone (false before there is a heading).
  final bool cone;

  /// A dark map: draw the cone white (the blue vanishes against dark tiles).
  final bool dark;

  // The iOS heading-cone blue (Apple draws this fan from the location dot).
  static const _blue = Color(0xFF0A84FF);
  // The location dot: a blue core inside a white ring, matching the dot the
  // rider/confirm maps draw (a 22 px marker: core radius 8, white ring 3).
  static const _coreRadius = 8.0;
  static const _ringRadius = 11.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);

    if (cone) {
      const reach = 42.0; // how far the cone fans out past the dot
      const half = 0.6; // half-angle of the cone, radians (~34°, ~69° total)
      const up = -math.pi / 2; // straight up (the caller turns it to the heading)
      // Apple Maps' heading cone: a soft translucent wedge opening in the
      // heading direction, brightest around the dot and fading to nothing at
      // its reach, with feathered edges. Drawn first, so the dot sits on top of
      // its root and the cone reads as coming from around the dot's edge.
      final coneColor = dark ? Colors.white : _blue;
      final wedge = ui.Path()
        ..moveTo(c.dx, c.dy)
        ..arcTo(Rect.fromCircle(center: c, radius: reach), up - half, half * 2, false)
        ..close();
      canvas.drawPath(
        wedge,
        Paint()
          ..shader = RadialGradient(
            colors: [coneColor.withValues(alpha: dark ? 0.7 : 0.6), coneColor.withValues(alpha: 0.0)],
          ).createShader(Rect.fromCircle(center: c, radius: reach))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }

    // The location dot, on top of the cone's root: soft shadow, white ring,
    // blue core — the same dot the map draws elsewhere, so nothing moved, but
    // now the cone is welded to it.
    canvas.drawCircle(
      c,
      _ringRadius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(c, _ringRadius, Paint()..color = Colors.white);
    canvas.drawCircle(c, _coreRadius, Paint()..color = _blue);
  }

  @override
  bool shouldRepaint(_HeadingArrowPainter oldDelegate) => oldDelegate.cone != cone || oldDelegate.dark != dark;
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
