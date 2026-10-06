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
  for (final r in _all) {
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
