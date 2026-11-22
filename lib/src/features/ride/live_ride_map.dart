import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/car_playback.dart';
import '../../core/follow_motion.dart';
import '../../core/launch_destination.dart' show mapButtonsRightInset;
import '../../core/live_eta.dart';
import '../../core/trip_card.dart' show TripRouteFix;
import '../../core/ride_cancel.dart' show riderLocationForDriver;
import '../../core/ride_confirm.dart' show tripRecenterOffset;
import '../../data/app_display_repository.dart';
import '../../data/compass.dart' show movingSpeed;
import '../../data/geo_service.dart';
import '../../data/live_fix.dart';
import '../../providers.dart';
import '../../data/models.dart';
import '../../data/trip_card_controller.dart' show tripRouteFeedProvider;
import '../../widgets/map_brightness.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/radar_pulse.dart';
import '../../widgets/map_vehicle_icon.dart';
import '../../widgets/ride_map.dart';
import '../../widgets/road_info_layers.dart';

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

/// The rider's ride map (Expo `ride-tracking`): pickup, stops and drop-off,
/// plus — once a driver is on the way — the road still ahead of them, an
/// ETA chip and the car turned to the way it is heading.
///
/// Once there is a car the camera follows it at street zoom, so the turns
/// can be watched: turned to the car's heading on the driver's own phone
/// ([driverAt]), north up for the rider. Moving the map by hand stops the
/// following; the recenter button starts it again, and so does the first
/// new position once the map has been left alone for [followResumeAfter].
///
/// The car moves a frame at a time, and the camera with it. On the driver's
/// own phone it is where the phone's GPS puts it now, each fix carried forward
/// by its own speed and course (core/follow_motion.dart, as the driver's home
/// map). On the passenger's it is played back from the positions the driver's
/// phone sends every few seconds: driven from one to the next along the road,
/// a few seconds behind the real car, rather than hopped (core/car_playback.dart).
class LiveRideMap extends ConsumerStatefulWidget {
  const LiveRideMap({
    super.key,
    required this.ride,
    this.now,
    this.driverAt,
    this.driverHeading,
    this.driverFixes,
    this.partner = false,
    this.riderPosition,
    this.topButton,
  });

  /// The driver's own phone's fixes, every one with the speed and course the
  /// GPS measured, when this map is the driver's own: what its car and camera
  /// follow a frame at a time. Null (or a stream with nothing in it) follows
  /// [driverAt] as it changes instead.
  final Stream<LiveFix> Function()? driverFixes;

  /// A button over map type and recenter (the passenger's location
  /// sharing); it sizes itself, nothing when it has nothing to show.
  final Widget? topButton;

  /// The passenger's own phone fix, for their "you are here" dot while they
  /// wait ([showRiderDot]); null draws none (the driver's map).
  final Stream<LatLng> Function()? riderPosition;

  final RideRequest ride;

  /// The driver's trip map rather than the rider's: its recenter button
  /// takes Admin → Display's partner offsets instead of the rider's.
  final bool partner;

  /// Where the driver is when this map is the driver's own (their phone's
  /// fix, fresher than the published one); null reads the ride row. It is
  /// where the road ahead and the ETA are counted from; the car is drawn
  /// where [driverFixes] puts it, when that has anything to say.
  final LatLng? driverAt;
  final double? driverHeading;

  /// The clock; null is [DateTime.now]. For tests.
  final DateTime Function()? now;

  @override
  ConsumerState<LiveRideMap> createState() => _LiveRideMapState();
}

/// Street zoom the camera follows the car at.
const followZoom = 16.5;

/// Street level the map sits at on the pickup while a driver is being
/// found (inDrive's).
const searchingZoom = 17.0;

/// How long a hand on the map holds the camera still: the next position
/// that arrives after this recentres on the car again by itself.
const followResumeAfter = Duration(seconds: 10);

/// How long the camera takes to come onto the car when it starts following:
/// the map has just opened, or the recenter button was pressed.
const followEngageSeconds = 0.9;

/// How long the driver's own phone can give no fix before the map goes back to
/// following the position its screen hands down ([LiveRideMap.driverAt]).
const ownFixesQuietAfter = Duration(seconds: 5);

