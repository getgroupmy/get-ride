// Request history, kept apart by the side someone was on: as a rider (Trips,
// the user side) the requests they made; as a partner (Drive → Trip
// history) the trips they took. Someone who is both sees each list in its
// own mode, never mixed. Pure.
import '../data/models.dart';

/// Which side of a request the list is for.
enum TripHistoryRole {
  rider('rider_id'),
  partner('partner_id');

  const TripHistoryRole(this.column);

  /// The `ride_requests` column that holds this person on that side.
  final String column;
}

/// The chips above the list.
enum TripHistoryFilter {
  all('All'),
  ongoing('Ongoing'),
  completed('Completed'),
  cancelled('Cancelled');

  const TripHistoryFilter(this.label);
  final String label;

  /// The `ride_requests.status` values it shows; null for all of them.
  List<String>? get statuses => switch (this) {
    all => null,
    ongoing => [
      for (final s in RideStatus.values)
        if (s.isOngoing) s.db,
    ],
    completed => [RideStatus.completed.db],
    // Expired requests (no driver found) count as cancelled.
    cancelled => [RideStatus.cancelled.db, RideStatus.expired.db],
  };

  bool matches(RideStatus s) => statuses?.contains(s.db) ?? true;
}

/// Where a row opens: a finished request its receipt, one still under way
/// the live screen of the side the list is for.
String tripHistoryRoute(TripHistoryRole role, RideRequest r) {
  if (r.status.isFinished) return role == TripHistoryRole.partner ? '/drive/history/${r.id}' : '/trips/${r.id}';
  return role == TripHistoryRole.partner ? '/drive/trip/${r.id}' : '/ride/${r.id}';
}

/// How many rows a page reads.
const tripHistoryPageSize = 30;
