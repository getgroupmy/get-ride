/// Recent destinations for the place picker, from the rider's own trips.
/// Expo's home screen showed a "recent locations" row too, but it was a fixed
/// list of eight Klang Valley malls, the same for every rider.
library;

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import '../data/models.dart';

/// The rider's last [max] distinct drop-offs, newest first. Only trips this
/// rider booked count (a partner's jobs are other people's destinations), and
/// two drops within about 50 m are the same place.
List<Place> recentPlaces(List<RideRequest> rides, {required String? riderId, required int max}) {
  if (riderId == null || max <= 0) return const [];
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final sorted = [...rides]..sort((a, b) => (b.createdAt ?? epoch).compareTo(a.createdAt ?? epoch));
  final out = <Place>[];
  final seen = <String>{};
  for (final r in sorted) {
    if (r.riderId != riderId) continue;
    final lat = r.dropLat, lng = r.dropLng;
    if (lat == null || lng == null) continue;
    final key = '${(lat * 2000).round()}:${(lng * 2000).round()}';
    if (!seen.add(key)) continue;
    final address = (r.dropAddress ?? '').trim();
    final name = (r.dropName ?? '').trim();
    out.add(
      Place(
        name: name.isNotEmpty ? name : (address.isNotEmpty ? address.split(',').first : 'Drop-off'),
        address: address.isNotEmpty ? address : name,
        point: LatLng(lat, lng),
      ),
    );
    if (out.length >= max) break;
  }
  return out;
}
