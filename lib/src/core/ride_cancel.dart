// The rider's cancel flow (Expo `ride-tracking.tsx`): the reasons offered,
// how a stored reason reads back, when a pending request was declined, and
// when the rider's own position is shared with the driver. Pure.
import '../data/models.dart';

/// A reason the rider can pick. [id] is what is stored in `cancel_reason`,
/// exactly as Expo stores it, so both apps read each other's rows.
typedef CancelReason = ({String id, String label});

const otherCancelReason = 'other';

const _all = <CancelReason>[
  (id: 'driver_too_long', label: 'Driver taking too long'),
  (id: 'driver_not_moving', label: "Driver isn't moving"),
  (id: 'changed_plans', label: 'Changed my plans'),
  (id: 'booked_by_mistake', label: 'Booked by mistake'),
  (id: 'driver_asked_cancel', label: 'Driver asked me to cancel'),
  (id: otherCancelReason, label: 'Other'),
];

/// Why a rider withdraws a request still looking for a driver (inDrive's
/// "Why do you want to cancel?"). Optional: the sheet can be skipped.
const searchCancelReasons = <CancelReason>[
  (id: 'drivers_too_far', label: 'Drivers are too far away'),
  (id: 'high_fares', label: 'High fares'),
  (id: 'accidental_request', label: 'Accidental request'),
  (id: 'wrong_points', label: 'Wrong pickup or destination point'),
  (id: 'no_offers', label: 'No offers from drivers'),
  (id: 'better_alternative', label: 'Better alternative found'),
];

/// The reasons a driver gives for cancelling before pickup, exactly as
/// Expo's ride-running screen stores them.
const driverCancelReasons = <CancelReason>[
  (id: 'passenger_no_show', label: 'Passenger no-show'),
  (id: 'wrong_address', label: 'Wrong pickup address'),
  (id: 'passenger_cancelled', label: 'Passenger asked to cancel'),
  (id: 'traffic_too_far', label: 'Too far / heavy traffic'),
  (id: 'vehicle_issue', label: 'Vehicle issue'),
  (id: otherCancelReason, label: 'Other'),
];

/// A driver may cancel only before the passenger is on board (migration
/// 0106 holds the database to the same rule). After pickup the trip is
/// completed or ended early instead.
bool driverMayCancel(RideStatus status) => status == RideStatus.accepted || status == RideStatus.arrived;

/// True when the driver cancelled the ride ([RideRepository.cancelAsDriver]
/// marks it `cancel_requested_by = 'partner'`, as does a passenger agreeing
/// to an older build's driver request).
bool cancelledByDriver(RideRequest r) => r.status == RideStatus.cancelled && r.cancelRequestedBy == 'partner';

/// What the passenger is told when their driver cancels.
String driverCancelNotice(RideRequest r) {
  final why = cancelReasonLabel(r.cancelReason);
  return why == null ? 'Your driver cancelled this ride.' : 'Your driver cancelled this ride: $why';
}

/// Reasons that blame a driver make no sense before one has accepted.
List<CancelReason> cancelReasonsFor(RideStatus status) => status == RideStatus.open
    ? [
        for (final r in _all)
          if (!r.id.startsWith('driver_')) r,
      ]
    : _all;

/// What is stored for [id]: the id itself, or the rider's own words for
/// "Other". Null when nothing usable was given.
String? cancelReasonValue(String? id, String otherText) {
  if (id == null) return null;
  if (id == otherCancelReason) {
    final t = otherText.trim();
    return t.isEmpty ? null : t;
  }
  return id;
}

/// A stored reason as people read it: a known id becomes its label, and
/// anything else (free text, older rows) is shown as written.
String? cancelReasonLabel(String? stored) {
  final s = stored?.trim() ?? '';
  if (s.isEmpty) return null;
  for (final r in [..._all, ...driverCancelReasons, ...searchCancelReasons]) {
    if (r.id == s) return r.label;
  }
  return s;
}

