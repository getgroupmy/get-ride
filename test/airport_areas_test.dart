import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/airport_areas.dart';
import 'package:latlong2/latlong.dart';

void main() {
  // A square around KLIA, roughly 2 km a side.
  final klia = AirportArea.fromEntry('a1', {
    'name': 'KLIA',
    'code': 'KUL',
    'boundary': jsonEncode({
      'coords': [
        {'latitude': 2.75, 'longitude': 101.70},
        {'latitude': 2.75, 'longitude': 101.72},
        {'latitude': 2.73, 'longitude': 101.72},
        {'latitude': 2.73, 'longitude': 101.70},
      ],
      'bbox': {'north': 2.75, 'south': 2.73, 'east': 101.72, 'west': 101.70},
    }),
  })!;

  test('inside, within 300 m of the edge, and outside', () {
    expect(klia.contains(const LatLng(2.74, 101.71)), isTrue);
    expect(klia.contains(const LatLng(2.752, 101.71)), isTrue); // ~220 m north of the edge
    expect(klia.contains(const LatLng(2.76, 101.71)), isFalse); // ~1.1 km out
    expect(klia.centroid.latitude, closeTo(2.74, 1e-9));
    expect(klia.centroid.longitude, closeTo(101.71, 1e-9));
  });

  test('a boundary is required; a bbox alone still works', () {
    expect(AirportArea.fromEntry('x', {'name': 'No shape'}), isNull);
    expect(AirportArea.fromEntry('x', {'boundary': 'not json'}), isNull);
    final box = AirportArea.fromEntry('b', {
      'boundary': jsonEncode({
        'coords': [],
        'bbox': {'north': 1, 'south': 0, 'east': 1, 'west': 0},
      }),
    })!;
    expect(box.contains(const LatLng(0.5, 0.5)), isTrue);
    expect(box.name, 'Airport');
  });

  test('results in or named after the airport collapse into it, once', () {
    final results = [
      ('Departure Hall', const LatLng(2.74, 101.71)),
      ('Mydin Sepang', const LatLng(2.80, 101.70)),
      ('KLIA Ekspres stop', const LatLng(3.00, 101.70)),
      ('Arrival Hall', const LatLng(2.741, 101.711)),
    ];
    final out = collapseAirports<(String, LatLng)>(
      results,
      [klia],
      point: (r) => r.$2,
      text: (r) => r.$1,
      airport: (a) => ('${a.name} (${a.code})', a.centroid),
    );
    expect(out.map((r) => r.$1), ['KLIA (KUL)', 'Mydin Sepang']);
    expect(
      collapseAirports(results, const [], point: (r) => r.$2, text: (r) => r.$1, airport: (_) => results.first),
      results,
    );
  });
}
