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
  return after.cancelRequestedAt == null && after.status.isOngoing && after.status != RideStatus.open;
}

/// The rider shares their live position once a driver is on the way, until
/// the ride ends (Expo publishes `user_live_*` the same way).
bool shareRiderLocation(RideStatus status) =>
    status == RideStatus.accepted || status == RideStatus.arrived || status == RideStatus.onTrip;
