import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:latlong2/latlong.dart';

// Rows as `regions_at` (migration 0169) returns them for a pickup in Kuala
// Lumpur: the server has tested each mapped boundary against the point.
Map<String, dynamic> row(
  String table, {
  String country = 'Malaysia',
  String state = '',
  String city = '',
  Map<String, dynamic> values = const {},
  bool? inside,
}) => {
  'region_table': table,
  'country': country,
  'state': state,
  'city': city,
  'suburb': '',
  'values': values,
  'has_boundary': inside != null,
  'inside': inside,
};

void main() {
  const kl = LatLng(3.1478, 101.6953);

  group('regionFromLookupRow', () {
    test('settings and path from the row, the boundary as the server answer', () {
      final r = regionFromLookupRow(
        row('states', state: 'Selangor', values: {'biddingEnabled': false, 'boundary': '{"coords":[]}'}, inside: true),
      )!;
      expect(r.country, 'Malaysia');
      expect(r.state, 'Selangor');
      expect(r.enabled, isFalse);
      expect(r.rings, isEmpty);
      expect(r.hasBoundary, isTrue);
      expect(r.covers(kl), isTrue);
    });

    test('no boundary: left to its names', () {
      final r = regionFromLookupRow(row('countries'))!;
      expect(r.hasBoundary, isFalse);
      expect(r.covers(kl), isNull);
    });

    test('no country, no region', () {
      expect(regionFromLookupRow(row('countries', country: ' ')), isNull);
    });
  });

  group('rules from a list read by point', () {
    // The live set-up that lost its rounding: Malaysia (mapped) rounds
    // fares up; Selangor (mapped) leaves pricing to it.
    final regions = [
      regionFromLookupRow(row('countries', values: {'wholeFare': true, 'biddingEnabled': false}, inside: true))!,
      regionFromLookupRow(
        row('states', state: 'Selangor', values: {'pricingOverride': false, 'biddingEnabled': true}, inside: true),
      )!,
      regionFromLookupRow(row('states', state: 'Johor', values: {'pricingOverride': true}, inside: false))!,
    ];

    test('the country rounds fares up, even when the geocoder gives nothing', () {
      expect(pricingAt(regions, kl).wholeFare, isTrue);
      expect(pricingAt(regions, kl).fareDecimals, 0);
      expect(pricingAt(regions, kl).roundFare(56.10), 57);
    });

    test('the most specific region holding the point decides bidding', () {
      expect(biddingByBoundary(regions, kl), isTrue);
      expect(regionAt(regions, kl)?.state, 'Selangor');
    });

    test('a mapped region the point is outside is not matched by its name', () {
      final around = regionsAround(
        regions,
        kl,
        area: const AreaInfo(country: 'Malaysia', state: 'Johor'),
      );
      expect(around.map((r) => r.state), isNot(contains('Johor')));
    });

    test('nothing mapped holds it: none', () {
      final outside = [
        regionFromLookupRow(row('countries', values: {'wholeFare': true}, inside: false))!,
      ];
      expect(pricingAt(outside, kl), RegionPricing.none);
    });
  });

  test('lookups are kept per ~11 m cell', () {
    expect(regionLookupKey(const LatLng(3.14781, 101.69532)), regionLookupKey(const LatLng(3.14779, 101.69529)));
    expect(regionLookupKey(const LatLng(3.1478, 101.6953)), isNot(regionLookupKey(const LatLng(3.1490, 101.6953))));
  });
}
