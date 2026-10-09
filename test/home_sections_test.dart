import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/home_sections.dart';
import 'package:get_ride/src/features/ride/home_parts.dart';

void main() {
  test('home parts default as in Expo: boxes and cars off', () {
    final d = HomeSections.fromSettings(const {});
    expect([d.vehicleBar, d.searchBar, d.recentPlaces, d.addressBar, d.newBadge], everyElement(isTrue));
    expect([d.serviceBoxes, d.vehicleMarkers], everyElement(isFalse));
    expect(HomeSections.fromSettings({'showVehicleMarkers': true}).vehicleMarkers, isTrue);
    // The cars ride on the vehicle bar's selection.
    expect(HomeSections.fromSettings({'showVehicleMarkers': true, 'rideTypes': false}).vehicleMarkers, isFalse);
    expect(HomeSections.fromSettings({'serviceCategories': 'true', 'searchBar': 0}).serviceBoxes, isTrue);
  });

  group('service boxes', () {
    final settings = {
      'serviceBoxes': [
        {'route': '/teksi-ev'},
        {'serviceId': 's1', 'route': '/wallet'},
        {'name': 'Parcels', 'route': '/wallet', 'comingSoon': true},
        {'route': '/auth-diagnostics'},
        {},
      ],
    };

    test('titles, links and badges', () {
      final boxes = serviceBoxViews(settings, serviceNames: {'s1': 'City Taxi'});
      expect(boxes.map((b) => b.title), ['Groceries\nin 30 min', 'City Taxi', 'Parcels', 'Couriers', 'Freight']);
      expect(boxes.map((b) => b.route), ['/ev', '/wallet', null, null, null]);
      expect(boxes.map((b) => b.badge), ['NEW', null, 'SOON', 'SOON', 'SOON']);
      expect(boxes.first.featured, isTrue);
      expect(
        serviceBoxComingSoon(boxes.first.title),
        "Groceries in 30 min isn't available yet. Please check back later.",
      );
    });

    test('service off makes every box "coming soon"; the NEW badge has its switch', () {
      expect(
        serviceBoxViews(settings, serviceEnabled: false).every((b) => b.badge == 'SOON' && b.route == null),
        isTrue,
      );
      expect(serviceBoxViews(settings, newBadge: false).first.badge, isNull);
    });

    testWidgets('the grid opens a box', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 900);
      addTearDown(tester.view.reset);
      ServiceBoxView? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServiceBoxesGrid(boxes: serviceBoxViews(settings), onOpen: (b) => opened = b),
          ),
        ),
      );
      expect(find.text('NEW'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('service-box-0')));
      expect(opened?.route, '/ev');
    });
  });

  test('simulated cars stay near the pin and keep moving', () {
    final rnd = math.Random(1);
    var cars = spawnDemoCars(3.1, 101.6, 12, rnd);
    expect(cars, hasLength(12));
    for (var i = 0; i < 600; i++) {
      cars = [for (final c in cars) stepDemoCar(c, 3.1, 101.6, rnd)];
    }
    for (final c in cars) {
      final d = math.sqrt(math.pow(c.lat - 3.1, 2) + math.pow(c.lng - 101.6, 2));
      expect(d, lessThan(demoCarRadius * 1.5));
    }
    expect([for (var i = 0; i < 6; i++) demoCarCount(i)], [12, 8, 6, 5, 4, 4]);
  });

  testWidgets('the vehicle bar selects a service and shows its details', (tester) async {
    RideService? picked;
    const a = RideService('Ride', 'Affordable', 1, 4), b = RideService('Comfort', 'Roomier cars', 1.2, 4);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VehicleTypeBar(services: const [a, b], selected: a, onSelect: (s) => picked = s),
        ),
      ),
    );
    await tester.tap(find.text('Comfort'));
    expect(picked?.name, 'Comfort');
    await tester.tap(find.byKey(const ValueKey('vehicle-info-Ride')));
    await tester.pumpAndSettle();
    expect(find.text('Affordable'), findsOneWidget);
  });

  group('Map Layout on the home map', () {
    test('each setting is read once the admin has set it', () {
      final l = HomeMapLayout.fromSettings({
        'recenterButtonBottom': 239,
        'mapHeightOffset': '215',
        'dropPinTopOffset': 65,
        'dropPinHorizontalOffset': -10,
        'addressBarTopOffset': -20,
      });
      expect(l.recenterBottom, 239);
      expect(l.mapExtra, 215);
      expect(l.pinShift, (-10.0, 65.0));
      expect(l.pillGap, 25, reason: 'up 20 from the 5 px gap');
    });

    test('nothing set leaves the map as it is', () {
      final l = HomeMapLayout.fromSettings(const {});
      expect(l.recenterBottom, isNull);
      expect(l.mapExtra, 0);
      expect(l.pinShift, (0.0, 0.0));
      expect(l.pillGap, 5);
    });

    test('the pill never comes down over the pin, and the map never shrinks', () {
      final l = HomeMapLayout.fromSettings(const {'addressBarTopOffset': 75, 'mapHeightOffset': -50});
      expect(l.pillGap, 2);
      expect(l.mapExtra, 0);
    });
  });
}
