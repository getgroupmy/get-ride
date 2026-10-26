// "Welcome back" (owner, 26 Oct): a ride the rider was booking when the app
// closed is offered again when it opens. The booking on the confirm step
// (route, vehicle, fare, payment and who's riding) is kept
// on the phone only, per account, for [rideDraftKeep]; a sheet on home asks
// to continue or start over. Continue fills the confirm step in as Book
// again does (ride_rebook.dart): the fare is priced again and the rider
// sends it, through the same checks as any booking.
import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'ride_rebook.dart';
import 'ride_stops.dart';

/// How long a booking left unfinished is offered again.
const rideDraftKeep = Duration(minutes: 30);

/// The phone's memory of the booking, per account.
String rideDraftKey(String uid) => 'ride_draft_$uid';

/// A booking the rider left on the confirm step, and when.
class RideDraft {
  const RideDraft({required this.trip, required this.savedAt, this.currency});

  final RideRebook trip;
  final DateTime savedAt;

  /// The currency [RideRebook.fare] is in, to show it.
  final String? currency;

  Map<String, Object?> toJson() => {
    'saved_at': savedAt.toUtc().toIso8601String(),
    'pickup': stopToJson(trip.pickup),
    'drop': stopToJson(trip.drop),
    if (trip.stops.isNotEmpty) 'stops': [for (final p in trip.stops) stopToJson(p)],
    'service': ?trip.service,
    'fare': ?trip.fare,
    'currency': ?currency,
    'payment': ?trip.payment,
    'for_name': ?trip.forName,
    'for_phone': ?trip.forPhone,
  };

  String encode() => jsonEncode(toJson());

  /// [raw] read back, or null when it is not a booking (an older or broken
  /// entry is dropped, never shown).
  static RideDraft? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final saved = DateTime.tryParse('${m['saved_at']}')?.toLocal();
      final ends = parseRideStops([m['pickup'], m['drop']]);
      if (saved == null || ends.length != 2) return null;
      final fare = m['fare'];
      return RideDraft(
        savedAt: saved,
        currency: _text(m['currency']),
        trip: RideRebook(
          pickup: ends[0],
          drop: ends[1],
          stops: parseRideStops(m['stops']).take(maxRideStops).toList(),
          service: _text(m['service']),
          fare: fare is num && fare.isFinite && fare > 0 ? fare.toDouble() : null,
          payment: _text(m['payment']),
          forName: _text(m['for_name']),
          forPhone: _text(m['for_phone']),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

String? _text(Object? v) {
  final s = v is String ? v.trim() : '';
  return s.isEmpty ? null : s;
}

/// [d] if it is still worth offering at [now]: saved within [rideDraftKeep],
/// and not saved in the future (a clock moved back).
RideDraft? freshRideDraft(RideDraft? d, DateTime now) {
  if (d == null) return null;
  final age = now.difference(d.savedAt);
  if (age.isNegative || age > rideDraftKeep) return null;
  return d;
}

/// "You were booking a ride 6 min ago."
String rideDraftLine(RideDraft d, DateTime now) {
  final mins = now.difference(d.savedAt).inMinutes;
  final when = mins < 1 ? 'just now' : '$mins min ago';
  final t = d.trip;
  final what = t.forName != null ? 'booking a ride for ${t.forName}' : 'booking a ride';
  return 'You were $what $when.';
}

/// The booking on the confirm step now, as it would be saved, or null when
/// there is none to keep (no pickup or no destination).
RideDraft? rideDraftOf({
  required Place? pickup,
  required Place? drop,
  required List<Place> stops,
  required DateTime now,
  String? service,
  double? fare,
  String? payment,
  String? forName,
  String? forPhone,
  String? currency,
}) {
  if (pickup == null || drop == null) return null;
  // A place still being looked up has no real position yet.
  bool real(Place p) => p.point != const LatLng(0, 0);
  if (!real(pickup) || !real(drop)) return null;
  return RideDraft(
    savedAt: now,
    currency: currency,
    trip: RideRebook(
      pickup: pickup,
      drop: drop,
      stops: [for (final s in stops.take(maxRideStops)) if (real(s)) s],
      service: service,
      fare: fare,
      payment: payment,
      forName: _text(forName),
      forPhone: _text(forPhone),
    ),
  );
}
