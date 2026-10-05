import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/destination_mode.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const klcc = LatLng(3.1579, 101.7123);
const putrajaya = LatLng(2.9264, 101.6964);
const cheras = LatLng(3.10, 101.72);
const sentral = LatLng(3.1338, 101.6869);

class _FakeRides implements RideRepository {
  final accepted = <String>[];

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<RideRequest?> accept(
    String id,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    accepted.add(id);
    return RideRequest({'id': id, 'status': 'accepted'});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _req(String id, LatLng pickup, LatLng drop) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Teksi',
  'fare': 12,
  'ride_fare': 12,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
  'pickup_name': 'From $id',
  'drop_name': 'To $id',
  'pickup_lat': pickup.latitude,
  'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude,
  'drop_lng': drop.longitude,
});

void main() {
  group('rules', () {
    test('a trip counts when it brings the driver well closer', () {
      expect(headsToward(pickup: putrajaya, drop: cheras, destination: klcc), isTrue);
      expect(headsToward(pickup: sentral, drop: putrajaya, destination: klcc), isFalse);
      // 1 km of progress is not enough.
      expect(headsToward(pickup: sentral, drop: const LatLng(3.1400, 101.6950), destination: klcc), isFalse);
      expect(destinationGainKm(pickup: sentral, drop: putrajaya, destination: klcc), lessThan(0));
    });

    test('a long detour that ends a little closer does not count', () {
      // Out to Putrajaya and back to near Sentral: ends ~3 km closer after ~25 km.
      expect(headsToward(pickup: putrajaya, drop: const LatLng(2.95, 101.75), destination: klcc), isFalse);
    });

    test('toward trips first, each group nearest first', () {
      final items = [('a', false, 1.0), ('b', true, 5.0), ('c', true, 2.0), ('d', false, null)];
      final order = destinationOrder(items, toward: (x) => x.$2, awayKm: (x) => x.$3);
      expect(order.map((x) => x.$1), ['c', 'b', 'a', 'd']);
    });
  });

  group('screen', () {
    late StreamController<List<RideRequest>> open;
    late _FakeRides rides;

    setUp(() {
      open = StreamController<List<RideRequest>>.broadcast();
      rides = _FakeRides();
    });
    tearDown(() => open.close());

    Future<void> pump(WidgetTester tester, {bool on = true}) async {
      SharedPreferences.setMockInitialValues({
        'partner_destination':
            '{"name":"Home","address":"KLCC","lat":${klcc.latitude},"lng":${klcc.longitude},"on":$on}',
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1600);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
          GoRoute(
            path: '/drive/trip/:id',
            builder: (_, s) => Scaffold(body: Text('trip ${s.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(rides),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('trips toward the destination come first and are marked', (tester) async {
      await pump(tester);
      expect(find.text('Heading to Home'), findsOneWidget);
      open.add([_req('away', sentral, putrajaya), _req('home', putrajaya, cheras)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toward-home')), findsOneWidget);
      expect(find.byKey(const ValueKey('toward-away')), findsNothing);
      final homeY = tester.getTopLeft(find.text('To home')).dy;
      final awayY = tester.getTopLeft(find.text('To away')).dy;
      expect(homeY, lessThan(awayY));
    });

    testWidgets('auto-accept takes only trips toward the destination', (tester) async {
      await pump(tester);
      open.add(const []);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('queue-auto-accept')));
      await tester.pumpAndSettle();
      open.add([_req('away', sentral, putrajaya)]);
      await tester.pumpAndSettle();
      expect(rides.accepted, isEmpty);
      open.add([_req('away', sentral, putrajaya), _req('home', putrajaya, cheras)]);
      await tester.pumpAndSettle();
      expect(rides.accepted, ['home']);
    });

    testWidgets('switched off, nothing is marked', (tester) async {
      await pump(tester, on: false);
      open.add([_req('home', putrajaya, cheras)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toward-home')), findsNothing);
    });
  });
}
