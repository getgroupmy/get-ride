/// Stops on the way (Expo ride-confirm's multi-destination list): up to four
/// places between the pickup and the drop-off, visited in order. Stored on
/// the request as `ride_requests.stops` (migration 0097), so the partner sees
/// them; the route and the fare go through them.
library;

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';

/// Stops between pickup and drop-off. Expo allowed five destinations in all.
const maxRideStops = 4;

/// One stop as stored on the request.
Map<String, Object> stopToJson(Place p) => {
  'name': p.name,
  'address': p.address,
  'lat': p.point.latitude,
  'lng': p.point.longitude,
};

/// The stops on a request row, in order. Anything malformed is skipped, so a
/// bad entry never hides the good ones.
List<Place> parseRideStops(Object? raw) {
  if (raw is! List) return const [];
  final out = <Place>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final lat = e['lat'], lng = e['lng'];
    if (lat is! num || lng is! num || !lat.isFinite || !lng.isFinite) continue;
    if (lat.abs() > 90 || lng.abs() > 180) continue;
    final name = '${e['name'] ?? ''}'.trim();
    final address = '${e['address'] ?? ''}'.trim();
    out.add(Place(
      name: name.isEmpty ? (address.isEmpty ? 'Stop' : address) : name,
      address: address,
      point: LatLng(lat.toDouble(), lng.toDouble()),
    ));
  }
  return out;
}

/// "Stop 1", "Stop 2", …
String stopLabel(int index) => 'Stop ${index + 1}';
