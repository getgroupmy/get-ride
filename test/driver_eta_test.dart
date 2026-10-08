// "• 4 min" on the confirm sheet: the nearest online driver to the pickup.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_eta.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';

void main() {
  test('minutes at town speed, never under one', () {
    expect(driverEtaMinutes(0.1), 1);
    expect(driverEtaMinutes(1.6), 4);
    expect(driverEtaMinutes(4), 10);
  });

  test('the nearest per vehicle type, else the nearest of any type', () {
    final byType = parseNearbyDrivers([
      {'vehicle_type': 'Comfort', 'nearest_km': 3.2, 'drivers': 2},
      {'vehicle_type': '', 'nearest_km': 0.8, 'drivers': 1},
      {'vehicle_type': 'comfort', 'nearest_km': 2.5, 'drivers': 1},
      {'nearest_km': 'bad'},
    ]);
    expect(byType, {'comfort': 2.5, '': 0.8});
    expect(nearestDriverKm(const RideService('Comfort', '', 1, 4), byType), 2.5);
    expect(nearestDriverKm(const RideService('6-seater', '', 1, 6), byType), 0.8);
    expect(nearestDriverKm(const RideService('Ride', '', 1, 4), const {}), isNull);
    expect(parseNearbyDrivers(null), isEmpty);
  });

  for (final b in Brightness.values) {
    testWidgets('the card shows seats and the minutes; icons follow the theme ($b)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(
            body: Column(
              children: [
                ConfirmServiceCard(
                  service: const RideService('Ride', 'Affordable fares', 1, 4),
                  price: 'RM 17',
                  selected: false,
                  etaMinutes: 4,
                  onTap: () {},
                ),
                ConfirmServiceCard(
                  service: const RideService('Comfort', 'Newer cars', 1, 4),
                  price: 'RM 20',
                  selected: false,
                  onTap: () {},
                ),
                const AutoAcceptIcon(),
              ],
            ),
          ),
        ),
      );
      expect(find.text('4 • 4 min'), findsOneWidget);
      expect(find.text('4'), findsOneWidget, reason: 'no driver near: seats only');
      final ink = ThemeData(brightness: b).colorScheme.onSurface;
      final plane = tester.widget<Icon>(
        find.descendant(of: find.byKey(const ValueKey('auto-accept-icon')), matching: find.byType(Icon)),
      );
      expect(plane.color, ink);
    });
  }
}
