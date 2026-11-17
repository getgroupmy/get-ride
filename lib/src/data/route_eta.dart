// The driver's "To pickup" distance and ETA on the ride-request card, from
// Apple Maps on iOS (ios/Runner/AppDelegate.swift → RouteEtaPlugin). MapKit's
// MKDirections gives a real driving distance and a traffic-adjusted ETA with
// no API key and no quota; it routes on Apple's servers, so it needs the
// network. Everywhere else — Android, web, no answer, offline or throttled —
// this returns null and the card keeps its straight-line + fixed-speed
// heuristic (awayKm / pickupMinutes).
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:latlong2/latlong.dart';

const _channel = MethodChannel('get_ride/route_eta');

/// Apple Maps' driving distance (km) and traffic-aware ETA (whole minutes)
/// from [from] to [to]. null off iOS, or when MapKit can't answer — the
/// caller then falls back to its heuristic.
Future<({double km, int minutes})?> routeEtaToPickup(LatLng from, LatLng to) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
  try {
    final res = await _channel.invokeMapMethod<String, dynamic>('eta', {
      'fromLat': from.latitude,
      'fromLng': from.longitude,
      'toLat': to.latitude,
      'toLng': to.longitude,
    });
    if (res == null) return null;
    final metres = (res['distanceMeters'] as num?)?.toDouble();
    final seconds = (res['etaSeconds'] as num?)?.toDouble();
    if (metres == null || seconds == null || metres <= 0 || seconds <= 0) return null;
    return routeEtaResult(metres, seconds);
  } catch (_) {
    // Throttled (MKErrorLoadingThrottled), offline, no route, or no channel.
    return null;
  }
}

/// Metres and seconds as the chip shows them: kilometres, and whole minutes
/// rounded up with a one-minute floor (so "just here" reads "1 min", matching
/// pickupMinutes). Pure; see test/route_eta_test.dart.
({double km, int minutes}) routeEtaResult(double distanceMetres, double etaSeconds) =>
    (km: distanceMetres / 1000, minutes: math.max(1, (etaSeconds / 60).ceil()));

/// The fare route chain's answer (ai-route-proxy: Waze → Google Maps → AI →
/// OSRM) as the chip shows it — distance in km unchanged, duration rounded up
/// to whole minutes with the same one-minute floor as [routeEtaResult]. Used
/// off iOS, where there is no Apple Maps call. Pure; see test/route_eta_test.dart.
({double km, int minutes}) pickupEtaFromEstimate(double distanceKm, double durationMin) =>
    (km: distanceKm, minutes: math.max(1, durationMin.ceil()));

/// Whether this phone can ask Apple Maps itself (an iPhone or iPad app).
bool get canAskAppleMapsOnDevice => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Apple Maps' driving distance (km) and traffic-aware time (minutes) for a
/// whole trip through [points] (pickup, stops in order, drop-off), asked on
/// the phone one leg at a time (MapKit, no key, no quota), all of it within
/// [within]. null off iOS, past the time, or when any leg has no answer.
Future<({double km, double minutes})?> appleRouteThrough(List<LatLng> points, Duration within) async {
  if (!canAskAppleMapsOnDevice || points.length < 2) return null;
  Future<({double km, double minutes})?> legs() async {
    var metres = 0.0, seconds = 0.0;
    for (var i = 0; i + 1 < points.length; i++) {
      final res = await _channel.invokeMapMethod<String, dynamic>('eta', {
        'fromLat': points[i].latitude,
        'fromLng': points[i].longitude,
        'toLat': points[i + 1].latitude,
        'toLng': points[i + 1].longitude,
      });
      final m = (res?['distanceMeters'] as num?)?.toDouble();
      final s = (res?['etaSeconds'] as num?)?.toDouble();
      if (m == null || s == null || m <= 0 || s <= 0) return null;
      metres += m;
      seconds += s;
    }
    return (km: metres / 1000, minutes: seconds / 60);
  }

  try {
    return await legs().timeout(within, onTimeout: () => null);
  } catch (_) {
    return null;
  }
}

/// Apple Maps' driving route for the booking preview: the same distance (km)
/// and traffic-aware time (minutes) as [appleRouteThrough], plus the driving
/// [points] MapKit itself would draw — so on iPhone the app's route line sits
/// on the roads of Apple's own map under it (apple_native_layer.dart), instead
/// of OSRM geometry that drifts off them. Asked one leg at a time through
/// [through] (pickup, stops, drop-off), stitched end to end. null off iOS,
/// past [within], or when any leg has no answer — the caller then keeps its
/// OSRM/proxy geometry (geo_service.dart). The distance here is Apple's; the
/// caller keeps the fare route's distance for pricing and takes only [points].
Future<({double km, double minutes, List<LatLng> points})?> appleRoute(
  List<LatLng> through,
  Duration within,
) async {
  if (!canAskAppleMapsOnDevice || through.length < 2) return null;
  Future<({double km, double minutes, List<LatLng> points})?> legs() async {
    var metres = 0.0, seconds = 0.0;
    final points = <LatLng>[];
    for (var i = 0; i + 1 < through.length; i++) {
      final res = await _channel.invokeMapMethod<String, dynamic>('route', {
        'fromLat': through[i].latitude,
        'fromLng': through[i].longitude,
        'toLat': through[i + 1].latitude,
        'toLng': through[i + 1].longitude,
      });
      final m = (res?['distanceMeters'] as num?)?.toDouble();
      final s = (res?['etaSeconds'] as num?)?.toDouble();
      final leg = latLngsFromFlat(res?['coords']);
      if (m == null || s == null || m <= 0 || s <= 0 || leg.length < 2) return null;
      metres += m;
      seconds += s;
      // Each leg begins where the last ended; drop the repeated join point.
      points.addAll(points.isEmpty ? leg : leg.skip(1));
    }
    if (points.length < 2) return null;
    return (km: metres / 1000, minutes: seconds / 60, points: points);
  }

  try {
    return await legs().timeout(within, onTimeout: () => null);
  } catch (_) {
    return null;
  }
}

/// A flat `[lat, lng, lat, lng, …]` list from the native side (route_eta's
/// "route" method) back into points, dropping a trailing odd value and any
/// pair out of range. Pure; see test/route_eta_test.dart.
List<LatLng> latLngsFromFlat(Object? flat) {
  if (flat is! List) return const [];
  final points = <LatLng>[];
  for (var i = 0; i + 1 < flat.length; i += 2) {
    final lat = (flat[i] as num?)?.toDouble();
    final lng = (flat[i + 1] as num?)?.toDouble();
    if (lat == null || lng == null) continue;
    if (lat.abs() > 90 || lng.abs() > 180) continue;
    points.add(LatLng(lat, lng));
  }
  return points;
}
