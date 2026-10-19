// "• 4 min" beside each vehicle on the confirm sheet (inDrive's): how long
// the nearest online driver would take to reach the pickup. Pure.
import 'dart:math' as math;

import 'fare.dart';

/// The speed a driver is assumed to come to the pickup at, in town.
const driverApproachKmh = 24.0;

/// Minutes for a driver [km] away to reach the pickup; never under one.
int driverEtaMinutes(double km) => math.max(1, (km / driverApproachKmh * 60).ceil());

/// The answer of `nearby_driver_etas` (0111): nearest distance per vehicle
/// type, keyed lower-case ('' for drivers with no type).
Map<String, double> parseNearbyDrivers(Object? rows) {
  if (rows is! List) return const {};
  final out = <String, double>{};
  for (final r in rows) {
    if (r is! Map) continue;
    final km = r['nearest_km'];
    if (km is! num) continue;
    final type = ((r['vehicle_type'] as String?) ?? '').trim().toLowerCase();
    final prev = out[type];
    out[type] = prev == null ? km.toDouble() : math.min(prev, km.toDouble());
  }
  return out;
}

/// How far the nearest driver for [service] is: the drivers whose vehicle
/// type is the service's name or id, else (types and services not lined up)
/// the nearest online driver of any type. Null when none is near.
double? nearestDriverKm(RideService service, Map<String, double> byType) {
  if (byType.isEmpty) return null;
  for (final key in [service.name, service.id]) {
    final k = key?.trim().toLowerCase();
    if (k != null && k.isNotEmpty && byType.containsKey(k)) return byType[k];
  }
  return byType.values.reduce(math.min);
}

/// Minutes until the driver on the way reaches the pickup, from where they
/// last were (their live position, else where they accepted) in a straight
/// line at [driverApproachKmh]; null when either end is unknown.
int? approachMinutes({double? driverLat, double? driverLng, double? pickupLat, double? pickupLng}) {
  if (driverLat == null || driverLng == null || pickupLat == null || pickupLng == null) return null;
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(pickupLat - driverLat), dLng = rad(pickupLng - driverLng);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(driverLat)) * math.cos(rad(pickupLat)) * math.pow(math.sin(dLng / 2), 2);
  final km = 2 * r * math.asin(math.sqrt(a));
  return driverEtaMinutes(km);
}

/// The ride screen's title: "Driver on the way · 4 min" with [minutes],
/// else the status alone.
String withEta(String label, int? minutes) => minutes == null ? label : '$label · $minutes min';
