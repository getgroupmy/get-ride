// A phone on its side (iOS tester #54, iPhone 15 landscape 852x393, safe
// area 59/59/21): the sheet at rest leaves too little map above it for SOS
// and the map's buttons, so they stand beside the sheet, whole and tappable.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/map_recenter.dart';
import 'package:get_ride/src/widgets/map_type_button.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

const pickup = LatLng(3.1579, 101.7116);
const drop = LatLng(3.1340, 101.6860);

RideRequest ride(String status, {Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'me',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': pickup.latitude,
  'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude,
  'drop_lng': drop.longitude,
  ...extra,
});

class _FakeRides implements RideRepository {
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async =>
      RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
}

void landscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(852, 393);
  tester.view.devicePixelRatio = 1;
  const pad = FakeViewPadding(left: 59, right: 59, bottom: 21);
  tester.view.padding = pad;
  tester.view.viewPadding = pad;
  addTearDown(tester.view.reset);
}

/// [f] is whole on screen and clear of the sheet: beside it or above it.
void expectClearOfSheet(WidgetTester tester, Finder f, String what) {
  expect(f, findsOneWidget, reason: what);
  final r = tester.getRect(f);
  final sheet = tester.getRect(find.byKey(const ValueKey('map-sheet-header')));
  expect(r.top, greaterThanOrEqualTo(0), reason: '$what on screen');
  expect(r.bottom, lessThanOrEqualTo(393), reason: '$what on screen');
  expect(r.left, greaterThanOrEqualTo(59), reason: '$what clear of the notch');
  expect(r.right, lessThanOrEqualTo(852 - 59), reason: '$what clear of the notch');
  final beside = r.right <= sheet.left || r.left >= sheet.right;
  final above = r.bottom <= sheet.top;
  expect(beside || above, isTrue, reason: '$what $r under the sheet $sheet');
}

void main() {
  testWidgets('Your ride: SOS and the map buttons stand beside the sheet', (tester) async {
    landscape(tester);
    final rows = StreamController<RideRequest>();
    addTearDown(rows.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides()),
          rideStreamProvider.overrideWith((ref, id) => rows.stream),
          riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
          geoServiceProvider.overrideWithValue(_Geo()),
        ],
        child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
      ),
    );
    rows.add(ride('accepted', extra: {
      'partner_id': '22222222-2222-2222-2222-222222222222',
      'partner_name': 'Ali',
      'partner_phone': '+60111111111',
      'partner_live_lat': 3.17,
      'partner_live_lng': 101.7116,
    }));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expectClearOfSheet(tester, find.byKey(const ValueKey('ride-sos')), 'SOS');
    expectClearOfSheet(tester, find.byType(RecenterButton), 'recenter');
    expectClearOfSheet(tester, find.byType(MapTypeButton), 'map type');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Current trip: SOS and recenter stand beside the sheet', (tester) async {
    landscape(tester);
    final rows = StreamController<RideRequest>();
    final fixes = StreamController<TripFix>();
    addTearDown(rows.close);
    addTearDown(fixes.close);
    final router = GoRouter(
      initialLocation: '/trip',
      routes: [
        GoRoute(path: '/drive', builder: (_, _) => const Scaffold(body: Text('requests'))),
        GoRoute(path: '/trip', builder: (_, _) => const PartnerTripScreen(requestId: 'r1')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides()),
          rideStreamProvider.overrideWith((ref, id) => rows.stream),
          tripPositionStreamProvider.overrideWithValue(() => fixes.stream),
          tripFixProvider.overrideWithValue(() async => null),
          geoServiceProvider.overrideWithValue(_Geo()),
          currentUserIdProvider.overrideWithValue(null),
          fareTariffsProvider.overrideWith((ref) async => const []),
          rideServicesProvider.overrideWith((ref) async => const []),
          serviceBoxNamesProvider.overrideWith((ref) async => const {}),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    rows.add(ride('on_trip', extra: {'rider_phone': '+60111111111'}));
    await tester.pump();
    await tester.pump();
    fixes.add((at: pickup, heading: 180, accuracy: 5));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expectClearOfSheet(tester, find.byKey(const ValueKey('ride-sos')), 'SOS');
    expectClearOfSheet(tester, find.byType(RecenterButton), 'recenter');
  });
}
