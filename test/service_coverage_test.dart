// Bolt's "currently unavailable": a pickup, stop or destination outside
// every region the admin set up, or in a blocked one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/ride/unavailable_sheet.dart';
import 'package:latlong2/latlong.dart';

const klcc = LatLng(3.1579, 101.7116);
const AreaInfo kl = AreaInfo(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur');

void main() {
  group('coverage, level by level', () {
    BiddingRegion r(Map<String, dynamic> v) => BiddingRegion.fromValues(v)!;
    final malaysia = r({'country': 'Malaysia'});
    final klState = r({'country': 'Malaysia', 'state': 'Kuala Lumpur'});
    final klCity = r({'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'});
    final perak = r({'country': 'Malaysia', 'state': 'Perak'});
    final ipoh = r({'country': 'Malaysia', 'state': 'Perak', 'city': 'Ipoh'});
    final all = [malaysia, klState, klCity, perak, ipoh];

    test('inside a region at every level set up: served', () {
      expect(coverageGap(all, klcc, area: kl), isNull);
      expect(
        coverageGap(
          all,
          const LatLng(4.6, 101.08),
          area: const AreaInfo(country: 'Malaysia', state: 'Perak', city: 'Ipoh'),
        ),
        isNull,
      );
    });

    test('in no country set up: outside', () {
      final g = coverageGap(all, const LatLng(4.9, 114.9), area: const AreaInfo(country: 'Brunei'));
      expect(g?.gap, CoverageGap.outside);
      expect(g?.region, isNull);
    });

    test("a town its state doesn't list is outside, named by the state (Gerik, Perak)", () {
      final g = coverageGap(
        all,
        const LatLng(5.43, 101.13),
        area: const AreaInfo(country: 'Malaysia', state: 'Perak', city: 'Gerik'),
      );
      expect(g?.gap, CoverageGap.outside);
      expect(g?.region?.name, 'Perak');
    });

    test("a state the country doesn't list is outside, named by the country", () {
      final g = coverageGap(
        all,
        const LatLng(5.3, 103.1),
        area: const AreaInfo(country: 'Malaysia', state: 'Terengganu'),
      );
      expect(g?.gap, CoverageGap.outside);
      expect(g?.region?.name, 'Malaysia');
    });

    test('a level with nothing set up below it is served', () {
      final thailand = r({'country': 'Thailand'});
      expect(
        coverageGap(
          [...all, thailand],
          const LatLng(13.75, 100.5),
          area: const AreaInfo(country: 'Thailand', state: 'Bangkok'),
        ),
        isNull,
      );
    });

    test('a blocked region at any level blocks, named by the most specific blocked one', () {
      final blockedCity = r({'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur', 'blocked': true});
      final g = coverageGap([malaysia, klState, blockedCity], klcc, area: kl);
      expect(g?.gap, CoverageGap.blocked);
      expect(g?.region?.name, 'Kuala Lumpur');

      final blockedCountry = r({'country': 'Malaysia', 'blocked': true});
      expect(coverageGap([blockedCountry, klState, klCity], klcc, area: kl)?.region?.name, 'Malaysia');
    });

    test('a mapped boundary decides without a name, and wins over one', () {
      final box = r({
        'country': 'Malaysia',
        'state': 'Selangor',
        'boundary': '{"bbox":{"north":3.3,"south":3.0,"east":101.8,"west":101.6}}',
      });
      expect(box.rings, isNotEmpty);
      // No state name from the geocoder: the boundary still holds KLCC.
      expect(coverageGap([malaysia, box], klcc, area: const AreaInfo(country: 'Malaysia')), isNull);
      // Named Selangor, but outside its boundary: outside.
      final far = coverageGap(
        [malaysia, box],
        const LatLng(3.6, 101.2),
        area: const AreaInfo(country: 'Malaysia', state: 'Selangor'),
      );
      expect(far?.gap, CoverageGap.outside);
    });

    test('errs towards serving: nothing set up, or a level it cannot tell', () {
      expect(coverageGap(const [], klcc, area: kl), isNull);
      expect(coverageGap(all, const LatLng(4.9, 114.9)), isNull, reason: 'geocode failed');
      expect(
        coverageGap(
          all,
          const LatLng(5.43, 101.13),
          area: const AreaInfo(country: 'Malaysia', state: 'Perak'),
        ),
        isNull,
        reason: 'no city name: the city level is not judged',
      );
    });
  });

  test("the database's refusal (0125) reads back as the point and the reason", () {
    final p = ServiceUnavailableError.parse('SERVICE_UNAVAILABLE:pickup:outside:Perak')!;
    expect((p.at, p.gap, p.region), ('pickup', CoverageGap.outside, 'Perak'));
    final s = ServiceUnavailableError.parse('ERROR: SERVICE_UNAVAILABLE:stop1:blocked:Selangor')!;
    expect((s.at, s.stop, s.gap, s.region), ('stop', 1, CoverageGap.blocked, 'Selangor'));
    final d = ServiceUnavailableError.parse('SERVICE_UNAVAILABLE:drop:outside:')!;
    expect((d.at, d.region), ('drop', null));
    expect(ServiceUnavailableError.parse('duplicate key value'), isNull);
  });

  group('names as the geocoder writes them', () {
    BiddingRegion r(Map<String, dynamic> v) => BiddingRegion.fromValues(v)!;
    final regions = [
      r({'country': 'Malaysia'}),
      r({'country': 'Malaysia', 'state': 'Selangor'}),
      r({'country': 'Malaysia', 'state': 'Selangor', 'city': 'Kajang'}),
      r({'country': 'Malaysia', 'state': 'Kuala Lumpur'}),
      r({'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'}),
      r({'country': 'Malaysia', 'state': 'Johor'}),
      r({'country': 'Malaysia', 'state': 'Johor', 'city': 'Johor Bahru'}),
    ];

    test('administrative wording is not part of the name', () {
      expect(placeNameKey('Kajang Municipal Council'), 'kajang');
      expect(placeNameKey('Majlis Perbandaran Kajang'), 'kajang');
      expect(placeNameKey('Wilayah Persekutuan Kuala Lumpur'), 'kuala lumpur');
      expect(placeNameKey('Negeri Sembilan'), 'negeri sembilan', reason: 'part of a name stays');
      expect(placeNameMatches('Kajang', 'Kajang Municipal Council'), isTrue);
      expect(placeNameMatches('Johor Bahru', 'Johor'), isFalse, reason: 'the whole region name must appear');
      expect(placeNameMatches('Jaya', 'Petaling Jaya'), isTrue);
      expect(placeNameMatches('Alam', 'Shah Alam'), isTrue);
      expect(placeNameMatches('Kota', 'Kotabaru'), isFalse, reason: 'whole words only');
    });

    test('a Kajang pickup the geocoder calls "Kajang Municipal Council" is served', () {
      const kajang = AreaInfo(country: 'Malaysia', state: 'Selangor', city: 'Kajang Municipal Council');
      expect(coverageGap(regions, const LatLng(2.99, 101.79), area: kajang), isNull);
      const kl = AreaInfo(country: 'Malaysia', state: 'Wilayah Persekutuan Kuala Lumpur', city: 'Kuala Lumpur');
      expect(coverageGap(regions, klcc, area: kl), isNull);
    });

    test('a name in another script cannot be compared: that level is served', () {
      expect(comparablePlaceName('吉隆坡'), isFalse);
      expect(comparablePlaceName('Kuala Lumpur'), isTrue);
      const zh = AreaInfo(country: 'Malaysia', state: 'Kuala Lumpur', city: '吉隆坡');
      expect(coverageGap(regions, klcc, area: zh), isNull);
    });

    test('a town its state does not list is still outside', () {
      const kulai = AreaInfo(country: 'Malaysia', state: 'Johor', city: 'Kulai');
      expect(coverageGap(regions, const LatLng(1.66, 103.6), area: kulai)?.region?.name, 'Johor');
    });
  });

  test('the wording names the point and the way out', () {
    final p = unavailableCopy(UnavailableAt.pickup, CoverageGap.outside);
    expect(p.message, "We don't pick up there yet. Try changing your pickup.");
    expect(p.action, 'Change pickup');
    final d = unavailableCopy(UnavailableAt.drop, CoverageGap.blocked, region: 'Selangor');
    expect(d.message, 'GET.ride is paused in Selangor right now. Try changing your destination.');
    expect(d.action, 'Change destination');
    expect(
      unavailableCopy(UnavailableAt.pickup, CoverageGap.outside, region: 'Perak').message,
      "GET.ride doesn't run in that part of Perak yet. Try changing your pickup.",
    );
    final s = unavailableCopy(UnavailableAt.stop, CoverageGap.outside);
    expect(s.message, "We don't go there yet. Try removing or changing the stop.");
    expect(s.action, 'Remove stop');
  });

  test('the admin Block switch round-trips', () {
    final f = RegionForm.fromEntry(RegionEntry(id: 'x', values: {'country': 'Malaysia', 'blocked': true}));
    expect(f.blocked, isTrue);
    f.blocked = false;
    expect(f.toValues()['blocked'], isFalse);
    expect(RegionForm.fromEntry(RegionEntry(id: 'y', values: {'country': 'Malaysia'})).blocked, isFalse);
  });

  test('a sub-service switched off in a region, or anything above it; the most specific region decides', () {
    BiddingRegion r(Map<String, dynamic> v) => BiddingRegion.fromValues(v)!;
    final now = DateTime.utc(2026, 10, 16, 3);
    final state = r({'country': 'Malaysia', 'state': 'Johor', 'subServices': {'ride': false}});
    final city = r({'country': 'Malaysia', 'state': 'Johor', 'city': 'Johor Bahru', 'subServices': '{"ride": true}'});
    final ctx = RegionRuleContext([state]);
    expect(ctx.available(types: {'car'}, vehicleType: 'ride', nowUtc: now), isFalse);
    expect(ctx.available(types: {'car'}, vehicleType: 'comfort', nowUtc: now), isTrue);
    expect(
      ctx.available(types: {'car'}, vehicleType: 'ride-xl', lineage: ['ride-xl', 'ride', 'car'], nowUtc: now),
      isFalse,
      reason: 'under Ride, which is off',
    );
    expect(RegionRuleContext([city, state]).available(types: {'car'}, vehicleType: 'ride', nowUtc: now), isTrue);
    final f = RegionForm.fromEntry(
      RegionEntry(id: 'x', values: {'country': 'Malaysia', 'subServices': {'ride': false}}),
    );
    expect(f.subServices, {'ride': false});
    expect(f.toValues()['subServices'], {'ride': false});
  });

  group('Block for pickups, drop-offs or both (0212)', () {
    BiddingRegion r(Map<String, dynamic> v) => BiddingRegion.fromValues(v)!;
    List<BiddingRegion> withKl(Map<String, dynamic> block) => [
      r({'country': 'Malaysia'}),
      r({'country': 'Malaysia', 'state': 'Kuala Lumpur', ...block}),
    ];

    test('pickups only: no ride starts there, stops and ends still can', () {
      final regions = withKl({'blockAt': 'pickup'});
      expect(coverageGap(regions, klcc, area: kl)?.gap, CoverageGap.blocked);
      expect(coverageGap(regions, klcc, area: kl, pickup: false), isNull);
    });

    test('drop-offs only: rides start there, none stops or ends there', () {
      final regions = withKl({'blockAt': 'drop'});
      expect(coverageGap(regions, klcc, area: kl), isNull);
      final g = coverageGap(regions, klcc, area: kl, pickup: false);
      expect([g?.gap, g?.region?.block], [CoverageGap.blocked, RegionBlock.drop]);
    });

    test('both, and the old switch, block either way; none is open', () {
      for (final block in [
        {'blockAt': 'both'},
        {'blocked': true},
      ]) {
        final regions = withKl(block);
        expect(coverageGap(regions, klcc, area: kl)?.gap, CoverageGap.blocked, reason: '$block');
        expect(coverageGap(regions, klcc, area: kl, pickup: false)?.gap, CoverageGap.blocked, reason: '$block');
      }
      expect(coverageGap(withKl({'blockAt': 'none', 'blocked': false}), klcc, area: kl, pickup: false), isNull);
    });

    test('the sheet says which', () {
      expect(
        unavailableCopy(UnavailableAt.pickup, CoverageGap.blocked, region: 'Johor', block: RegionBlock.pickup).message,
        "GET.ride doesn't pick up in Johor right now. Try changing your pickup.",
      );
      expect(
        unavailableCopy(UnavailableAt.stop, CoverageGap.blocked, region: 'Penang', block: RegionBlock.drop).message,
        "GET.ride doesn't drop off in Penang right now. Try removing or changing the stop.",
      );
    });

    test('the admin form saves which, the old switch only for both', () {
      final f = RegionForm.fromEntry(RegionEntry(id: 'x', values: {'country': 'Malaysia', 'blocked': true}));
      expect([f.blocked, f.blockAt], [true, RegionBlock.both], reason: 'the old Block is both');
      f.blockAt = RegionBlock.pickup;
      expect([f.toValues()['blocked'], f.toValues()['blockAt']], [false, 'pickup']);
      f.blockAt = RegionBlock.both;
      expect([f.toValues()['blocked'], f.toValues()['blockAt']], [true, 'both']);
      f.blocked = false;
      expect([f.toValues()['blocked'], f.toValues()['blockAt']], [false, 'none']);
      final drop = RegionForm.fromEntry(RegionEntry(id: 'y', values: {'country': 'Malaysia', 'blockAt': 'drop'}));
      expect([drop.blocked, drop.blockAt], [true, RegionBlock.drop]);
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('slides up from the bottom; the button changes the point (${brightness.name})', (tester) async {
      var changed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showServiceUnavailable(
                    context,
                    at: UnavailableAt.drop,
                    gap: CoverageGap.outside,
                    onChange: () => changed++,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-animation it is still coming up from below.
      final sheet = find.byKey(const ValueKey('service-unavailable'));
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final midway = tester.getTopLeft(sheet).dy;
      await tester.pumpAndSettle();
      final settled = tester.getTopLeft(sheet).dy;
      expect(midway, greaterThan(settled), reason: 'it rises into place');
      expect(tester.getBottomLeft(sheet).dy, closeTo(screen.height, 1), reason: 'anchored to the bottom edge');
      expect(find.text('Unfortunately, GET.ride is currently unavailable'), findsOneWidget);
      expect(find.text('Change destination'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('service-unavailable-change')));
      await tester.pumpAndSettle();
      expect(changed, 1);
      expect(sheet, findsNothing, reason: 'closed on the way to the change');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('service-unavailable-close')));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(changed, 1, reason: 'closing changes nothing');
    });
  }
}
