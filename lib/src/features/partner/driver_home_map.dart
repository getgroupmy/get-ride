import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/follow_motion.dart';
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

// The follow's arithmetic lives in core/follow_motion.dart (the rider's home map
// draws its dot with it too); it is still reached through this file.
export '../../core/follow_motion.dart';

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
    this.fixTime,
    this.accuracyMetres,
  });

  final LatLng? me;

  /// The GPS velocity vector reported with the latest fix: ground speed (m/s)
  /// and course (bearing of travel, degrees), or null when the chip gives none.
  /// The map carries the fix forward by them to where the driver is now —
  /// cleaner than reconstructing them from how the fix moved.
  final double? speedMps;
  final double? courseDeg;

  /// When the GPS took the latest fix. The time between two fixes turns the
  /// change in their speeds into the braking or acceleration the fix is carried
  /// forward with; null where the platform gives none.
  final DateTime? fixTime;

  /// How far out the latest fix may be, by the GPS's own estimate (metres);
  /// null when it gives none. A parked car's dot is not moved by a fix it
  /// already sits inside ([settledFix]).
  final double? accuracyMetres;

  /// The requests to pin (those on the driver's queue).
  final List<RideRequest> requests;
  final void Function(RideRequest)? onSelect;

  @override
  ConsumerState<DriverHomeMap> createState() => _DriverHomeMapState();
}

