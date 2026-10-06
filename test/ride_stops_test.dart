import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_stops.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart' show rideStreamProvider;
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

class _FakeRides implements RideRepository {
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const midValley = Place(name: 'Mid Valley', address: 'Lingkaran Syed Putra', point: LatLng(3.1178, 101.6772));

  test('stops round-trip through the stored JSON, skipping bad entries', () {
    final stored = [
      stopToJson(midValley),
      {'name': 'No coordinates'},
      {'name': '', 'address': 'Jalan Ampang', 'lat': 3.16, 'lng': 101.71},
      {'name': 'Off the map', 'lat': 95, 'lng': 101.7},
    ];
    final stops = parseRideStops(jsonDecode(jsonEncode(stored)));
    expect(stops.map((s) => s.name), ['Mid Valley', 'Jalan Ampang']);
    expect(stops.first.point, midValley.point);
    expect(parseRideStops(null), isEmpty);
    expect(parseRideStops('[]'), isEmpty);
    expect(RideRequest({'id': 'r', 'stops': stored}).stops, hasLength(2));
    expect(RideRequest({'id': 'r'}).stops, isEmpty);
  });

  test('the route goes through the stops in order', () async {
    Uri? asked;
    final geo = GeoService(
      client: MockClient((req) async {
        asked = req.url;
        return http.Response(
          jsonEncode({
            'routes': [
              {
                'distance': 12000,
                'duration': 1200,
                'geometry': {
                  'coordinates': [
                    [101.7, 3.15],
                    [101.68, 3.12],
                  ],
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    final r = await geo.route(const LatLng(3.15, 101.7), const LatLng(3.13, 101.69), via: [midValley.point]);
    expect(asked!.path, '/route/v1/driving/101.7,3.15;101.6772,3.1178;101.69,3.13');
    expect(r.distanceKm, 12);
  });

  test('without the router, the estimate still adds every leg', () async {
    final geo = GeoService(client: MockClient((_) async => http.Response('', 500)));
    const a = LatLng(3.15, 101.7), b = LatLng(3.13, 101.69);
    final direct = await geo.route(a, b);
    final viaStop = await geo.route(a, b, via: [midValley.point]);
    expect(viaStop.distanceKm, greaterThan(direct.distanceKm));
    expect(viaStop.points, [a, midValley.point, b]);
  });

  testWidgets('the driver sees each stop, numbered, with its own navigate key', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rows = StreamController<RideRequest>();
    addTearDown(rows.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides()),
          rideStreamProvider.overrideWith((ref, id) => rows.stream),
          tripFixProvider.overrideWithValue(() async => null),
          currentUserIdProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: PartnerTripScreen(requestId: 'r1')),
      ),
    );
    rows.add(
      RideRequest({
        'id': 'r1',
        'status': 'accepted',
        'pickup_name': 'KLCC',
        'drop_name': 'KL Sentral',
        'pickup_lat': 3.1579,
        'pickup_lng': 101.7116,
        'drop_lat': 3.134,
        'drop_lng': 101.686,
        'stops': [stopToJson(midValley)],
      }),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('trip-stop-0')), findsOneWidget);
    expect(find.text('Mid Valley'), findsOneWidget);
    expect(find.byTooltip('Navigate to stop 1'), findsOneWidget);
  });
}
