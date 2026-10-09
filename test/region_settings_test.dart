import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/home_sections.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Rows as Admin → Country / States / Cities saves them.
final _tables = <String, List<Map<String, dynamic>>>{
  'countries': [
    {
      'name': 'Malaysia',
      'values': {
        'wholeFare': true,
        'biddingEnabled': true,
        'services': jsonEncode({'car': true, 'food': false}),
      },
      'geofence': null,
    },
  ],
  'states': [
    {
      'country': 'Malaysia',
      'name': 'Selangor',
      'values': {'biddingEnabled': false, 'services': '{}', 'pricingOverride': false},
      'geofence': null,
    },
  ],
  'cities': [
    {
      'country': 'Malaysia',
      'state': 'Selangor',
      'name': 'Kajang',
      'values': {
        'services': jsonEncode({'car': true, 'food': true}),
      },
      'geofence': null,
    },
  ],
  'suburbs': <Map<String, dynamic>>[],
};

void main() {
  const point = LatLng(2.99, 101.79);
  const selangor = AreaInfo(country: 'Malaysia', state: 'Selangor', city: 'Shah Alam');
  const kajang = AreaInfo(country: 'Malaysia', state: 'Selangor', city: 'Kajang');

  List<BiddingRegion> regions() => [
    for (final e in _tables.entries)
      for (final r in e.value) BiddingRegion.fromRegionRow(e.key, r)!,
  ];

  test('a region table row reads as the region it names', () {
    final r = regions();
    expect(
      [for (final x in r) '${x.country}/${x.state}/${x.city}'],
      ['Malaysia//', 'Malaysia/Selangor/', 'Malaysia/Selangor/Kajang'],
    );
    expect(r[1].enabled, isFalse);
    expect(r[0].pricing!.wholeFare, isTrue);
    final bounded = BiddingRegion.fromRegionRow('suburbs', {
      'country': 'Malaysia',
      'state': 'Selangor',
      'city': 'Kajang',
      'name': 'Eco Majestic',
      'values': {},
      'geofence': {
        'boundary': jsonEncode({
          'bbox': {'north': 3.0, 'south': 2.9, 'east': 101.8, 'west': 101.7},
        }),
      },
    })!;
    expect(bounded.suburb, 'Eco Majestic');
    expect(bounded.rings.single, hasLength(4));
  });

  test('bidding, pricing and services follow the most specific region that sets them', () {
    final r = regions();
    expect(biddingEnabledAt(r, point, area: selangor), isFalse);
    // Selangor sets no pricing of its own: Malaysia's whole fares apply.
    expect(pricingAt(r, point, area: selangor).wholeFare, isTrue);
    // Selangor switches no service on: Malaysia's list applies…
    expect(servicesAt(r, point, area: selangor), {'car'});
    // …and Kajang's own list wins inside Kajang.
    expect(servicesAt(r, point, area: kajang), {'car', 'food'});
    // Nothing switched on anywhere: every service stays available.
    expect(
      servicesAt(
        [
          BiddingRegion.fromValues({'country': 'Malaysia'})!,
        ],
        point,
        area: selangor,
      ),
      isNull,
    );
  });

  test('a service box linked to a service its region switched off is not available there', () {
    final settings = {
      'serviceBoxes': [
        {'name': 'Ride', 'serviceId': 'car', 'route': '/'},
        {'name': 'Food', 'serviceId': 'food', 'route': '/'},
        {'name': 'Other', 'route': '/'},
      ],
    };
    final boxes = serviceBoxViews(settings, regionServices: {'car'});
    expect(boxes[0].route, isNotNull);
    expect(boxes[1].route, isNull);
    expect(boxes[1].badge, 'SOON');
    expect(boxes[2].route, isNotNull, reason: 'not linked to a service');
    expect(serviceBoxViews(settings)[1].route, isNotNull, reason: 'no region restriction');
  });

  test('the rider app reads the regions from the tables the admin page saves to', () async {
    final asked = <String>[];
    final client = MockClient((req) async {
      final table = req.url.pathSegments.last;
      asked.add(table);
      final rows = _tables[table] ?? const [];
      return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'}, request: req);
    });
    final db = SupabaseClient(
      'http://localhost',
      'anon',
      httpClient: client,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final repo = RideRepository(db);
    expect(await repo.biddingEnabledFor(point, () async => selangor), isFalse);
    expect((await repo.pricingFor(point, () async => selangor)).wholeFare, isTrue);
    expect(await repo.servicesFor(point, () async => kajang), {'car', 'food'});
    expect(asked.toSet(), containsAll(['countries', 'states', 'cities', 'suburbs']));
    // One read serves a pickup's three checks.
    expect(asked.where((t) => t == 'countries'), hasLength(1));
  });

  test('Meter Digital prices on its own rate cards, never on a region\'s pricing', () {
    final meter = Directory('lib/src/features/meter')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in meter) {
      final src = f.readAsStringSync();
      expect(
        src.contains('region_pricing.dart') || src.contains('pricingFor(') || src.contains('roundFare('),
        isFalse,
        reason: f.path,
      );
    }
  });
}
