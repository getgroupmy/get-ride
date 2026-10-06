// The driver's incoming-request alert (Expo `partner-ehailing`): each new
// request pops up on its own for [requestAlertWindow], then drops back into
// the queue if it is left alone, or out of it if declined. Pure.
import 'dart:math' as math;

/// How long a request is spotlighted before it is dismissed (Expo's 35 s).
const requestAlertWindow = Duration(seconds: 35);

/// Which request to spotlight now.
///
/// - The one already showing, while it is still open.
/// - Otherwise the first in [openIds] (already in display order) that has
///   not been spotlighted before and that the driver hasn't hidden.
/// - Null when nothing is new.
String? nextRequestAlert({
  required List<String> openIds,
  required Set<String> seen,
  required Set<String> hidden,
  String? current,
}) {
  if (current != null && openIds.contains(current) && !hidden.contains(current)) return current;
  for (final id in openIds) {
    if (!seen.contains(id) && !hidden.contains(id)) return id;
  }
  return null;
}

/// The countdown bar: 1 when the request pops up, 0 when its window ends.
double requestAlertProgress(Duration shownFor) =>
    math.max(0, 1 - shownFor.inMilliseconds / requestAlertWindow.inMilliseconds).toDouble();

bool requestAlertExpired(Duration shownFor) => shownFor >= requestAlertWindow;

/// Seconds left, rounded up, for the label beside the bar.
int requestAlertSecondsLeft(Duration shownFor) =>
    math.max(0, ((requestAlertWindow - shownFor).inMilliseconds / 1000).ceil());

/// A rough drive time to the pickup, at an average city speed of 25 km/h
/// (Expo's request card shows "~N min"); never under a minute.
int pickupMinutes(double km) => math.max(1, (km / 25 * 60).ceil());

/// Requests the driver declined whose passenger has since raised the fare
/// (Expo re-surfaces them): those in [declined] (id → the fare when declined)
/// now asking more. A fare that dropped or stayed put leaves them declined.
List<String> raisedAfterDecline(Map<String, double> declined, Iterable<({String id, double? fare})> open) => [
  for (final r in open)
    if (declined[r.id] case final was? when r.fare != null && r.fare! > was) r.id,
];
