/// Recent destinations for the place picker, from the rider's own trips.
/// Expo's home screen showed a "recent locations" row too, but it was a fixed
/// list of eight Klang Valley malls, the same for every rider.
library;

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import '../data/models.dart';

/// The rider's last [max] distinct drop-offs, newest first. Only trips this
/// rider booked count (a partner's jobs are other people's destinations), and
/// two drops within about 50 m are the same place, as are two of the same
/// name within about 500 m (KLCC's different entrances).
List<Place> recentPlaces(List<RideRequest> rides, {required String? riderId, required int max}) {
  if (riderId == null || max <= 0) return const [];
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final sorted = [...rides]..sort((a, b) => (b.createdAt ?? epoch).compareTo(a.createdAt ?? epoch));
  final out = <Place>[];
  const distance = Distance();
  for (final r in sorted) {
    if (r.riderId != riderId) continue;
    final lat = r.dropLat, lng = r.dropLng;
    if (lat == null || lng == null) continue;
    final address = (r.dropAddress ?? '').trim();
    final name = (r.dropName ?? '').trim();
    final place = Place(
      name: name.isNotEmpty ? name : (address.isNotEmpty ? address.split(',').first : 'Drop-off'),
      address: address.isNotEmpty ? address : name,
      point: LatLng(lat, lng),
    );
    final same = out.any((p) {
      final m = distance.as(LengthUnit.Meter, p.point, place.point);
      return m <= 50 || (m <= 500 && p.name.trim().toLowerCase() == place.name.trim().toLowerCase());
    });
    if (same) continue;
    out.add(place);
    if (out.length >= max) break;
  }
  return out;
}
