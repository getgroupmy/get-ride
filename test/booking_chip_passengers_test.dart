// The Passengers booking chip gives RideOptions a real passenger count
// (otherwise derived from the "More than N passengers" switch).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_confirm.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';

void main() {
  group('RideOptions passenger count', () {
    test('falls back to the morePassengers switch when unset', () {
      expect(const RideOptions().passengers, 1);
      expect(const RideOptions(morePassengers: true).passengers, RideOptions.standardSeats + 1);
    });

    test('a picked count wins over the switch', () {
      expect(const RideOptions(passengerCount: 6).passengers, 6);
      expect(const RideOptions(morePassengers: true, passengerCount: 2).passengers, 2);
    });

    test('copyWith keeps the count, and ==/hashCode include it', () {
      final a = const RideOptions().copyWith(passengerCount: 3);
      expect(a.passengers, 3);
      expect(a, const RideOptions(passengerCount: 3));
      expect(a.hashCode, const RideOptions(passengerCount: 3).hashCode);
      expect(const RideOptions(passengerCount: 3) == const RideOptions(passengerCount: 4), isFalse);
    });

    test('allowed() keeps the picked count (it is not an option kind)', () {
      const config = RideOptionsConfig();
      expect(config.allowed(const RideOptions(passengerCount: 5)).passengers, 5);
    });
  });
}
