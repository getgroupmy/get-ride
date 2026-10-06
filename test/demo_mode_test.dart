import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('demo switches are off unless the admin turned them on', () {
    final off = DemoSettings.fromSettings(const {});
    expect([off.riderOffers, off.riderTripSim, off.partnerRequests, off.partnerDriveSim], everyElement(isFalse));
    final on = DemoSettings.fromSettings({
      'userMockEnabled': true,
      'riderTripSimEnabled': 'true',
      'partnerMockEnabled': 1,
      'partnerDriveSimEnabled': true,
    });
    expect([on.riderOffers, on.riderTripSim, on.partnerRequests, on.partnerDriveSim], everyElement(isTrue));
  });

  test('three offers at 3, 6 and 9 s, priced around the fare', () {
    final offers = demoOffers(20);
    expect(offers.map((o) => o.$1.inSeconds), [3, 6, 9]);
    expect(offers.map((o) => o.$2.price), [21, 20, 21]);
    expect(offers.first.$2.platinum, isTrue);
  });

  test('the demo trip plays out arrive, wait, drive, done', () {
    expect(demoPhaseAt(Duration.zero).phase, DemoPhase.arriving);
    expect(demoPhaseAt(const Duration(seconds: 7)).progress, closeTo(0.5, 1e-9));
    expect(demoPhaseAt(const Duration(seconds: 15)).phase, DemoPhase.arrived);
    expect(demoPhaseAt(const Duration(seconds: 27, milliseconds: 500)).phase, DemoPhase.onTrip);
    expect(demoPhaseAt(const Duration(seconds: 40)).phase, DemoPhase.completed);
  });

  test('a point along a route', () {
    const route = [LatLng(0, 0), LatLng(0, 1), LatLng(0, 3)];
    expect(alongRoute(route, 0), route.first);
    expect(alongRoute(route, 1), route.last);
    expect(alongRoute(route, 0.5).longitude, closeTo(1.5, 1e-3));
    expect(alongRoute(const [], 0.5), const LatLng(0, 0));
  });

  testWidgets('the feed shows viewers, then offers, and offers expire', (tester) async {
    DemoOffer? taken;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DemoOffersFeed(fare: 20, currency: 'RM', onAccept: (o) => taken = o),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('demo-viewers')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byKey(const ValueKey('demo-viewers')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byKey(const ValueKey('demo-offer-demo-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('demo-accept-demo-1')));
    expect(taken?.name, 'Patrick');
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const ValueKey('demo-offer-demo-1')), findsNothing);
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('a demo trip drives itself when simulated driving is on', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          demoSettingsProvider.overrideWithValue(const DemoSettings(riderTripSim: true)),
          geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
        ],
        child: MaterialApp(
          home: DemoTripScreen(
            args: DemoTripArgs(
              pickup: const LatLng(3.1, 101.6),
              pickupName: 'Home',
              drop: const LatLng(3.2, 101.7),
              dropName: 'KLCC',
              offer: demoOffers(20).first.$2,
              currency: 'RM',
            ),
          ),
        ),
      ),
    );
    String phase() => tester.widget<Text>(find.byKey(const ValueKey('demo-trip-phase'))).data!;
    expect(phase(), 'Driver is on the way');
    await tester.pump(const Duration(seconds: 15));
    expect(phase(), 'Driver has arrived');
    await tester.pump(const Duration(seconds: 25));
    expect(phase(), 'Trip complete');
    expect(find.text('Done'), findsOneWidget);
  });
}
