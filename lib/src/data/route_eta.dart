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
