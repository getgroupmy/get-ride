import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

class _Rides implements RideRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _offered({double? lat = 3.150, double? lng = 101.700}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'offered_fare': 24,
  'partner_id': 'p1',
  'partner_name': 'Ali',
  'partner_accept_lat': lat,
  'partner_accept_lng': lng,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'pickup_lat': 3.158,
  'pickup_lng': 101.712,
  'drop_name': 'KL Sentral',
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

void main() {
  test('minutes round up and never read zero', () {
    expect(offerEtaMinutes(0.2), 1);
    expect(offerEtaMinutes(1), 1);
    expect(offerEtaMinutes(2.1), 3);
    expect(offerEtaMinutes(14), 14);
    expect(offerEtaMinutes(double.nan), 1);
  });

  test('an offer carries where its driver was', () {
    final o = standingOffer(_offered())!;
    expect((o.fromLat, o.fromLng), (3.150, 101.700));
    final none = standingOffer(_offered(lat: null, lng: null))!;
    expect(none.fromLat, isNull);
  });

  Future<List<Uri>> pump(WidgetTester tester, RideRequest row, {required int seconds}) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final asked = <Uri>[];
    final osrm = MockClient((req) async {
      if (!req.url.path.contains('/route/')) return http.Response('', 404);
      asked.add(req.url);
      return http.Response(
        jsonEncode({
          'routes': [
            {
              'distance': 1800,
              'duration': seconds,
              'geometry': {
                'coordinates': [
                  [101.700, 3.150],
                  [101.712, 3.158],
                ],
              },
            },
          ],
        }),
        200,
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_Rides()),
          rideStreamProvider.overrideWith((ref, id) => Stream.value(row)),
          geoServiceProvider.overrideWithValue(GeoService(client: osrm)),
          riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
        ],
        child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return asked;
  }

  testWidgets('the offer card shows how far the driver is by road', (tester) async {
    final asked = await pump(tester, _offered(), seconds: 150);
    expect(find.text('3 min'), findsOneWidget);
    expect(asked, hasLength(1));
    expect(asked.single.path, contains('101.7,3.15;101.712,3.158'), reason: 'from the driver to the pickup');
  });

  testWidgets('no position on the offer: no ETA rather than a guess', (tester) async {
    final asked = await pump(tester, _offered(lat: null, lng: null), seconds: 150);
    expect(find.text('Ali'), findsOneWidget);
    expect(find.textContaining(' min'), findsNothing);
    expect(asked, isEmpty);
  });
}
