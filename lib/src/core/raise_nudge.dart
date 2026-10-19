// The rider's search, once no driver has answered for a while: "Raise
// your fare and search again" on the sheet itself (bidding requests only),
// and the hint beside the countdown of how near the drivers are. Pure.
import 'dart:math' as math;

import 'driver_eta.dart';

/// The admin's setting (Admin → Display → Ride search): seconds without an
/// offer before the search sheet offers a raise. Kept in the display
/// settings blob, so it needs no column of its own.
const raiseNudgeKey = 'raiseFareAfterSeconds';

/// Without that setting: 45 seconds, as long as one driver's offer stands.
const raiseNudgeDefault = Duration(seconds: 45);
const raiseNudgeMinSeconds = 15;
const raiseNudgeMaxSeconds = 300;

/// How long the search waits for an offer before offering a raise, as the
/// admin set it (clamped), or [raiseNudgeDefault].
Duration raiseNudgeAfter(Map<String, dynamic>? settings) {
  final v = settings?[raiseNudgeKey];
  final n = v is num ? v : num.tryParse('${v ?? ''}');
  if (n == null) return raiseNudgeDefault;
  return Duration(seconds: n.round().clamp(raiseNudgeMinSeconds, raiseNudgeMaxSeconds));
}

/// Whether the sheet offers a raise now: a request open to offers, none on
/// screen, and [after] gone by since the search (or the rider's last raise
/// or "Keep waiting") began.
bool showRaiseNudge({
  required bool bidding,
  required bool offerStanding,
  required Duration waited,
  required Duration after,
}) => bidding && !offerStanding && waited >= after;

/// Past this, the nearest driver is too far off to call the area busy with
/// drivers.
const fewDriversKm = 5.0;

/// The hint beside the search's countdown, from the nearest online drivers
/// per vehicle type ([parseNearbyDrivers]): how far the nearest one for
/// [service] is (any type's when none of its own is listed), or that few
/// are near. Null with nothing to go on: never a made-up number.
String? searchWaitHint(Map<String, double> nearestKmByType, {String? service}) {
  if (nearestKmByType.isEmpty) return null;
  final key = service?.trim().toLowerCase();
  final km = key != null && key.isNotEmpty && nearestKmByType.containsKey(key)
      ? nearestKmByType[key]!
      : nearestKmByType.values.reduce(math.min);
  if (km.isNaN || km < 0) return null;
  if (km > fewDriversKm) return 'Few drivers nearby';
  return 'Nearest driver about ${driverEtaMinutes(km)} min away';
}
