// Place fees follow-ups (migration 0325), light and dark: the place's
// outline on the rider's map (on or off by the admin's showOutline), the
// admin's switch for it, and the driver's scheduled rides with the place
// fees a booking locked in their total.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/place_fees_tab.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/airport_areas.dart';
import 'package:get_ride/src/core/place_fees.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:get_ride/src/features/partner/scheduled_jobs_screen.dart';
import 'package:get_ride/src/features/ride/place_fee_parts.dart';
import 'package:latlong2/latlong.dart';

Map<String, dynamic> _box(double n, double s, double e, double w) => {
  'coords': [
    {'latitude': n, 'longitude': w},
    {'latitude': n, 'longitude': e},
    {'latitude': s, 'longitude': e},
    {'latitude': s, 'longitude': w},
  ],
  'bbox': {'north': n, 'south': s, 'east': e, 'west': w},
};

final _klia = AirportArea.fromEntry('klia', {'name': 'KLIA', 'boundary': _box(2.83, 2.70, 101.76, 101.64)})!;

/// A mall in two pieces: the shops and the car park across the road.
final _mall = AirportArea.fromEntry('mall', {
  'name': 'Mall',
  'boundary': {
    ..._box(3.16, 3.14, 101.72, 101.70),
    'polygons': [
      [
        {'latitude': 3.16, 'longitude': 101.70},
        {'latitude': 3.16, 'longitude': 101.71},
        {'latitude': 3.15, 'longitude': 101.71},
        {'latitude': 3.15, 'longitude': 101.70},
      ],
      [
        {'latitude': 3.145, 'longitude': 101.715},
        {'latitude': 3.145, 'longitude': 101.72},
        {'latitude': 3.14, 'longitude': 101.72},
        {'latitude': 3.14, 'longitude': 101.715},
      ],
    ],
  },
}, kind: AreaKind.place)!;

class _FakeRepo implements ScheduledRideRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _kliaPoint = LatLng(2.75, 101.70);
const _mallShops = LatLng(3.155, 101.705);
const _town = LatLng(3.0, 101.5);

PlaceFeesQuote _quote({bool outline = true, List<Map<String, dynamic>>? lines}) => PlaceFeesQuote.fromJson({
  'lines':
      lines ??
      [
        {'name': 'KLIA kerbside fee', 'value': 5, 'airport': 'pick', 'place_fee': 'f1', 'area': 'klia'},
        {'name': 'Mall entry', 'value': 2, 'airport': 'drop', 'place_fee': 'f2', 'area': 'mall'},
      ],
  'total': 7,
  'pickup': {
    'area_id': 'klia',
    'name': 'KLIA',
    'fees': [
      {'name': 'KLIA kerbside fee', 'amount': 5},
    ],
  },
  'drop': {
    'area_id': 'mall',
    'name': 'Mall',
    'fees': [
      {'name': 'Mall entry', 'amount': 2},
    ],
  },
  'settings': {'showOutline': outline},
});

