import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/push_area.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const klcc = LatLng(3.1579, 101.7116);
  const regions = [
    BiddingRegion(country: 'Malaysia'),
    BiddingRegion(country: 'Malaysia', state: 'Selangor'),
    BiddingRegion(country: 'Malaysia', state: 'Selangor', city: 'Shah Alam'),
    BiddingRegion(country: 'Malaysia', state: 'Wilayah Persekutuan'),
    BiddingRegion(country: 'Malaysia', state: 'Wilayah Persekutuan', city: 'Kuala Lumpur'),
    BiddingRegion(country: 'Malaysia', state: 'Wilayah Persekutuan', city: 'Kuala Lumpur', suburb: 'Bukit Bintang'),
    BiddingRegion(country: 'Singapore'),
  ];

  group('PushArea', () {
    test('everywhere sends no area', () {
      const a = PushArea.everywhere();
      expect(a.complete, isTrue);
      expect(a.toJson(), isNull);
      expect(a.label, '');
    });

    test('a region needs a country, and leaves out the levels it does not name', () {
      expect(const PushArea.region(country: '').complete, isFalse);
      const a = PushArea.region(country: 'Malaysia', state: 'Selangor');
      expect(a.toJson(), {'country': 'Malaysia', 'state': 'Selangor'});
      expect(a.label, 'in Selangor, Malaysia');
      expect(PushArea.fromJson(a.toJson()), a);
    });

    test('a radius needs a point and a sane distance', () {
      expect(const PushArea.radius().complete, isFalse);
      expect(const PushArea.radius(lat: 3.1, lng: 101.7, radiusKm: 600).complete, isFalse);
      const a = PushArea.radius(lat: 3.139, lng: 101.6869, radiusKm: 5);
      expect(a.complete, isTrue);
      expect(a.toJson(), {'lat': 3.139, 'lng': 101.6869, 'radiusKm': 5.0});
      expect(a.label, 'within 5 km of 3.1390, 101.6869');
      expect(PushArea.fromJson(a.toJson()), a);
    });

    test('anything unreadable is everywhere', () {
      expect(PushArea.fromJson(null), const PushArea.everywhere());
      expect(PushArea.fromJson({'state': 'Selangor'}), const PushArea.everywhere());
    });
  });

  test('the region picker offers each level of the admin\'s Regions, once, sorted', () {
    var c = pushRegionChoices(regions, const PushArea.region(country: ''));
    expect(c.countries, ['Malaysia', 'Singapore']);
    expect(c.states, isEmpty);
    c = pushRegionChoices(regions, const PushArea.region(country: 'malaysia'));
    expect(c.states, ['Selangor', 'Wilayah Persekutuan']);
    c = pushRegionChoices(regions, const PushArea.region(country: 'Malaysia', state: 'Wilayah Persekutuan'));
    expect(c.cities, ['Kuala Lumpur']);
    c = pushRegionChoices(
      regions,
      const PushArea.region(country: 'Malaysia', state: 'Wilayah Persekutuan', city: 'Kuala Lumpur'),
    );
    expect(c.suburbs, ['Bukit Bintang']);
  });

  test('the reach line', () {
    const kl = PushArea.region(country: 'Malaysia', city: 'Kuala Lumpur');
    expect(
      pushReachText({'recipients': 12, 'accounts': 10}, const PushArea.everywhere()),
      'Reaches 10 people on 12 devices.',
    );
    expect(
      pushReachText({'recipients': 1, 'accounts': 1, 'unlocated': 4}, kl),
      'Reaches 1 person on 1 device in Kuala Lumpur, Malaysia. 4 devices have no known location yet and are left out.',
    );
    expect(
      pushReachText({'recipients': 0, 'unlocated': 1}, kl),
      'Nobody in Kuala Lumpur, Malaysia would get this. 1 device has no known location yet and is left out.',
    );
  });

  group('where a phone says it is', () {
    test('the admin\'s spelling of the region it is in', () {
      const area = AreaInfo(country: 'malaysia', state: 'wilayah persekutuan', city: 'kuala lumpur', suburb: 'KLCC');
      final p = pushPlaceAt(regions, klcc, area);
      expect(p.country, 'Malaysia');
      expect(p.state, 'Wilayah Persekutuan');
      expect(p.city, 'Kuala Lumpur');
      // Suburbs only match by boundary: the geocoder's name is kept.
      expect(p.suburb, 'KLCC');
    });

    test('the geocoder\'s names where no region matches, none without them', () {
      const area = AreaInfo(country: 'Thailand', state: 'Bangkok');
      expect(pushPlaceAt(regions, klcc, area), (country: 'Thailand', state: 'Bangkok', city: null, suburb: null));
      expect(pushPlaceAt(regions, klcc, null), (country: null, state: null, city: null, suburb: null));
    });

    test('a mapped boundary wins over the names', () {
      final mapped = [
        ...regions,
        const BiddingRegion(
          country: 'Malaysia',
          state: 'Wilayah Persekutuan',
          city: 'Kuala Lumpur',
          suburb: 'KLCC',
          rings: [
            [LatLng(3.15, 101.70), LatLng(3.15, 101.72), LatLng(3.17, 101.72), LatLng(3.17, 101.70)],
          ],
        ),
      ];
      expect(regionAt(mapped, klcc)?.suburb, 'KLCC');
      expect(pushPlaceAt(mapped, klcc, const AreaInfo(country: 'Malaysia')).suburb, 'KLCC');
    });
  });

  test('a phone re-reports only when it moved or the last report is old', () {
    final t0 = DateTime(2026, 10, 13, 9);
    expect(shouldReportPushLocation(point: klcc, now: t0), isTrue);
    expect(
      shouldReportPushLocation(point: klcc, now: t0.add(const Duration(minutes: 5)), lastPoint: klcc, lastAt: t0),
      isFalse,
    );
    expect(
      shouldReportPushLocation(point: klcc, now: t0.add(const Duration(minutes: 31)), lastPoint: klcc, lastAt: t0),
      isTrue,
    );
    const twoKmAway = LatLng(3.1759, 101.7116);
    expect(
      shouldReportPushLocation(point: twoKmAway, now: t0.add(const Duration(minutes: 5)), lastPoint: klcc, lastAt: t0),
      isTrue,
    );
  });
}