/// True when the rider's pending cancellation request has just been
/// declined: it was there, now it is gone, and the ride carries on.
bool riderCancelDeclined(RideRequest? before, RideRequest after) {
  if (before == null || before.cancelRequestedAt == null || before.cancelRequestedBy != 'rider') return false;
  // A request that lapsed unanswered (0191) is not a decline.
  return after.cancelRequestedAt == null &&
      after.status.isOngoing &&
      after.status != RideStatus.open &&
      after.cancelRequestOutcome != 'expired';
}

/// How long a cancellation request waits for an answer (Admin → App
/// Settings → Trip cancellation, migration 0191), and whether one that is
/// declined or not answered opens a support ticket.
class CancelRequestConfig {
  const CancelRequestConfig({this.timeout = const Duration(minutes: 2), this.openTicket = true});

  final Duration timeout;
  final bool openTicket;

  static const standard = CancelRequestConfig();

  factory CancelRequestConfig.fromJson(Object? json) {
    if (json is! Map) return standard;
    final secs = json['timeoutSeconds'];
    return CancelRequestConfig(
      timeout: Duration(seconds: secs is num ? secs.round().clamp(30, 1800) : 120),
      openTicket: json['openTicket'] != false,
    );
  }

  Map<String, dynamic> toJson() => {'timeoutSeconds': timeout.inSeconds, 'openTicket': openTicket};

  @override
  bool operator ==(Object other) =>
      other is CancelRequestConfig && other.timeout == timeout && other.openTicket == openTicket;

  @override
  int get hashCode => Object.hash(timeout, openTicket);
}

/// How long the rider's pending request still waits; null when there is none.
Duration? riderCancelWaitLeft(RideRequest r, DateTime now, CancelRequestConfig c) {
  final at = r.cancelRequestedAt;
  if (at == null || r.cancelRequestedBy != 'rider' || !r.status.isOngoing) return null;
  final left = at.add(c.timeout).difference(now);
  return left.isNegative ? Duration.zero : left;
}

/// The rider asked to cancel and the driver didn't answer in time: the
/// server lapsed it, or the time is up and the server's job is still to
/// run. The ride carries on; the rider can ask again, contact support or
/// use SOS.
bool riderCancelUnanswered(RideRequest r, DateTime now, CancelRequestConfig c) {
  if (!r.status.isOngoing || r.status == RideStatus.open) return false;
  final left = riderCancelWaitLeft(r, now, c);
  if (left != null) return left == Duration.zero;
  final at = r.cancelRequestOutcomeAt;
  return r.cancelRequestedAt == null &&
      r.cancelRequestOutcome == 'expired' &&
      r.cancelRequestOutcomeBy == 'rider' &&
      (at == null || now.difference(at) < unansweredShownFor);
}

/// How long the options stay up after a request lapsed.
const unansweredShownFor = Duration(minutes: 10);

/// "1:05" for what is left of the wait.
String cancelWaitText(Duration left) {
  final s = left.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The rider shares their live position once a driver is on the way, until
/// the ride ends (Expo publishes `user_live_*` the same way). Before pickup
/// only with Settings → Show location to your driver on ([showToDriver]);
/// during the trip always, unseen by the driver, for the check that notices
/// passenger and car apart (0154).
bool shareRiderLocation(RideStatus status, {bool showToDriver = true}) => switch (status) {
  RideStatus.accepted || RideStatus.arrived => showToDriver,
  RideStatus.onTrip => true,
  _ => false,
};

/// How old a shared position may be and still be drawn for the driver.
const riderLocationFreshFor = Duration(minutes: 1);

/// Where the passenger is waiting, for the driver on the way to them: only
/// before pickup, only a recent position; null otherwise.
({double lat, double lng})? riderLocationForDriver(RideRequest r, DateTime now) {
  if (r.status != RideStatus.accepted && r.status != RideStatus.arrived) return null;
  final lat = r.userLiveLat, lng = r.userLiveLng, at = r.userLiveAt;
  if (lat == null || lng == null || at == null) return null;
  return now.difference(at) <= riderLocationFreshFor ? (lat: lat, lng: lng) : null;
}
