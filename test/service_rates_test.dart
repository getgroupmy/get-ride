// A service with no fare tariff for the trip is priced on its own rates
// (0300, docs/KIV.md H4): km × Cost per km + minutes × Cost per min, never
// below the Minimum fare. A metered taxi keeps the built-in TEKSI meter.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/early_end.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/fare_info.dart';
import 'package:get_ride/src/core/fare_tariff.dart';
import 'package:get_ride/src/core/freight.dart';
import 'package:get_ride/src/core/ride_offers.dart';
import 'package:get_ride/src/core/ride_services.dart';

const _courierCar = {
  'name': 'Courier Car',
  'serviceTypes': ['Courier'],
  'costPerKm': 1.2,
  'costPerMin': '0.2',
  'minFareAmount': 8,
};

void main() {
  group('ServiceRates', () {
    test('read from the catalogue entry', () {
      final r = ServiceRates.fromValues(_courierCar)!;
      expect(r.perKm, 1.2);
      expect(r.perMinute, 0.2);
      expect(r.minimumFare, 8);
      expect(ServiceRates.fromValues(const {'name': 'Ride'}), isNull, reason: 'no Cost per km');
      expect(ServiceRates.fromValues(const {'name': 'Ride', 'costPerKm': 0}), isNull);
      expect(ServiceRates.fromValues(const {'name': 'Teksi', 'costPerKm': 1.5}), isNull, reason: 'the meter prices a taxi');
      expect(ServiceRates.fromValues(const {'name': 'City cab', 'serviceTypes': ['Taxi'], 'costPerKm': 1.5}), isNull);
      expect(ServiceRates.fromValues(const {'name': 'Bike', 'costPerKm': 0.8})!.minimumFare, 0);
    });

    test('km × per km + minutes × per minute, never below the minimum', () {
      final r = ServiceRates.fromValues(_courierCar)!;
      expect(r.fare(10, 20), 16.0);
      expect(r.fare(3, 8), 8.0, reason: '5.20 is under the RM 8 minimum');
      expect(r.fare(25, 35), 37.0);
      expect(r.fare(-1, -5), 8.0);
    });
  });

  group('quoteFare', () {
    final rates = ServiceRates.fromValues(_courierCar)!;
    const card = FareTariff(level: 'master', baseFare: 4, perKm: 1, perMinute: 0.3);

    test('a tariff always wins', () {
      expect(quoteFare(card, 10, 20, rates: rates).fare, tariffFare(card, 10, 20));
    });

    test('no tariff: the service rates, else the built-in meter', () {
      expect(quoteFare(null, 10, 20, multiplier: 0.8, rates: rates).fare, 16.0);
      expect(quoteFare(null, 10, 20, multiplier: 0.8).fare, calculateFare(10, 20, multiplier: 0.8));
    });

    test('the early-end floor is the minimum fare', () {
      expect(earlyEndFloor(null, rates: rates), 8.0);
      expect(earlyEndFloor(null, multiplier: 2), calculateFare(0, 0, multiplier: 2));
    });
  });

  test('catalogue services carry their rates', () {
    final ride = rideServicesFromCatalogue([(id: 'c', values: _courierCar)], const {}).single;
    expect(ride.rates?.perMinute, 0.2);
    final courier = freightVehiclesFrom([(id: 'c', values: {..._courierCar, 'status': true})], kind: DeliveryKind.courier);
    expect(courier.single.rates?.minimumFare, 8);
    expect(courier.single.service.rates?.perKm, 1.2);
  });

  test("the fare's details list the service rates", () {
    final s = RideService('Courier Car', '', 0.8, 1, rates: ServiceRates.fromValues(_courierCar));
    expect(fareRateLines(null, s), ['Fare per km: RM1.20', 'Fare per minute: RM0.20', 'Minimum fare: RM8']);
  });

  test('a refusal for want of a vehicle reads the server reason', () {
    const hint = "Comfort requests need a vehicle. Pick the vehicle you're driving in Partner, then you can offer on these jobs.";
    expect(
      vehicleRequiredReason('PostgrestException(message: VEHICLE_REQUIRED, code: 42501, details: Forbidden, hint: $hint)'),
      hint,
    );
    expect(vehicleRequiredReason('PostgrestException(message: VEHICLE_REQUIRED, code: 42501, details: , hint: null)'),
        startsWith('This job needs a vehicle.'));
    expect(vehicleRequiredReason('PostgrestException(message: OFFER_AMOUNT)'), isNull);
  });
}
