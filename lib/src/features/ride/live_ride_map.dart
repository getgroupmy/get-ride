import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/live_eta.dart';
import '../../data/geo_service.dart';
import '../../providers.dart';
import '../../data/models.dart';
import '../../widgets/ride_map.dart';

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

/// The rider's ride map (Expo `ride-tracking`): pickup, stops and drop-off,
/// plus — once a driver is on the way — the road still ahead of them, an
/// ETA chip and the car turned to the way it is heading.
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

class _LiveRideMapState extends ConsumerState<LiveRideMap> {
  RouteInfo? _route;
  LatLng? _routeFrom, _routeTo;
  DateTime? _routeAt;
  int _seq = 0;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _maybeReroute();
  }

  @override
  void didUpdateWidget(covariant LiveRideMap old) {
    super.didUpdateWidget(old);
    _maybeReroute();
  }

  LatLng? get _driver => widget.driverAt ?? _ll(widget.ride.partnerLiveLat, widget.ride.partnerLiveLng);

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
    if (!shouldReroute(from: from, to: to, now: now, lastFrom: _routeFrom, lastTo: _routeTo, lastAt: _routeAt)) {
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
    return Stack(
      children: [
        RideMap(
          pickup: _ll(r.pickupLat, r.pickupLng),
          drop: _ll(r.dropLat, r.dropLng),
          stops: [for (final s in r.stops) s.point],
          driver: _driver,
          driverHeading: widget.driverAt != null ? widget.driverHeading : r.partnerLiveHeading,
          route: route?.points ?? const [],
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
                            minutes: route.durationMin,
                            km: route.distanceKm,
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
