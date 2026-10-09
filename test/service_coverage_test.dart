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