/// How far the car is drawn moving (metres) before the road line is cut back
/// to it again: the line starts under the car, never a car's length behind it.
const carLineStepMetres = 12.0;

class _LiveRideMapState extends ConsumerState<LiveRideMap> with SingleTickerProviderStateMixin {
  RouteInfo? _route;
  LatLng? _routeFrom, _routeTo;
  DateTime? _routeAt;
  int _seq = 0;
  final _map = MapController();

  bool _follow = true;
  bool _mapReady = false;

  /// When the map was last moved by hand (following paused).
  DateTime? _handAt;

  DateTime get _now => (widget.now ?? DateTime.now)();

  // ---- The car, a frame at a time -----------------------------------------
  //
  // Where the car is drawn is worked out every frame, and the camera put on
  // it: by [FixFollower] from the phone's own GPS on the driver's map, by
  // [CarPlayback] from the positions heard every few seconds on the
  // passenger's (see the top of each). Nothing glides to a position and then
  // waits for the next.

  /// Runs a frame at a time while there is something to move, and stops when
  /// the car is where it is going and the camera is on it.
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  /// Where the car is drawn and the way it faces: the car's marker, and what
  /// the camera is put on.
  final _car = ValueNotifier<CarOnMap?>(null);

  /// The driver's own map: its phone's fixes, carried forward a frame at a
  /// time. [_fixesLive] once the stream of them has given one: [LiveRideMap.
  /// driverAt] is then the same position heard second-hand.
  var _own = FixFollower();
  StreamSubscription<LiveFix>? _fixes;
  bool _fixesLive = false;
  DateTime? _fixAt;
  LatLng? _ownTaken;
  double? _ownTakenHeading;

  /// The turn the latest fix asked for while driving, as on the driver's home
  /// map: from the heading showing when it came in ([_turnFrom]) to its
  /// course, spread over [_turnOver] seconds ([headingBetween]); and the
  /// heading the car is drawn at and the map turned to, eased onto that.
  /// Stopped, both stay as they were: the car has not turned.
  double? _turnFrom, _facing;
  double _turnOver = 1;

  /// The passenger's map: the positions heard, played back; and the last one
  /// given to it, to tell a row that only says the same again.
  final _heard = CarPlayback();
  LatLng? _heardAt;
  double? _heardHeading;

  /// Whether the camera is on the car, or still on its way there from
  /// [_engageFrom] ([_engaged] seconds of [followEngageSeconds] ago); and
  /// where on screen the car is held, eased when the sheet moves.
  bool _onCar = false;
  _Cam? _engageFrom;
  double _engaged = 0;
  Offset? _heldOffset;

  /// Where the car was drawn when the road line was last cut back to it.
  LatLng? _lineFrom;

