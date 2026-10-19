// The driver's incoming request on a phone on its side (iOS tester #55,
// #56, iPhone 15 landscape 852x393): the fare, pickup and drop-off always
// show, at 1.3x text too, and the map draws the world, and its pins, once.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

class _Rides implements RideRepository {
  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _open() => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'pickup_address': 'Jalan Ampang, Kuala Lumpur',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.1340,
  'drop_lng': 101.6860,
  'distance_km': 7.2,
  'duration_min': 19,
  'payment_mode': 'Cash',
  'passengers': 1,
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

Future<void> pump(WidgetTester tester, Size size, {double text = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  const pad = FakeViewPadding(left: 59, right: 59, bottom: 21);
  if (size.width > size.height) {
    tester.view.padding = pad;
    tester.view.viewPadding = pad;
  }
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
      child: MaterialApp(
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)), child: child!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RideRequestSheet(
              request: _open(),
              shown: Duration.zero,
              now: DateTime.now(),
              me: const LatLng(3.1700, 101.7000),
              awayKm: 1.8,
              onAccept: () async {},
              onSkip: () {},
              onOffer: (_) async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// [f] is laid out whole inside the part of the sheet that shows it.
void expectShown(WidgetTester tester, Finder f, String what) {
  expect(f, findsOneWidget, reason: what);
  final r = tester.getRect(f);
  final view = tester.getRect(find.ancestor(of: f, matching: find.byType(Scrollable)).first);
  expect(r.height, greaterThan(0), reason: what);
  expect(r.top, greaterThanOrEqualTo(view.top - 0.5), reason: '$what $r in $view');
  expect(r.bottom, lessThanOrEqualTo(view.bottom + 0.5), reason: '$what $r in $view');
}

void main() {
  for (final text in const [1.0, 1.3]) {
    testWidgets('landscape: fare, pickup and drop-off show (${text}x text)', (tester) async {
      await pump(tester, const Size(852, 393), text: text);
      expectShown(tester, find.byKey(const ValueKey('request-fare')), 'fare');
      expectShown(tester, find.textContaining('KLCC'), 'pickup');
      expectShown(tester, find.textContaining('KL Sentral'), 'drop-off');
      expect(find.byKey(const ValueKey('request-alert-accept')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('portrait keeps the map over the details', (tester) async {
    await pump(tester, const Size(390, 844));
    final map = tester.getRect(find.byType(RideMap));
    expect(map.top, lessThan(tester.getRect(find.byKey(const ValueKey('request-fare'))).top));
    expectShown(tester, find.byKey(const ValueKey('request-fare')), 'fare');
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in const [Size(852, 393), Size(390, 844), Size(1366, 300)]) {
    testWidgets('the map draws its pins once (${size.width.round()}x${size.height.round()})', (tester) async {
      await pump(tester, size);
      expect(find.byKey(const ValueKey('request-chip-trip')), findsOneWidget);
      expect(find.byKey(const ValueKey('request-chip-pickup')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-dot-drop')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('one copy of the world spans the map', () {
    expect(worldOnceZoom(256), 0);
    expect(worldOnceZoom(double.infinity), 0);
    expect(256 * (1 << worldOnceZoom(852).ceil()), greaterThanOrEqualTo(852));
  });
}
