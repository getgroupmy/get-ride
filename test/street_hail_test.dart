// A street hail with a destination: the quote, the record and the screen.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/meter_trip.dart';
import 'package:get_ride/src/core/street_hail.dart';
import 'package:get_ride/src/core/taxi_meter.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/meter/hail_destination_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

const _klcc = LatLng(3.1579, 101.7116);

HailDestination _dest({double? km = 8.2, double? min = 18}) =>
    HailDestination(name: 'KL Sentral', latitude: 3.1340, longitude: 101.6860, routeKm: km, routeMin: min);

class _Geo extends GeoService {
  final routed = <(LatLng, LatLng)>[];

  @override
  Future<Place> reverse(LatLng p) async => Place(name: 'KL Sentral', address: 'Jalan Stesen Sentral', point: p);

  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async {
    routed.add((from, to));
    return RouteInfo(distanceKm: 8.2, durationMin: 18, points: [from, to]);
  }
}

void main() {
  group('the quote', () {
    test('on the built-in TEKSI tariffs it is the fare Expo quotes for the trip', () {
      expect(hailEstimate(tariffRates['old']!, _dest()), calculateFare(8.2, 18));
      expect(hailEstimate(tariffRates['new']!, _dest()), calculateFare(8.2, 18, tariff: Tariff.newTariff));
      expect(hailEstimate(tariffRates['old']!, _dest(km: 0.6, min: 3)), calculateFare(0.6, 3));
    });

    test('the night shift is quoted at the night multiplier', () {
      expect(hailEstimate(tariffRates['old']!, _dest(), multiplier: 1.5), calculateFare(8.2, 18, multiplier: 1.5));
    });

    test('no route, no quote', () {
      expect(hailEstimate(tariffRates['old']!, _dest(km: null)), isNull);
      expect(hailEstimate(tariffRates['old']!, _dest(km: 0)), isNull);
      expect(describeHailRoute(_dest(km: null)), 'No route found');
      expect(describeHailRoute(_dest()), '8.2 km · ~18 min');
    });
  });

  group('the record', () {
    MeterTrip trip({String? destination, double? estimate}) => buildMeterTrip(
          const MeterState(startedAt: 1000, distanceM: 8400, elapsedMs: 1200000, gpsSamples: 1200),
          id: 't1',
          endedAt: 1201000,
          fare: 17.3,
          details: resolveTripDetails(
              const MeterTripDetailsDraft(pax: 1, luggage: 0, charges: 0, airport: MeterAirport.none))!,
          rateLabel: 'Global',
          period: MeterPeriod.day,
          flagFare: 4,
          nightMultiplier: 1.5,
          currency: 'RM',
          destination: destination,
          estimate: estimate,
        );

    test('carries the destination and the quote, and prints both beside the metered fare', () {
      final t = trip(destination: ' KL Sentral ', estimate: 16.6);
      expect(t.destination, 'KL Sentral');
      expect(t.total, 17.3, reason: 'the quote is never what is charged');
      final back = MeterTrip.fromJson(t.toJson())!;
      expect(back.destination, 'KL Sentral');
      expect(back.estimate, 16.6);
      final lines = {for (final l in meterReceiptLines(t)) l.label: l.value};
      expect(lines['Destination'], 'KL Sentral');
      expect(lines['Quoted estimate'], 'RM 16.60');
      expect(lines['Metered fare'], 'RM 17.30');
    });

    test('a hire without one, or a record from an older build, prints neither line', () {
      final labels = meterReceiptLines(trip(destination: '  ', estimate: double.nan)).map((l) => l.label);
      expect(labels, isNot(contains('Destination')));
      expect(labels, isNot(contains('Quoted estimate')));
      final old = MeterTrip.fromJson({'id': 'x', 'endedAt': 5})!;
      expect(old.destination, isNull);
      expect(old.estimate, isNull);
    });
  });

  group('the destination screen', () {
    Future<(_Geo, List<HailDestination?>)> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final geo = _Geo();
      final popped = <HailDestination?>[];
      final router = GoRouter(initialLocation: '/meter', routes: [
        GoRoute(
          path: '/meter',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () async => popped.add(await context.push<HailDestination>('/meter/destination')),
              child: const Text('OPEN'),
            ),
          ),
        ),
        GoRoute(
          path: '/meter/destination',
          builder: (_, _) => HailDestinationScreen(
            args: HailDestinationArgs(origin: _klcc, rates: tariffRates['old']!, currency: 'RM'),
          ),
        ),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [geoServiceProvider.overrideWithValue(geo)],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      return (geo, popped);
    }

    testWidgets('a tap on the map is routed from here and quoted on the card', (tester) async {
      final (geo, popped) = await pump(tester);
      expect(find.text('Search, or tap the map where the passenger is going.'), findsOneWidget);
      await tester.tap(find.byType(FlutterMap));
      // flutter_map holds a tap until a double tap is ruled out.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(geo.routed.single.$1, _klcc);
      expect(find.text('KL Sentral'), findsOneWidget);
      expect(find.text('8.2 km · ~18 min'), findsOneWidget);
      expect(find.text('Est. RM ${calculateFare(8.2, 18).toStringAsFixed(2)}'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hail-set')));
      await tester.pumpAndSettle();
      expect(popped.single?.name, 'KL Sentral');
      expect(popped.single?.routeKm, 8.2);
    });

    testWidgets('back sets nothing', (tester) async {
      final (_, popped) = await pump(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(popped, [null]);
    });
  });
}
