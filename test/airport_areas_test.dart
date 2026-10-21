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
    final out = collapseIntoAreas<(String, LatLng)>(
      results,
      [klia],
      point: (r) => r.$2,
      text: (r) => r.$1,
      area: (a, _) => ('${a.name} (${a.code})', a.centroid),
    );
    expect(out.map((r) => r.$1), ['KLIA (KUL)', 'Mydin Sepang']);
    expect(
      collapseIntoAreas(results, const [], point: (r) => r.$2, text: (r) => r.$1, area: (_, _) => results.first),
      results,
    );
  });

  test('an airport code matches only as a whole word: KUA is not in Kuala Lumpur', () {
    const kua = AirportArea(
      id: 'kua',
      name: 'Sultan Ahmad Shah Airport',
      code: 'KUA',
      rings: [],
      north: 3.78,
      south: 3.77,
      east: 103.21,
      west: 103.20,
    );
    expect(kua.matchesName('KLCC Kuala Lumpur City Centre, 50088 Kuala Lumpur'), isFalse);
    expect(kua.matchesName('Kuantan'), isFalse);
    expect(kua.matchesName('KUA'), isTrue);
    expect(kua.matchesName('Sultan Ahmad Shah Airport, Kuantan'), isTrue);
    expect(kua.matchesName('Kuantan Airport KUA'), isTrue);
    final results = [('KLCC', const LatLng(3.1579, 101.7116)), ('Suria KLCC, Kuala Lumpur', const LatLng(3.158, 101.712))];
    expect(
      collapseIntoAreas(results, const [kua], point: (r) => r.$2, text: (r) => r.$1, area: (_, _) => ('KUA', const LatLng(0, 0))),
      results,
    );
  });

  group('grouping search results into an area', () {
    String shape(double n, double s, double e, double w) => jsonEncode({
      'coords': [
        {'latitude': n, 'longitude': w},
        {'latitude': n, 'longitude': e},
        {'latitude': s, 'longitude': e},
        {'latitude': s, 'longitude': w},
      ],
      'bbox': {'north': n, 'south': s, 'east': e, 'west': w},
    });
    final airport = AirportArea.fromEntry('klia', {
      'name': 'KLIA',
      'code': 'KUL',
      'groupWords': [' KLIA2 ', 'klia2', ''],
      'boundary': shape(2.75, 2.73, 101.72, 101.70),
    })!;
    // A mall's boundary, about 1 km a side, grouping its results.
    Map<String, dynamic> mall({Object? on = true, Object? words}) => {
      'name': 'Mid Valley Megamall',
      'groupResults': on,
      'groupWords': words,
      'address': 'Lingkaran Syed Putra',
      'lat': '3.1178',
      'lon': 101.6772,
      'placeType': 'mall',
      'boundary': shape(3.122, 3.113, 101.682, 101.672),
    };
    final midValley = AirportArea.fromEntry('mv', mall(words: ['the gardens']), kind: AreaKind.place, sizeM2: 1e6)!;

    // (text, position or null for a suggestion); an area's entry is its
    // name and how many were folded into it.
    List<String> collapse(List<(String, LatLng?)> results, List<AirportArea> areas) => [
      for (final r in collapseIntoAreas<(String, LatLng?)>(
        results,
        areas,
        point: (r) => r.$2,
        text: (r) => r.$1,
        area: (a, n) => ('${a.name} +$n', null),
      ))
        r.$1,
    ];

    test('the switch and words as stored: airports on, places off unless set', () {
      expect(airport.groupResults, isTrue);
      expect(airport.groupWords, ['klia2'], reason: 'trimmed, lower case, no repeats or blanks');
      expect(AirportArea.fromEntry('k', {'groupResults': false, 'boundary': shape(1, 0, 1, 0)})!.groupResults, isFalse);
      expect(AirportArea.fromEntry('p', {'boundary': shape(1, 0, 1, 0)}, kind: AreaKind.place)!.groupResults, isFalse);
      expect(midValley.groupResults, isTrue);
      expect(midValley.address, 'Lingkaran Syed Putra');
      expect(midValley.point, const LatLng(3.1178, 101.6772));
      expect(midValley.placeType, 'mall');
      expect(parseGroupResults('off'), isFalse);
      expect(parseGroupResults(null), isNull);
      expect(parseGroupWords(['Terminal  2', 'terminal 2', 3]), ['terminal 2', '3']);
    });

    test('inside by position, by name or code, by a word; a suggestion by its words only', () {
      final out = collapse([
        ('Mydin Sepang', const LatLng(2.80, 101.70)),
        ('Jalan KLIA 1', const LatLng(2.74, 101.71)), // inside
        ('Arrival Hall, KUL', const LatLng(3.5, 101.0)), // its code, elsewhere
        ('klia2 Arrival Lane', null), // a suggestion: its word
        ('Gateway@klia2, Sepang', null),
        ('Departure Hall', null), // a suggestion with no word: left alone
        ('Kuala Lumpur Sentral', null),
      ], [airport]);
      expect(out, ['Mydin Sepang', 'KLIA +4', 'Departure Hall', 'Kuala Lumpur Sentral']);
    });

    test('a place groups the shops inside it and its words, when switched on', () {
      final results = <(String, LatLng?)>[
        ('Uniqlo', const LatLng(3.118, 101.677)),
        ('Bangsar Village', const LatLng(3.130, 101.670)),
        ('The Gardens Mall', null),
        ('Mid Valley Megamall', null),
      ];
      expect(collapse(results, [midValley]), ['Mid Valley Megamall +3', 'Bangsar Village']);
      final off = AirportArea.fromEntry('mv', mall(on: false, words: ['the gardens']), kind: AreaKind.place)!;
      expect(collapse(results, [off]), results.map((r) => r.$1), reason: 'switched off: every result as it is');
      final airportOff = AirportArea.fromEntry('k', {'name': 'KLIA', 'groupResults': 'false', 'boundary': shape(2.75, 2.73, 101.72, 101.70)})!;
      expect(collapse([('Jalan KLIA 1', const LatLng(2.74, 101.71))], [airportOff]), ['Jalan KLIA 1']);
    });

    test('a result folds into the first area only: airports first, then the smallest place', () {
      // A hotel inside both the airport and a place drawn over it.
      final hotel = AirportArea.fromEntry(
        'hotel',
        {'name': 'Sama-Sama Hotel', 'groupResults': true, 'boundary': shape(2.745, 2.735, 101.715, 101.705)},
        kind: AreaKind.place,
        sizeM2: 1e4,
      )!;
      final out = collapse([
        ('Sama-Sama Hotel lobby', const LatLng(2.74, 101.71)),
        ('Sama-Sama Hotel, Sepang', null),
      ], [hotel, airport]);
      expect(out, ['KLIA +1', 'Sama-Sama Hotel +1'], reason: 'the lobby is in KLIA; the suggestion names the hotel');
      // Two places: the smaller one wins, and each result counts once.
      final big = AirportArea.fromEntry('big', mall(), kind: AreaKind.place, sizeM2: 1e6)!;
      final small = AirportArea.fromEntry(
        'small',
        {'name': 'Food Court', 'groupResults': true, 'boundary': shape(3.119, 3.117, 101.678, 101.676)},
        kind: AreaKind.place,
        sizeM2: 100,
      )!;
      expect(collapse([('Stall 4', const LatLng(3.118, 101.677)), ('Uniqlo', const LatLng(3.121, 101.680))], [big, small]), [
        'Food Court +1',
        'Mid Valley Megamall +1',
      ]);
    });

    test('a place has no 300 m margin; an airport keeps it', () {
      final justOut = const LatLng(3.1235, 101.677); // ~170 m north of the mall
      expect(collapse([('Shop', justOut)], [midValley]), ['Shop']);
      expect(collapse([('Shop', const LatLng(2.752, 101.71))], [airport]), ['KLIA +1']);
    });
  });
}
