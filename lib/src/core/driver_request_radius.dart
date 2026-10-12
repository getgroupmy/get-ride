// Which open requests a driver's list shows (My Ride, migration 0160): only
// those whose pickup is inside the request's vehicle service's max search
// radius from the driver, the same radius the server widens a push to.
// A request starred for the driver (offered to them as a favourite, or from
// a rider who has them as a favourite) is never capped: it is theirs first
// wherever they are. When the driver's position or the pickup is not known
// the request stays: hiding work over a missing fix is worse than showing
// too much.
//
// Pure: the screen is lib/src/features/partner/partner_screen.dart.
library;

import 'my_ride.dart';

/// The `vehicle-services` catalogue's dispatch settings by service, keyed by
/// the service name (lower case, trimmed — what `ride_requests.service`
/// holds) and by entry id, as the server matches them. The first entry with
/// a name wins, as the server's ordered lookup does.
Map<String, ServiceDispatchConfig> dispatchConfigsByService(
  Iterable<({String id, Map<String, dynamic> values})> entries,
) {
  final out = <String, ServiceDispatchConfig>{};
  for (final e in entries) {
    final cfg = ServiceDispatchConfig.fromValues(e.values);
    final name = '${e.values['name'] ?? ''}'.trim().toLowerCase();
    if (name.isNotEmpty) out.putIfAbsent(name, () => cfg);
    if (e.id.trim().isNotEmpty) out.putIfAbsent(e.id.trim(), () => cfg);
  }
  return out;
}

/// The dispatch settings of [service]; the defaults for an unknown one.
ServiceDispatchConfig dispatchConfigFor(Map<String, ServiceDispatchConfig> configs, String? service) {
  final s = (service ?? '').trim();
  if (s.isEmpty) return const ServiceDispatchConfig();
  return configs[s.toLowerCase()] ?? configs[s] ?? const ServiceDispatchConfig();
}

/// Whether a request [awayKm] from the driver belongs on their list under a
/// [maxKm] cap. [uncapped] (a starred request) always does; an unknown
/// distance does too.
bool withinPickupRadius({required double? awayKm, required double maxKm, bool uncapped = false}) {
  if (uncapped || awayKm == null || !awayKm.isFinite) return true;
  if (!maxKm.isFinite || maxKm <= 0) return true;
  return awayKm <= maxKm;
}

/// [requests] whose pickup is within their service's max search radius,
/// keeping their order. [awayKm] is null when the driver's position or the
/// pickup is not known (kept); [uncapped] marks the starred ones (kept).
List<T> filterByPickupRadius<T>(
  List<T> requests, {
  required double? Function(T) awayKm,
  required double Function(T) maxKm,
  required bool Function(T) uncapped,
}) => [
  for (final r in requests)
    if (withinPickupRadius(awayKm: awayKm(r), maxKm: maxKm(r), uncapped: uncapped(r))) r,
];

/// Whether a request is, at [now], still offered to [me] alone among the
/// rider's favourites (the "for you first" window).
bool myRideForMeFirst({
  required String? me,
  required List<String> targetDriverIds,
  required DateTime? targetedUntil,
  required DateTime now,
}) =>
    me != null &&
    targetDriverIds.contains(me) &&
    myRideWindowOpen(targets: targetDriverIds, targetedUntil: targetedUntil, now: now);

/// What is left of the window, as the driver reads it: whole seconds,
/// rounded up ("42 s"); null when none runs.
String? myRideWindowCountdown(Duration? remaining) {
  if (remaining == null || remaining <= Duration.zero) return null;
  final s = (remaining.inMilliseconds / 1000).ceil();
  return s < 60 ? '$s s' : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
