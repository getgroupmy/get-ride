import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/live_eta.dart';
import '../../data/geo_service.dart';
import '../../providers.dart';
import '../../data/models.dart';
import '../../widgets/map_recenter.dart';
import '../../widgets/map_type_button.dart';
import '../../widgets/map_sheet_layout.dart';
import '../../widgets/ride_map.dart';

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
class LiveRideMap extends ConsumerStatefulWidget {
  const LiveRideMap({super.key, required this.ride, this.now, this.driverAt, this.driverHeading});

  final RideRequest ride;

  /// Where the driver is when this map is the driver's own (their phone's
  /// fix, fresher than the published one); null reads the ride row.
  final LatLng? driverAt;
  final double? driverHeading;

  /// The clock; null is [DateTime.now]. For tests.
  final DateTime Function()? now;

  @override
  ConsumerState<LiveRideMap> createState() => _LiveRideMapState();
}

/// Street zoom the camera follows the car at.
const followZoom = 16.5;

/// How long a hand on the map holds the camera still: the next position
/// that arrives after this recentres on the car again by itself.
const followResumeAfter = Duration(seconds: 10);

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
  late final _cam = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..addListener(_camTick);
  _Cam? _camFrom, _camTo, _camNow;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _maybeReroute();
  }

  @override
  void dispose() {
    _cam.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LiveRideMap old) {
    super.didUpdateWidget(old);
    _maybeReroute();
    // A fresh position after the hand has been off the map a while: follow
    // the car again, as if the recenter button had been pressed.
    final hand = _handAt;
    if (!_follow && _driver != null && _driver != _driverOf(old) && hand != null &&
        _now.difference(hand) >= followResumeAfter) {
      _follow = true;
      _handAt = null;
      _camTo = null;
    }
    if (_driver != null) WidgetsBinding.instance.addPostFrameCallback((_) => _followCar());
  }

  /// The driver's own map turns to the way the car is going.
  bool get _headingUp => widget.driverAt != null;

  double? get _heading => widget.driverAt != null ? widget.driverHeading : widget.ride.partnerLiveHeading;

  /// Glides the camera onto the car: centred in the part of the map the
  /// sheet leaves showing (on the driver's phone, lower down, to show more
  /// of the road ahead).
  void _followCar() {
    final at = _driver;
    if (!mounted || !_follow || !_mapReady || at == null) return;
    final MapCamera camera;
    try {
      camera = _map.camera;
    } catch (_) {
      return;
    }
    final h = camera.nonRotatedSize.height;
    final visible = h - MapBottomInset.of(context);
    final y = (_headingUp ? visible * 0.65 : visible / 2) - h / 2;
    final heading = _heading;
    final to = _Cam(at, followZoom, _headingUp && heading != null ? -heading : 0, Offset(0, y));
    if (_camTo != null && _camTo!.same(to)) return;
    _camFrom = _camNow ?? _Cam(camera.center, camera.zoom, camera.rotation, Offset.zero);
    _camTo = to;
    _cam.forward(from: 0);
  }

  void _camTick() {
    final a = _camFrom, b = _camTo;
    if (a == null || b == null) return;
    final c = _Cam.lerp(a, b, Curves.easeInOut.transform(_cam.value));
    try {
      _map.rotate(c.rotation);
      _map.move(c.point, c.zoom, offset: c.offset);
      _camNow = c;
    } catch (_) {
      // Not drawn yet.
    }
  }

  /// A hand on the map: stop following until the recenter button.
  void _onGesture() {
    _handAt = _now;
    if (!_follow) return;
    _cam.stop();
    _camNow = _camTo = null;
    setState(() => _follow = false);
  }

  void _recenter() {
    final r = widget.ride;
    if (_driver == null) {
      recenterMap(_map, _ll(r.pickupLat, r.pickupLng));
      return;
    }
    setState(() => _follow = true);
    _handAt = null;
    _camTo = null;
    _followCar();
  }

  /// A bidder on an open request is not the rider's driver yet: no car.
  LatLng? get _driver => _driverOf(widget);

  static LatLng? _driverOf(LiveRideMap w) =>
      w.driverAt ?? (w.ride.status == RideStatus.open ? null : _ll(w.ride.partnerLiveLat, w.ride.partnerLiveLng));

  LatLng? get _target => etaTarget(
    widget.ride.status,
    pickup: _ll(widget.ride.pickupLat, widget.ride.pickupLng),
    drop: _ll(widget.ride.dropLat, widget.ride.dropLng),
  );

  void _maybeReroute() {
    final from = _driver, to = _target;
    if (from == null || to == null) {
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
        if (mounted && seq == _seq) setState(() => _route = r);
      } catch (_) {}
    }());
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final route = _target == null ? null : _route;
    final driver = _driver;
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
          route: ahead?.points ?? route?.points ?? const [],
          satellite: ref.watch(mapSatelliteProvider),
          // With a car on the map the camera follows it instead.
          autoFit: driver == null,
          onGesture: _onGesture,
          onReady: () {
            _mapReady = true;
            _followCar();
          },
        ),
        MapBottomInset.listen(
          context,
          (inset) => Positioned(
            right: 12,
            bottom: mapAttributionClearance + inset,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Map view above recenter on every map.
              const MapTypeButton(),
              const SizedBox(height: 8),
              // Expo's trip maps recenter on the car; before a driver is on
              // the way, on the pickup.
              RecenterButton(
                tooltip: driver == null ? 'Recenter' : 'Follow the car',
                onPressed: _recenter,
              ),
            ]),
          ),
        ),
        if (route != null)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
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

/// A camera position: [point] shown [offset] from the map's centre.
class _Cam {
  const _Cam(this.point, this.zoom, this.rotation, this.offset);
  final LatLng point;
  final double zoom, rotation;
  final Offset offset;

  bool same(_Cam o) =>
      o.point == point &&
      (o.zoom - zoom).abs() < 0.01 &&
      (o.rotation - rotation).abs() < 0.5 &&
      (o.offset - offset).distance < 1;

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
