/// Recent destinations for the place picker, from the rider's own trips.
/// Expo's home screen showed a "recent locations" row too, but it was a fixed
/// list of eight Klang Valley malls, the same for every rider.
library;

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import '../data/models.dart';

/// [address] reduced for comparing: lower case, only letters and digits,
/// so "KLCC, 156, Jalan Ampang" and "KLCC 156 Jalan  Ampang." match.
String recentAddressKey(String address) => address.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

/// The rider's last [max] distinct drop-offs, newest first. Only trips this
/// rider booked count (a partner's jobs are other people's destinations), and
/// two drops within about 50 m are the same place, as are two of the same
/// name or the same address (punctuation aside) within 5 km (KLCC's
/// different entrances, an address written twice). The newest is kept.
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
      final sameName = p.name.trim().toLowerCase() == place.name.trim().toLowerCase();
      final sameAddress = recentAddressKey(p.address).isNotEmpty && recentAddressKey(p.address) == recentAddressKey(place.address);
      return m <= 50 || (sameName && m <= 5000) || (sameAddress && m <= 5000);
    });
    if (same) continue;
    out.add(place);
    if (out.length >= max) break;
  }
  return out;
}
