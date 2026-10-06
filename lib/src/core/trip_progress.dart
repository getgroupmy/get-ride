// The driver's running trip (Expo `ride-running`): how long the passenger
// has been on board, how far the car has driven since, and what to tell the
// driver when the ride ends without them. Pure.
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import 'ride_cancel.dart';

/// A fix worse than this is too loose to add to the distance driven.
const tripFixMaxAccuracyMetres = 50.0;

/// A leg faster than this (~250 km/h) is a GPS jump, not driving.
const tripLegMaxSpeed = 70.0;

const _distance = Distance();

/// How long the trip has been running: from the row's `started_at`, else
/// from when this screen first saw it on trip; never negative.
Duration tripElapsed({DateTime? startedAt, DateTime? firstSeen, required DateTime now}) {
  final from = startedAt ?? firstSeen;
  if (from == null) return Duration.zero;
  final d = now.difference(from);
  return d.isNegative ? Duration.zero : d;
}

/// The metres one GPS leg adds to the distance driven: none for a loose fix
/// or a jump no car could make in [elapsed].
double tripLegMetres(LatLng from, LatLng to, Duration elapsed, {double? accuracy}) {
  if (accuracy != null && accuracy > tripFixMaxAccuracyMetres) return 0;
  final m = _distance(from, to);
  final secs = elapsed.inMilliseconds / 1000;
  if (secs <= 0 || m / secs > tripLegMaxSpeed) return 0;
  return m;
}

/// `4:05`, or `1:02:05` past the hour.
String formatTripElapsed(Duration d) {
  final s = d.inSeconds;
  final mm = ((s ~/ 60) % 60).toString(), ss = (s % 60).toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${mm.padLeft(2, '0')}:$ss' : '$mm:$ss';
}

/// What to tell the driver when a ride they were on ends cancelled without
/// them approving it: the passenger accepted the driver's own request, or
/// the ride was cancelled from elsewhere (the passenger, or an admin). Null
/// when there is nothing to say: the driver approved it, or it wasn't a live
/// ride turning cancelled. A reason on the row is the passenger's own (the
/// Expo app cancels outright before the trip starts, with one).
String? passengerCancelNotice(RideStatus? before, RideRequest after, {required bool approvedHere}) {
  if (approvedHere || before == null || !before.isOngoing || after.status != RideStatus.cancelled) return null;
  if (after.cancelRequestedBy == 'partner') return 'The passenger agreed to cancel this ride.';
  final why = cancelReasonLabel(after.cancelReason);
  return why == null ? 'This ride was cancelled.' : 'The passenger cancelled this ride: $why';
}
