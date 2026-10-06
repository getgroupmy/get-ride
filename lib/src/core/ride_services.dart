/// Ride options from the admin Vehicle Services catalogue (Expo
/// `ride-confirm.tsx` `EXTENDED_RIDE_TYPES`), arranged as Admin → Display's
/// vehicle bar says.
library;

import '../admin/screens/meterapp/display_logic.dart';
import 'fare.dart';

/// Expo prices each service at `costPerKm / 1.5` of the base fare.
const baseCostPerKm = 1.5;

/// What Expo offers when the catalogue has nothing a passenger can book.
const fallbackRideService = RideService('Ride', 'Affordable rides', 1.0, 4);

typedef CatalogueEntry = ({String id, Map<String, dynamic> values});

/// The services a passenger can book: active, not hidden, tagged for
/// passengers (or untagged), in the vehicle-bar order and then display
/// priority. Never empty.
List<RideService> rideServicesFromCatalogue(List<CatalogueEntry> entries, Map<String, dynamic> display) {
  final arranged = arrangeVehicles<CatalogueEntry>(entries, display, id: (e) => e.id, values: (e) => e.values);
  final out = <RideService>[];
  for (final e in arranged) {
    final v = e.values;
    final types = _strings(v['serviceTypes']);
    if (types.isNotEmpty && !types.contains('Passenger')) continue;
    final cost = _num(v['costPerKm']);
    final seats = _num(v['maxPax'])?.round();
    final name = '${v['name'] ?? ''}'.trim();
    out.add(
      RideService(
        name.isEmpty ? 'Ride' : name,
        '${v['shortDescription'] ?? ''}'.trim(),
        cost != null && cost > 0 ? cost / baseCostPerKm : 1.0,
        seats != null && seats > 0 ? seats : 4,
        id: e.id,
      ),
    );
  }
  return out.isEmpty ? const [fallbackRideService] : out;
}

List<String> _strings(Object? raw) => raw is List ? raw.map((x) => '$x').toList() : const [];

double? _num(Object? raw) => raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