  /// The driver's own map (turned to the way the car is going) rather than
  /// the passenger's.
  bool get _ownMap => widget.driverAt != null || widget.driverFixes != null;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _fixes = widget.driverFixes?.call().listen(_onOwnFix, onError: (_) {}, onDone: () => _fixesLive = false);
    _takeCar();
    _maybeReroute();
    _syncMe();
  }

  /// The passenger's own position on their map, and the subscription that
  /// keeps it, only while they wait for pickup.
  LatLng? _me;
  StreamSubscription<LatLng>? _meSub;

  void _syncMe() {
    final want = widget.riderPosition != null && showRiderDot(widget.ride.status);
    if (want && _meSub == null) {
      _meSub = widget.riderPosition!().listen((p) {
        if (mounted) setState(() => _me = p);
      }, onError: (_) {});
    } else if (!want && _meSub != null) {
      _meSub!.cancel();
      _meSub = null;
      _me = null;
    }
  }

  @override
  void dispose() {
    _meSub?.cancel();
    _fixes?.cancel();
    _ticker.dispose();
    _car.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LiveRideMap old) {
    super.didUpdateWidget(old);
    _takeCar();
    _maybeReroute();
    _syncMe();
    // A fresh position after the hand has been off the map a while: follow
    // the car again, as if the recenter button had been pressed.
    final hand = _handAt;
    if (!_follow && _driver != null && _driver != _driverOf(old) && hand != null &&
        _now.difference(hand) >= followResumeAfter) {
      _follow = true;
      _handAt = null;
      _onCar = false;
    }
    // Whatever else changed (the sheet over the map, say), the camera is put
    // where it now belongs.
    if (_carNow != null) _wake();
    // Moved to a new pickup while searching: back onto it.
    if (_searching && (_pickup != _ll(old.ride.pickupLat, old.ride.pickupLng) || old.ride.status != widget.ride.status)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusPickup());
    }
  }

  /// Still finding a driver: the map stays on the pickup, pulsing.
  bool get _searching => widget.ride.status == RideStatus.open && _driver == null && _pickup != null;

  LatLng? get _pickup => _ll(widget.ride.pickupLat, widget.ride.pickupLng);

  /// The pickup at street level, in the middle of the map between the top
  /// of the screen and the sheet (inDrive's search screen).
  void _focusPickup() {
    final at = _pickup;
    if (!mounted || !_mapReady || at == null || !_searching) return;
    try {
      _map.rotate(0);
      _map.move(at, searchingZoom, offset: Offset(0, -MapBottomInset.of(context) / 2));
    } catch (_) {
      // Not drawn yet.
    }
  }

  /// Whether the ride has a car to show: not once it is cancelled, and on the
  /// passenger's map not while it is still on offer (a bidder is not their
  /// driver yet).
  bool get _hasCar {
    final status = widget.ride.status;
    return status != RideStatus.cancelled && (_ownMap || status != RideStatus.open);
  }

  /// Where the car is: as it is drawn, or — until it has been — where it was
  /// last known to be.
  LatLng? get _carNow => _car.value?.at ?? _driver;

  /// What the widget now says about the car, given to whichever follows it.
  void _takeCar() {
    if (!_hasCar) {
      if (_car.value != null || _own.hasFix || _heard.shown != null) {
        _own = FixFollower();
        _heard.clear();
        _car.value = null;
        _ownTaken = _ownTakenHeading = _heardAt = _heardHeading = _turnFrom = _facing = null;
        _onCar = false;
        _engageFrom = null;
      }
      return;
    }
    if (_ownMap) {
      final own = widget.driverAt;
      if (own == null) return;
      // The phone's own fixes are the news, and this the same position handed
      // down by the screen some fixes later — unless they have stopped coming.
      final last = _fixAt;
      if (_fixesLive && last != null && _now.difference(last) < ownFixesQuietAfter) return;
      if (own == _ownTaken && widget.driverHeading == _ownTakenHeading) return;
      _ownTaken = own;
      _ownTakenHeading = widget.driverHeading;
      _takeOwn((at: own, speed: null, course: widget.driverHeading, time: _now, accuracy: null));
      return;
    }
    final at = _driver;
    if (at == null) return;
    final r = widget.ride;
    final heading = r.partnerLiveHeading;
    // A row that says the same again, or a car standing still whose GPS has
    // wandered a metre: not a move.
    if (!carMovedOnMap(from: _heardAt, to: at, headingFrom: _heardHeading, headingTo: heading)) return;
    _heardAt = at;
    _heardHeading = heading;
    if (_heard.take(at, heading: heading, sentAt: r.partnerLiveAt, heardAt: _now)) {
      // The first is where the car is: there is nothing to play back yet.
      _car.value ??= (at: _heard.shown!, heading: _heard.heading);
      _wake();
    }
  }

  void _onOwnFix(LiveFix fix) {
    if (!mounted || !_hasCar) return;
    _fixesLive = true;
    _fixAt = _now;
    _takeOwn(fix);
  }

  /// A fix from the driver's own phone: what the follow carries forward from
  /// now on ([_onTick]).
  void _takeOwn(LiveFix fix) {
    // The heading as it stands, read before the fix is taken: the turn to the
    // new course carries on from wherever the last one had got to.
    final headingWas = _headingNow;
    final taken = _own.take(
      fix.at,
      speed: fix.speed,
      course: fix.course,
      time: fix.time,
      accuracy: fix.accuracy,
      clock: widget.now ?? DateTime.now,
    );
    if (taken == null) return; // from before the one in hand: not news
    final speed = taken.speed, course = taken.course;
    // The course is the way the car is going only at a speed worth the name
    // (data/compass.dart); slower, and the car faces the way it did. A fix
    // that cannot say how fast is taken at its word.
    final travelling = course != null && (speed == null || speed >= movingSpeed);
    _turnFrom = travelling ? (_turnFrom == null ? course : headingWas ?? course) : null;
    _turnOver = (taken.gap ?? 1).clamp(followTurnOverLeast, followTurnOverMost).toDouble();
    if (_car.value == null) {
      // Until it has driven anywhere, it faces the way the screen last knew.
      _facing ??= _headingNow ?? widget.driverHeading;
      _car.value = (at: _own.shown!, heading: _facing);
    }
    _wake();
  }

  /// The way the driver's own car is heading at this moment: the turn the
  /// latest fix asked for, as far as it has got. Null while it is stopped or
  /// has no course: it then faces the way it did.
  double? get _headingNow {
    final from = _turnFrom, to = _own.course;
    if (from == null || to == null) return null;
    return headingBetween(from, to, ageSeconds: _own.ageSeconds, overSeconds: _turnOver);
  }

  /// Starts the frames if they are not already running.
  void _wake() {
    if (!mounted || _ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  /// The driver's own map turns to the way the car is going.
  bool get _headingUp => _ownMap;

  /// Where on screen the car is held, from the map's centre: in the middle of
  /// the part of the map the sheet leaves showing (on the driver's phone,
  /// lower down, to show more of the road ahead).
  Offset _offsetIn(MapCamera camera) {
    final h = camera.nonRotatedSize.height;
    final visible = h - MapBottomInset.of(context);
    return Offset(0, (_headingUp ? visible * 0.65 : visible / 2) - h / 2);
  }

  /// One frame: where the car is now, and the camera put on it.
  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    if (!mounted) {
      _ticker.stop();
      return;
    }
    var busy = false;
    LatLng? at;
    if (_ownMap) {
      if (_own.hasFix) {
        // A long frame (a hitch, the app coming back) is not that much travel.
        final step = math.min(dt, 0.25);
        busy = _own.advance(step);
        at = _own.shown;
        final heading = _headingNow, faced = _facing;
        if (heading != null) {
          if (faced == null) {
            _facing = heading;
          } else {
            final turn = shortestTurn(faced, heading);
            final settled = turn.abs() < 0.05;
            _facing = settled ? heading : (faced + turnStep(turn, step) + 360) % 360;
            busy = busy || !settled;
          }
        }
        _car.value = (at: at!, heading: _facing);
      }
    } else if (_heard.shown != null) {
      // Played back, not guessed: after a long frame the car is simply where
      // it had got to by then.
      busy = _heard.advance(dt);
      at = _heard.shown;
      _car.value = (at: at!, heading: _heard.heading);
    }
    at ??= _carNow;

    if (_follow && _mapReady && at != null) {
      try {
        final camera = _map.camera;
        // Coming onto the car: from wherever the camera is now.
        if (!_onCar) {
          _onCar = true;
          _engageFrom = _Cam(camera.center, camera.zoom, camera.rotation, Offset.zero);
          _engaged = 0;
          _heldOffset = null;
        }
        // Where on screen the car is held: slid there when the sheet moves.
        final wanted = _offsetIn(camera);
        var held = _heldOffset ?? wanted;
        if (held != wanted) {
          final slide = wanted - held;
          final settled = slide.distance < 0.5;
          held = settled ? wanted : held + slide * easeFraction(dt, followTurnSeconds);
          busy = busy || !settled;
        }
        _heldOffset = held;
        final facing = _headingUp ? _facing : null;
        final up = facing == null ? 0.0 : -facing;
        var to = _Cam(at, followZoom, up, held);
        final from = _engageFrom;
        if (from != null) {
          _engaged += dt;
          final t = (_engaged / followEngageSeconds).clamp(0.0, 1.0).toDouble();
          to = _Cam.lerp(from, to, Curves.easeInOut.transform(t));
          if (t >= 1) {
            _engageFrom = null;
          } else {
            busy = true;
          }
        } else {
          // On the car: the map turns to its heading by the same ease as the
          // car does, so a bend is one steady sweep.
          final turn = shortestTurn(camera.rotation, up);
          if (turn != 0) {
            final settled = turn.abs() < 0.05;
            to = _Cam(at, followZoom, camera.rotation + (settled ? turn : turnStep(turn, math.min(dt, 0.25))), held);
            busy = busy || !settled;
          }
        }
        if (to.rotation != camera.rotation) _map.rotate(to.rotation);
        _map.move(to.point, to.zoom, offset: to.offset);
      } catch (_) {
        // Not drawn yet.
      }
    }
    // The road line starts at the car: cut back to it as it drives on.
    final drawn = _car.value?.at, cut = _lineFrom;
    if (drawn != null && _route != null && (cut == null || metresApart(cut, drawn) >= carLineStepMetres)) {
      setState(() {});
    }
    if (!busy) _ticker.stop();
  }

  /// A hand on the map: stop following until the recenter button. The car
  /// keeps moving; only the camera is let go.
  void _onGesture() {
    _handAt = _now;
    if (!_follow) return;
    _onCar = false;
    _engageFrom = null;
    setState(() => _follow = false);
  }

  void _recenter() {
    final r = widget.ride;
    if (_searching) return _focusPickup();
    if (_carNow == null) {
      recenterMap(_map, _ll(r.pickupLat, r.pickupLng));
      return;
    }
    setState(() => _follow = true);
    _handAt = null;
    _onCar = false;
    _wake();
  }

  /// A bidder on an open request is not the rider's driver yet: no car. Nor
  /// once the ride is cancelled: the car (and its route) leave the map.
  LatLng? get _driver => _driverOf(widget);

  static LatLng? _driverOf(LiveRideMap w) => w.ride.status == RideStatus.cancelled
      ? null
      : w.driverAt ?? (w.ride.status == RideStatus.open ? null : _ll(w.ride.partnerLiveLat, w.ride.partnerLiveLng));

  LatLng? get _target => etaTarget(
    widget.ride.status,
    pickup: _ll(widget.ride.pickupLat, widget.ride.pickupLng),
    drop: _ll(widget.ride.dropLat, widget.ride.dropLng),
  );

  void _maybeReroute() {
    final from = _driver, to = _target;
    if (from == null || to == null) {
      _heard.road = null;
      if (_route != null) setState(() => _route = null);
      return;
    }
    final now = _now;
    final ahead = _route == null ? null : routeAhead(_route!.points, from);
    if (!shouldReroute(
      from: from,
      to: to,
      now: now,
      lastFrom: _routeFrom,
      lastTo: _routeTo,
      lastAt: _routeAt,
      offRoute: ahead != null && ahead.offBy > offRouteMetres,
    )) {
      return;
    }
    _routeFrom = from;
    _routeTo = to;
    _routeAt = now;
    final seq = ++_seq;
    unawaited(() async {
      try {
        final r = await ref.read(geoServiceProvider).route(from, to);
        if (mounted && seq == _seq) {
          setState(() => _route = r);
          // The road the passenger's car is played back along.
          _heard.road = r.points;
          // The trip card's minutes follow the same road (core/trip_card.dart).
          ref
              .read(tripRouteFeedProvider.notifier)
              .put(widget.ride.id, TripRouteFix(target: to, points: r.points, minutes: r.durationMin, km: r.distanceKm));
        }
      } catch (_) {}
    }());
  }

  /// The road line as drawn, for [route] with [ahead] of it still in front of
  /// the car's latest position: starting at the car as it is drawn. On the
  /// passenger's map that is some way short of where the car was last heard
  /// from, so the line runs the way the car is driving there first, and on
  /// down the road from it.
  List<LatLng> _roadLine(RouteInfo? route, List<LatLng>? ahead) {
    if (route == null) return const [];
    final drawn = _car.value?.at;
    _lineFrom = drawn;
    final rest = ahead ?? route.points;
    if (drawn == null) return rest;
    if (_ownMap) return routeAhead(route.points, drawn)?.points ?? rest;
    final lead = _heard.ahead;
    return lead.isEmpty ? rest : [...lead, ...rest];
  }

  @override
  Widget build(BuildContext context) {
    // Where Admin → Display moves the recenter button (live).
    final recenterAt = tripRecenterOffset(
      ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{},
      partner: widget.partner,
    );
    final r = widget.ride;
    final route = _target == null ? null : _route;
    final narrow = MediaQuery.sizeOf(context).width < etaPillNarrowWidth;
    final driver = _driver;
    // Where the passenger is waiting, as their phone shares it (Settings →
    // Show location to your driver), for the driver on the way.
    final waiting = widget.partner ? riderLocationForDriver(r, _now) : null;
    // The way from where the passenger is to the pickup, when they are not
    // at it: on their own map from their phone, on the driver's from the
    // position they share.
    final walk = walkToPickupLine(
      widget.partner ? (waiting == null ? null : LatLng(waiting.lat, waiting.lng)) : _me,
      _ll(r.pickupLat, r.pickupLng),
    );
    // The road still ahead of the car, and the time and distance it takes.
    final ahead = route == null || driver == null ? null : routeAhead(route.points, driver);
    final eta = route == null
        ? null
        : ahead == null
        ? (minutes: route.durationMin, km: route.distanceKm)
        : etaAhead(
            routeMinutes: route.durationMin,
            routeKm: route.distanceKm,
            route: route.points,
            ahead: ahead.points,
          );
    return Stack(
      children: [
        RideMap(
          controller: _map,
          pickup: _ll(r.pickupLat, r.pickupLng),
          drop: _ll(r.dropLat, r.dropLng),
          stops: [for (final s in r.stops) s.point],
          driver: _driver,
          driverHeading: widget.driverAt != null ? widget.driverHeading : r.partnerLiveHeading,
          // Where the car is drawn, a frame at a time.
          driverLive: _car,
          // The service's Map Icon, a multi-angle one showing the frame
          // for the car's heading.
          driverIcon: ref.watch(serviceMapIconProvider(r.service)),
          route: _roadLine(route, ahead?.points),
          satellite: ref.watch(mapSatelliteProvider),
          // With a car on the map the camera follows it instead; while a
          // driver is being found it sits on the pickup.
          autoFit: driver == null && _car.value == null && !_searching,
          onGesture: _onGesture,
          onReady: () {
            _mapReady = true;
            _wake();
            _focusPickup();
          },
          // The passenger's own dot while they wait, and the way to the
          // pickup when they are not at it.
          me: _me,
          // inDrive's search: white rings pulse out of the pickup.
          extraLayers: [if (_searching) radarPulseLayer(_pickup!), if (walk != null) walkToPickupLayer(walk)],
          extraMarkers: [
            if (waiting != null)
              passengerHereMarker(
                LatLng(waiting.lat, waiting.lng),
                label: driver == null || const Distance()(driver, LatLng(waiting.lat, waiting.lng)) > 40,
              ),
          ],
        ),
        MapBottomInset.listen(
          context,
          (inset) => Positioned(
            // Clear of the notch on a phone on its side; flush to the edge on
            // the iPhone Duo, past its reserved-region inset (like the Claude app).
            right: 12 +
                mapButtonsRightInset(MediaQuery.sizeOf(context).width, MediaQuery.sizeOf(context).height,
                    MediaQuery.paddingOf(context).right, web: kIsWeb) -
                recenterAt.$1,
            // Clear of the sheet's rounded corner too, so the buttons never
            // tuck against it on a device whose sheet rests tight to them.
            bottom: mapAttributionClearance + MapBottomInset.cornerOf(context) + inset - recenterAt.$2,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ?widget.topButton,
              // Map view above recenter on every map.
              const MapTypeButton(),
              const SizedBox(height: 8),
              // Expo's trip maps recenter on the car; before a driver is on
              // the way, on the pickup.
              RecenterButton(
                tooltip: driver == null && _car.value == null ? 'Recenter' : 'Follow the car',
                onPressed: _recenter,
              ),
            ]),
          ),
        ),
        // The road the car is on: its limit, or its class as an estimate.
        Positioned(
          left: 12 + MediaQuery.paddingOf(context).left,
          top: route != null ? 68 : 12,
          child: SpeedLimitBadge(at: driver),
        ),
        if (route != null)
          Positioned(
            top: 12,
            left: 12 + MediaQuery.paddingOf(context).left,
            // On a narrow phone the pill stays left of the map buttons'
            // column (48 wide, 12 in), which can climb to the top when the
            // sheet is up.
            right: 12 +
                mapButtonsRightInset(MediaQuery.sizeOf(context).width, MediaQuery.sizeOf(context).height,
                    MediaQuery.paddingOf(context).right, web: kIsWeb) +
                (narrow ? 56 : 0),
            child: Center(
              child: Material(
                key: const ValueKey('eta-chip'),
                elevation: 4,
                borderRadius: BorderRadius.circular(24),
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.schedule, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          etaLabel(
                            minutes: eta!.minutes,
                            km: eta.km,
                            now: _now,
                            toPickup: r.status == RideStatus.accepted,
                            withClock: !narrow,
                          ),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// How far a car's fix can move, and its heading turn, and still be the car
/// standing where it was: GPS jitter, not driving (PERF-64).
const carStillMetres = 4.0;
const carStillDegrees = 5.0;

/// Whether the driver's fix [to] (heading [headingTo]) moves their car on
/// the map from where it was last shown, [from] (heading [headingFrom])
/// [elapsed] ago: by [carStillMetres] or more, or a turn of
/// [carStillDegrees] or more, and not a slow drift (under 1 m/s) that the
/// fix's own [accuracy] could account for. Pure.
bool carMovedOnMap({
  required LatLng? from,
  required LatLng to,
  double? headingFrom,
  double? headingTo,
  Duration? elapsed,
  double? accuracy,
}) {
  if (from == null) return true;
  if ((headingFrom == null) != (headingTo == null)) return true;
  if (headingFrom != null && headingTo != null && _Cam._turn(headingFrom, headingTo) >= carStillDegrees) return true;
  final moved = const Distance()(from, to);
  if (moved < carStillMetres) return false;
  final seconds = elapsed == null ? null : elapsed.inMilliseconds / 1000;
  final slow = seconds != null && seconds > 0 && moved / seconds < 1;
  return !(slow && accuracy != null && moved < accuracy);
}

/// A camera position: [point] shown [offset] from the map's centre.
class _Cam {
  const _Cam(this.point, this.zoom, this.rotation, this.offset);
  final LatLng point;
  final double zoom, rotation;
  final Offset offset;

  /// The short way round from [a] to [b], in degrees.
  static double _turn(double a, double b) {
    final d = (b - a).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  static _Cam lerp(_Cam a, _Cam b, double t) {
    // Turn the short way round.
    var turn = (b.rotation - a.rotation) % 360;
    if (turn > 180) turn -= 360;
    return _Cam(
      LatLng(
        a.point.latitude + (b.point.latitude - a.point.latitude) * t,
        a.point.longitude + (b.point.longitude - a.point.longitude) * t,
      ),
      a.zoom + (b.zoom - a.zoom) * t,
      a.rotation + turn * t,
      Offset.lerp(a.offset, b.offset, t)!,
    );
  }
}

/// The passenger's own position on the driver's map: a person in a ring of
/// the theme's colour, with "Passenger" under it unless [label] is off (the
/// car on top of it: the car marker would cover the word).
Marker passengerHereMarker(LatLng at, {bool label = true}) => Marker(
  point: at,
  width: 96,
  height: 76,
  alignment: Alignment.topCenter,
  child: Builder(
    builder: (context) {
      final t = Theme.of(context);
      return Semantics(
        label: 'Passenger is here',
        child: Column(
          key: const ValueKey('passenger-here'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: t.colorScheme.primaryContainer,
                shape: BoxShape.circle,
                border: Border.all(color: t.colorScheme.surface, width: 3),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
              ),
              child: Icon(Icons.person, size: 20, color: t.colorScheme.onPrimaryContainer),
            ),
            if (label) const SizedBox(height: 2),
            if (label)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: t.colorScheme.surface, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  'Passenger',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
      );
    },
  ),
);

/// The dashed line from the passenger to where they are picked up.
Widget walkToPickupLayer(List<LatLng> line) => Builder(
  builder: (context) => PolylineLayer(
    key: const ValueKey('walk-to-pickup'),
    polylines: [
      Polyline(
        points: line,
        color: mapIsDark(context) ? Colors.lightBlueAccent : Colors.blue.shade700,
        strokeWidth: 4,
        pattern: StrokePattern.dashed(segments: const [10, 8]),
      ),
    ],
  ),
);