void main() {
  group('pure', () {
    test('showOutline: on by default, kept, sent', () {
      expect(PlaceFeeSettings.defaults.showOutline, isTrue);
      expect(PlaceFeeSettings.fromJson({'showOutline': false}).showOutline, isFalse);
      expect(PlaceFeeSettings.fromJson({'showOutline': 'x'}).showOutline, isTrue);
      expect(PlaceFeeSettings.defaults.copyWith(showOutline: false).toJson()['showOutline'], isFalse);
      expect(PlaceFeesQuote.fromJson({'settings': {}}).display.showOutline, isTrue);
      expect(_quote(outline: false).display.showOutline, isFalse);
    });

    test('the outlines: the piece of each place an end is in, once', () {
      final rings = placeFeeOutlineRings(_quote(), [_klia, _mall], pickup: _kliaPoint, drop: _mallShops);
      expect(rings.length, 2);
      expect(identical(rings[0], _klia.rings.first), isTrue);
      expect(identical(rings[1], _mall.rings.first), isTrue, reason: 'the shops, not the car park');
    });

    test('none when the admin turned it off, the quote is empty or the area is unknown', () {
      expect(placeFeeOutlineRings(_quote(outline: false), [_klia, _mall], pickup: _kliaPoint, drop: _mallShops), isEmpty);
      expect(placeFeeOutlineRings(PlaceFeesQuote.none, [_klia], pickup: _kliaPoint, drop: _town), isEmpty);
      expect(placeFeeOutlineRings(_quote(), const [], pickup: _kliaPoint, drop: _mallShops), isEmpty);
    });

    test('a counted stop inside the place; one outside it adds nothing', () {
      final q = _quote(lines: [
        {'name': 'Mall entry', 'value': 2, 'airport': 'stop', 'place_fee': 'f2', 'area': 'mall'},
      ]);
      expect(placeFeeOutlineRings(q, [_mall], pickup: _town, drop: _town, stops: [_mallShops]).length, 1);
      expect(placeFeeOutlineRings(q, [_mall], pickup: _town, drop: _town, stops: [_town]), isEmpty);
    });

    test('either end, charged once: the end that is in it', () {
      final q = PlaceFeesQuote.fromJson({
        'lines': [
          {'name': 'KLIA fee', 'value': 4, 'airport': 'once', 'place_fee': 'f3', 'area': 'klia'},
        ],
        'drop': {
          'area_id': 'klia',
          'name': 'KLIA',
          'fees': [
            {'name': 'KLIA fee', 'amount': 4},
          ],
        },
      });
      final rings = placeFeeOutlineRings(q, [_klia], pickup: _town, drop: _kliaPoint);
      expect(rings.length, 1);
      expect(identical(rings.single, _klia.rings.first), isTrue);
    });

    test("a driver's booking: the locked fees from the server's lists", () {
      final lines = [
        {'name': 'KLIA kerbside fee', 'value': 5, 'airport': 'pick', 'place_fee': 'f1', 'goes_to': 'pass', 'locked': true},
      ];
      final up = UpcomingBooking.fromRow({'id': 'd1', 'pickup_at': '2026-10-16T01:30:00Z', 'fare': 20, 'place_fees': lines});
      expect(up.ride.placeFees.single.label, 'KLIA kerbside fee (pickup)');
      expect(up.ride.total, 25);
      final mine = ScheduledRide.fromRow({'id': 'd2', 'pickup_at': '2026-10-16T01:30:00Z', 'fare': 20, 'place_fee_lines': lines});
      expect(mine.total, 25);
      final offer = ScheduledOffer.fromRow({
        'id': 'o1',
        'scheduled_ride_id': 'd3',
        'kind': 'assign',
        'incoming': true,
        'expires_at': '2026-10-16T01:10:00Z',
        'pickup_at': '2026-10-16T01:30:00Z',
        'fare': 20,
        'place_fees': lines,
      });
      expect(offer.ride.total, 25);
      expect(ScheduledRide.fromRow({'id': 'd4', 'pickup_at': '2026-10-16T01:30:00Z', 'fare': 20}).placeFees, isEmpty);
    });
  });

  for (final b in Brightness.values) {
    group('${b.name} mode', () {
      Future<void> pumpMap(WidgetTester tester, List<List<LatLng>> rings) async {
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Scaffold(
            body: FlutterMap(
              options: const MapOptions(initialCenter: _kliaPoint, initialZoom: 12),
              children: [
                Builder(builder: (context) => Stack(children: placeFeeOutlineLayers(context, rings))),
              ],
            ),
          ),
        ));
        await tester.pump();
      }

      testWidgets('the outline on the map when the setting is on', (tester) async {
        await pumpMap(tester, placeFeeOutlineRings(_quote(), [_klia, _mall], pickup: _kliaPoint, drop: _mallShops));
        final layer = tester.widget<PolygonLayer>(find.byKey(const ValueKey('place-fee-outline')));
        expect(layer.polygons.length, 2);
        final primary = appTheme(b).colorScheme.primary;
        expect(layer.polygons.first.color, primary.withValues(alpha: 0.10), reason: 'lightly filled in the accent');
        expect(layer.polygons.first.borderColor, primary.withValues(alpha: 0.75));
        expect(tester.takeException(), isNull);
      });

      testWidgets('no outline when the setting is off', (tester) async {
        await pumpMap(
          tester,
          placeFeeOutlineRings(_quote(outline: false), [_klia, _mall], pickup: _kliaPoint, drop: _mallShops),
        );
        expect(find.byKey(const ValueKey('place-fee-outline')), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('admin: "Show the place outline on the map"', (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 2600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        PlaceFeeSettings? saved;
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Scaffold(
            body: PlaceFeeSettingsForm(settings: PlaceFeeSettings.defaults, onSave: (s) => saved = s),
          ),
        ));
        expect(find.text('Show the place outline on the map'), findsOneWidget);
        final sw = find.descendant(of: find.byKey(const ValueKey('place-fee-show-outline')), matching: find.byType(Switch));
        await tester.ensureVisible(sw);
        await tester.tap(sw);
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('place-fee-settings-save')));
        await tester.tap(find.byKey(const ValueKey('place-fee-settings-save')));
        await tester.pump();
        expect(saved?.showOutline, isFalse);
        expect(saved?.toJson()['showOutline'], isFalse);
        expect(tester.takeException(), isNull);
      });

      testWidgets("driver's scheduled rides: the total and lines with the locked place fees", (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final at = DateTime.now().add(const Duration(hours: 3)).toUtc().toIso8601String();
        final lines = [
          {'name': 'KLIA kerbside fee', 'value': 5, 'airport': 'pick', 'place_fee': 'f1', 'goes_to': 'pass', 'locked': true},
          {'name': 'Driver fee', 'value': 3, 'airport': 'drop', 'place_fee': 'f2', 'goes_to': 'driver', 'locked': true},
        ];
        final upcoming = UpcomingBooking.fromRow({
          'id': 'u1',
          'pickup_at': at,
          'fare': 20,
          'currency': 'MYR',
          'pickup_address': 'KLIA',
          'drop_address': 'Town',
          'place_fees': lines,
        });
        final mine = ScheduledRide.fromRow({
          'id': 'm1',
          'pickup_at': at,
          'status': 'assigned',
          'fare': 30,
          'currency': 'MYR',
          'place_fee_lines': lines.sublist(0, 1),
        });
        final offer = ScheduledOffer.fromRow({
          'id': 'o1',
          'scheduled_ride_id': 'r1',
          'kind': 'assign',
          'incoming': true,
          'expires_at': at,
          'pickup_at': at,
          'fare': 10,
          'currency': 'MYR',
          'place_fees': lines.sublist(1),
        });
        Widget app() => ProviderScope(
          overrides: [
            scheduledRideRepositoryProvider.overrideWithValue(_FakeRepo()),
            scheduledRidesConfigProvider.overrideWith(
              (_) async => const ScheduledRidesConfig(enabled: true, releaseMinutes: 20, interestNoticeMinutes: 60),
            ),
            upcomingBookingsProvider.overrideWith((_) async => [upcoming]),
            acceptedScheduledRidesProvider.overrideWith((_) async => [mine]),
            scheduledOffersProvider.overrideWith((_) async => [offer]),
          ],
          child: MaterialApp(theme: appTheme(b), home: const ScheduledJobsScreen()),
        );

        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('scheduled-total-u1'))).data,
          contains('28.00'),
          reason: 'the fare and the place fees, as the rider sees it',
        );
        final text = tester.widget<Text>(find.byKey(const ValueKey('scheduled-place-fees-u1'))).data!;
        expect(text, contains('+ KLIA kerbside fee (pickup)'));
        expect(text, contains('(passed on)'));
        expect(text, contains('+ Driver fee (drop-off)'));
        expect(RegExp(r'\(passed on\)').allMatches(text).length, 1, reason: "the driver's own fee is not passed on");
        final style = tester.widget<Text>(find.byKey(const ValueKey('scheduled-place-fees-u1'))).style;
        expect(style?.color, appTheme(b).colorScheme.onSurfaceVariant);

        await tester.tap(find.byKey(const ValueKey('scheduled-tab-mine')));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.byKey(const ValueKey('scheduled-total-m1'))).data, contains('35.00'));
        expect(find.byKey(const ValueKey('scheduled-place-fees-m1')), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('scheduled-total-r1'))).data, contains('13.00'));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('scheduled-place-fees-r1'))).data,
          isNot(contains('passed on')),
        );
        expect(tester.takeException(), isNull);
      });
    });
  }
}
