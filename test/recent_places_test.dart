import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/recent_places.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:latlong2/latlong.dart';

RideRequest _ride(
  String id, {
  String rider = 'me',
  double? lat,
  double? lng,
  String? name,
  String? address,
  int day = 1,
}) => RideRequest({
  'id': id,
  'rider_id': rider,
  'drop_name': name,
  'drop_address': address,
  'drop_lat': lat,
  'drop_lng': lng,
  'created_at': DateTime.utc(2026, 1, day).toIso8601String(),
});

void main() {
  test('newest distinct drop-offs of this rider only', () {
    final rides = [
      _ride('a', lat: 3.1579, lng: 101.7123, name: 'KLCC', day: 1),
      _ride('b', lat: 3.1338, lng: 101.6869, name: 'KL Sentral', address: 'KL Sentral, Kuala Lumpur', day: 3),
      _ride('c', lat: 3.15791, lng: 101.71231, name: 'KLCC again', day: 2),
      _ride('d', rider: 'someone', lat: 2.9, lng: 101.7, name: 'Their place', day: 4),
      _ride('e', name: 'No coordinates', day: 5),
      _ride('f', lat: 3.0726, lng: 101.6075, address: 'Sunway Pyramid, Petaling Jaya', day: 0),
    ];
    final recent = recentPlaces(rides, riderId: 'me', max: 8);
    expect(recent.map((p) => p.name), ['KL Sentral', 'KLCC again', 'Sunway Pyramid']);
    expect(recent.first.address, 'KL Sentral, Kuala Lumpur');
    expect(recentPlaces(rides, riderId: 'me', max: 1), hasLength(1));
    expect(recentPlaces(rides, riderId: null, max: 4), isEmpty);
    expect(recentPlaces(rides, riderId: 'me', max: 0), isEmpty);
  });

  test('admin count is read and clamped', () {
    expect(AppDisplay.fromSettings({'recentLocationsCount': 6}).recentLocationsCount, 6);
    expect(AppDisplay.fromSettings({'recentLocationsCount': 20}).recentLocationsCount, 8);
    expect(AppDisplay.fromSettings({'recentLocationsCount': -1}).recentLocationsCount, 0);
    expect(AppDisplay.fromSettings({}).recentLocationsCount, 4);
    expect(AppDisplay.fromSettings({'recentLocations': false}).recentLocations, isFalse);
  });

  testWidgets('the picker lists recent places until the rider types', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.reset);
    const klcc = Place(name: 'KLCC', address: 'Kuala Lumpur City Centre', point: LatLng(3.1579, 101.7123));
    PlacePick? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentPlacesProvider.overrideWith((ref) async => const [klcc]),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await showPlaceSearch(context, title: 'Where to?'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('KLCC'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump();
    expect(find.text('Recent'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.tap(find.text('KLCC'));
    await tester.pumpAndSettle();
    expect(picked?.place?.name, 'KLCC');
  });
}