/// The clock a fix's arrival is timed by ([fixLateness]); overridden in tests.
final driverMapClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

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

  /// The map's current rotation in degrees (0 = north-up), kept from the map's
  /// own events for the compass button. A notifier of its own, so a map turning
  /// through a bend redraws the button and not this whole widget every frame.
  final _bearing = ValueNotifier<double>(0);
  StreamSubscription<MapEvent>? _mapEvents;

  /// The device heading (the GPS course while moving, the compass while stopped;
  /// data/compass.dart), null until a sensor answers. It is what the cone points
  /// along while the driver is parked; on the move the follow works the heading
  /// out itself, a frame at a time ([_headingNow]).
  double? _heading;

  // ---- The follow ---------------------------------------------------------
  //
  // Where the driver is, a frame at a time, is worked out by [FixFollower]
  // (core/follow_motion.dart, which says why): the latest fix carried forward
  // by the GPS's own speed and course for as long as it is old, the drawn point
  // eased onto that. Here the camera is put on the drawn point every frame. The
  // heading is the one thing not guessed ahead: the cone, and the map in
  // heading-up, turn steadily from one fix's course to the next
  // ([headingBetween]). The zoom and where on screen the dot is held are eased
  // too. Nothing waits for a fix.

  /// Runs a frame at a time while there is something to move, and stops when
  /// the driver is parked and everything has settled.
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  /// The latest fix, carried forward a frame at a time.
  final _follower = FixFollower();

  /// The turn the latest fix asked for, while the driver is on the move: from
  /// the heading that was showing when it came in ([_turnFrom]) to its course,
  /// spread over [_turnOver] seconds ([headingBetween]). Null while parked or
  /// without a course: the phone's own heading is used then.
  double? _turnFrom;
  double _turnOver = 1;

  /// The heading the cone is drawn at, a frame at a time: the way the driver is
  /// travelling while on the move, where the phone points while parked; null
  /// until either is known. In heading-up the map is turned to the same heading
  /// by the same ease, so the cone keeps pointing up the screen through a bend.
  final _facing = ValueNotifier<double?>(null);

  /// Where the driver is drawn: the camera's target and the dot's position,
  /// one point for both, so the dot never leaves its place on the screen.
  final _shown = ValueNotifier<LatLng?>(null);

  /// Where on screen the dot is held (see [_offset]), eased so that switching
  /// between north-up and heading-up slides it there.
  Offset? _heldOffset;

  /// Whether the driver is moving: the map then turns to the heading and pulls
  /// in to [driverDrivingZoom]. From the GPS speed, smoothed and held by
  /// [nextMoving].
  bool _moving = false;
  double? _speedEma; // smoothed speed, m/s

  /// The live traffic tiles over the map, and the source they were made for.
  List<Widget> _overlays = const [];
  (String?, bool, String?)? _trafficFor;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // Keep the compass button turned to the map: watch the camera's rotation.
    _mapEvents = _map.mapEventStream.listen((_) {
      if (!mounted) return;
      try {
        _bearing.value = _map.camera.rotation;
      } catch (_) {}
    });
    final me = widget.me;
    if (me != null) _takeFix(me, building: true);
    // Debug-only: redraw when the tester locks/clears the diagnostic reference
    // marker (its button lives in the overlay, not this widget).
    if (driverMapDiagnosticsEnabled) driverMapReference.addListener(_diagRefChanged);
  }

  @override
  void dispose() {
    _mapEvents?.cancel();
    if (driverMapDiagnosticsEnabled) driverMapReference.removeListener(_diagRefChanged);
    _ticker.dispose();
    _shown.dispose();
    _facing.dispose();
    _bearing.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DriverHomeMap old) {
    super.didUpdateWidget(old);
    final me = widget.me;
    // A new fix: somewhere new, or the same place a moment later or with a new
    // speed or course (a car that has just pulled up reports the same spot at
    // 0 m/s).
    if (me != null &&
        (me != old.me ||
            widget.fixTime != old.fixTime ||
            widget.speedMps != old.speedMps ||
            widget.courseDeg != old.courseDeg ||
            widget.accuracyMetres != old.accuracyMetres)) {
      _takeFix(me);
      if (driverMapDiagnosticsEnabled && me != old.me) {
        driverMapNoteRawFix(me.latitude, me.longitude);
        _diagRecord(DriverMapEventKind.gpsFix, gpsLat: me.latitude, gpsLng: me.longitude);
      }
    }
  }

  /// A fix has come in: what the follow carries forward from now on ([_onTick]).
  /// [building] in initState, where there is nothing to rebuild yet.
  void _takeFix(LatLng me, {bool building = false}) {
    // The heading as it stands, read before the fix is taken: the turn to the
    // new course carries on from wherever the last one had got to.
    final headingWas = _headingNow;
    final taken = _follower.take(
      me,
      speed: widget.speedMps,
      course: widget.courseDeg,
      time: widget.fixTime,
      accuracy: widget.accuracyMetres,
      clock: ref.read(driverMapClockProvider),
    );
    if (taken == null) return; // from before the one in hand: not news
    final speed = taken.speed, course = taken.course;
    // The heading on the move: turned from where it stood to this fix's course
    // over the time fixes are coming at. Only at a speed where the course means
    // the direction of travel (as data/compass.dart has it); slower than that,
    // the phone's own heading stands.
    final travelling = course != null && (speed ?? 0) >= movingSpeed;
    _turnFrom = travelling ? (_turnFrom == null ? course : headingWas ?? course) : null;
    _turnOver = (taken.gap ?? 1).clamp(followTurnOverLeast, followTurnOverMost).toDouble();
    _shown.value = _follower.shown;
    if (speed != null) {
      // Smoothed, so one odd reading cannot flip moving / stopped.
      final smoothed = _speedEma = _speedEma == null ? speed : _speedEma! * 0.6 + speed * 0.4;
      final wasMoving = _moving;
      _moving = nextMoving(moving: _moving, speed: smoothed);
      // Starting to drive turns the map so the way they are going points up
      // (heading-up), like Apple/Google/Waze navigation. It is not un-done when
      // they stop (the map stays at that orientation, no snap back to north);
      // tapping the compass straightens it, and a manual north-up resumes
      // heading-up only on the next stop → start.
      if (_moving && !wasMoving && !_headingMode) {
        if (building) {
          _headingMode = true;
        } else {
          setState(() => _headingMode = true);
        }
      }
    }
    _wake();
  }

  /// The way the driver is heading at this moment: on the move, the turn the
  /// latest fix asked for as far as it has got ([headingBetween]); parked, where
  /// the phone points ([_heading]). Null until either is known.
  double? get _headingNow {
    final from = _turnFrom, to = _follower.course;
    if (from == null || to == null) return _heading;
    return headingBetween(from, to, ageSeconds: _follower.ageSeconds, overSeconds: _turnOver);
  }

  /// Starts the follow's frames if they are not already running.
  void _wake() {
    if (!mounted || _ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  /// One frame of the follow: where the driver is now, the drawn point eased
  /// onto it, and the camera put there (see the note above [_ticker]).
  void _onTick(Duration elapsed) {
    // A long frame (a hitch, the app coming back) is not that much travel.
    final dt = math.min((elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond, 0.25);
    _lastTick = elapsed;
    if (!mounted || !_follower.hasFix) {
      _ticker.stop();
      return;
    }
    var busy = _follower.advance(dt);
    final shown = _follower.shown!;
    _shown.value = shown;

    // The way they are heading now, and the cone eased round to it.
    final heading = _headingNow;
    final faced = _facing.value;
    if (heading == null || faced == null) {
      _facing.value = heading;
    } else {
      final turn = shortestTurn(faced, heading);
      final settled = turn.abs() < 0.05;
      _facing.value = settled ? heading : (faced + turnStep(turn, dt) + 360) % 360;
      busy = busy || !settled;
    }

    if (_follow && _ready) {
      try {
        final camera = _map.camera;
        // Heading-up: the map turns to the heading while driving, by the same
        // ease as the cone, so a bend is one steady sweep and the cone keeps
        // pointing up the screen through it. A parked phone never turns the map
        // (the compass would spin it as the phone is held).
        if (_headingMode && _moving && _heading != null && heading != null) {
          final turn = shortestTurn(camera.rotation, -heading);
          if (turn != 0) {
            final settled = turn.abs() < 0.05;
            _map.rotate(shortestTurn(0, camera.rotation + (settled ? turn : turnStep(turn, dt))));
            busy = busy || !settled;
          }
        }
        // While moving, pull in to the driving zoom (never sit more zoomed-out
        // than it); a driver who has zoomed further in stays there. While
        // stopped the zoom is theirs, so they can look around.
        var zoom = camera.zoom;
        if (_moving && zoom < driverDrivingZoom) {
          final short = driverDrivingZoom - zoom;
          final settled = short < 0.01;
          zoom = settled ? driverDrivingZoom : zoom + short * easeFraction(dt, followZoomSeconds);
          busy = busy || !settled;
        }
        // Where on screen the dot is held: slid there when it changes (centre
        // in heading-up, above the sheet otherwise), not jumped.
        final wanted = _offset;
        var held = _heldOffset ?? wanted;
        if (held != wanted) {
          final slide = wanted - held;
          final settled = slide.distance < 0.5;
          held = settled ? wanted : held + slide * easeFraction(dt, followTurnSeconds);
          busy = busy || !settled;
        }
        _heldOffset = held;
        _map.move(shown, zoom, offset: held);
      } catch (_) {}
    }
    if (driverMapDiagnosticsEnabled) _diagSampleCamera(animating: busy);
    if (!busy) _ticker.stop();
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

  /// Puts the camera on the driver at once, at the zoom the map is at: the map
  /// has just come up, or the driver asked for it (locate, compass). The follow
  /// ([_onTick]) keeps it there from then on.
  void _snapCamera() {
    final at = _shown.value ?? widget.me;
    if (!mounted || !_follow || !_ready || at == null) return;
    try {
      final held = _heldOffset = _offset;
      _map.move(at, _map.camera.zoom, offset: held);
    } catch (_) {}
  }

  /// A hand on the map: stop following until the recenter button. The dot keeps
  /// moving with the driver; only the camera is let go.
  void _onGesture() {
    if (!_follow) return;
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
    if (driverMapDiagnosticsEnabled) {
      driverMapLive
        ..gesture = false
        ..follow = _follow
        ..touch();
      _diagRecord(DriverMapEventKind.recenterTap, zoom: _safeZoom());
      _diagRecord(DriverMapEventKind.followChanged);
    }
    if (widget.me == null) return;
    // Resume at the zoom the driver left the map at, not back at street level,
    // and orient it: heading-up turns to the heading, north-up straightens.
    _snapCamera();
    _face(_headingUp ? _headingNow : null);
    _wake();
  }

  /// The compass button: snap back to north-up and leave heading-up mode, but
  /// keep following. Shown only once the map is turned away from north.
  void _onCompass() {
    setState(() => _headingMode = false);
    _face(null);
    _snapCamera();
  }

  /// A fresh heading from the phone: remember it and let the follow ease the
  /// cone round to it ([_onTick]) — and, driving heading-up, the map. A parked
  /// phone never turns the map, so it stays at its last heading when stopped.
  void _onHeading(double h) {
    if (_heading == h || !mounted) return;
    // Only the first heading changes what this widget builds (heading-up
    // becomes possible); after that the cone turns without rebuilding the map.
    final was = _headingUp;
    _heading = h;
    if (_headingUp != was) setState(() {});
    _wake();
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
    final t = Theme.of(context);
    // The device heading turns the cone over the driver's dot while they are
    // parked, and says the map may turn heading-up. Only this map listens, so
    // the sensor runs while the driver waits and stops when they leave.
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
        _snapCamera();
        _face(_headingUp ? _headingNow : null);
        _wake();
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
        // at the follow's own point — the same point the camera is put on each
        // frame — so the dot holds its place on the screen while the map moves
        // under it, and the cone is always welded to the dot. The dot shows
        // whenever there is a fix; the cone is added once there is a heading,
        // turned to it relative to the map's rotation so heading-up keeps it
        // pointing up.
        if (me != null)
          _DriverLocationArrow(
            key: const ValueKey('driver-heading-arrow'),
            controller: _map,
            position: _shown,
            heading: _facing,
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
              // straighten it (and leave heading-up). It listens to the map's
              // rotation itself, so a map turning with the road redraws this
              // button alone.
              ValueListenableBuilder<double>(
                valueListenable: _bearing,
                builder: (_, bearing, _) => bearing.abs() > 0.5
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: CompassButton(bearing: bearing, onPressed: _onCompass),
                      )
                    : const SizedBox.shrink(),
              ),
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

/// The driver's location dot and heading cone, drawn at the follow's own point
/// ([position]: where the driver is now, a frame at a time). It projects that
/// point to the screen on every frame of the follow and on every map movement,
/// so it holds its place while the map follows and stays on the driver while
/// the map is panned away; the cone turns to the heading relative to the map's
/// rotation — so heading-up (the map turned to the heading) keeps it pointing
/// up, and north-up turns it to the heading.
class _DriverLocationArrow extends StatefulWidget {
  const _DriverLocationArrow({super.key, required this.controller, required this.position, required this.heading});

  final MapController controller;

  /// Where the driver is drawn; null until the first fix.
  final ValueListenable<LatLng?> position;

  /// The heading to draw the cone at, in degrees (0 = north), a frame at a time
  /// like [position]; null when there is none yet — then only the dot is drawn,
  /// with no direction cone.
  final ValueListenable<double?> heading;

  @override
  State<_DriverLocationArrow> createState() => _DriverLocationArrowState();
}

class _DriverLocationArrowState extends State<_DriverLocationArrow> {
  StreamSubscription<MapEvent>? _sub;

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_redraw);
    widget.heading.addListener(_redraw);
    // Reposition on every map movement (pan, zoom, rotate), so the dot tracks
    // its spot even when the map is not following the driver.
    _sub = widget.controller.mapEventStream.listen((_) => _redraw());
  }

  @override
  void didUpdateWidget(covariant _DriverLocationArrow old) {
    super.didUpdateWidget(old);
    if (widget.position != old.position) {
      old.position.removeListener(_redraw);
      widget.position.addListener(_redraw);
    }
    if (widget.heading != old.heading) {
      old.heading.removeListener(_redraw);
      widget.heading.addListener(_redraw);
    }
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.position.removeListener(_redraw);
    widget.heading.removeListener(_redraw);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final where = widget.position.value;
    if (where == null) return const SizedBox.shrink();
    final Offset at;
    final double bearing;
    try {
      final camera = widget.controller.camera;
      at = camera.latLngToScreenOffset(where);
      bearing = camera.rotation;
    } catch (_) {
      return const SizedBox.shrink();
    }
    // The dot and cone are drawn in a 96×96 box centred on the projected
    // position. The whole box turns to the heading relative to the map's
    // rotation (the dot is round, so only the cone turns visibly); with no
    // heading the box is upright and only the dot is drawn.
    final heading = widget.heading.value;
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
