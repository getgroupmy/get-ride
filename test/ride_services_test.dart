import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_services.dart';

CatalogueEntry _svc(String id, Map<String, dynamic> v) => (id: id, values: v);

void main() {
  test('active passenger services, priced on cost per km, in display order', () {
    final services = rideServicesFromCatalogue([
      _svc('xl', {
        'name': 'GET XL',
        'shortDescription': 'Up to 6',
        'costPerKm': 2.25,
        'maxPax': 6,
        'displayPriority': 2,
      }),
      _svc('car', {
        'name': 'GET Car',
        'shortDescription': 'Everyday',
        'costPerKm': 1.5,
        'maxPax': '4',
        'displayPriority': 1,
      }),
      _svc('off', {'name': 'Retired', 'costPerKm': 1.5, 'status': false}),
      _svc('frt', {
        'name': 'Freight',
        'costPerKm': 3,
        'serviceTypes': ['Freight'],
      }),
      _svc('both', {
        'name': 'Van',
        'costPerKm': 3,
        'serviceTypes': ['Freight', 'Passenger'],
        'displayPriority': 3,
      }),
    ], const {});
    expect(services.map((s) => s.name), ['GET Car', 'GET XL', 'Van']);
    expect(services[0].multiplier, 1.0);
    expect(services[1].multiplier, 1.5);
    expect(services[1].seats, 6);
    expect(services[1].description, 'Up to 6');
    expect(services[2].multiplier, 2.0);
    expect(services[0].id, 'car');
  });

  test('Admin Display hides services and orders the bar', () {
    final services = rideServicesFromCatalogue(
      [
        _svc('a', {'name': 'A', 'costPerKm': 1.5, 'displayPriority': 1}),
        _svc('b', {'name': 'B', 'costPerKm': 1.5, 'displayPriority': 2}),
        _svc('c', {'name': 'C', 'costPerKm': 1.5, 'displayPriority': 3}),
      ],
      {
        'hiddenVehicleServiceIds': ['b'],
        'vehicleBarOrder': ['c', 'a'],
      },
    );
    expect(services.map((s) => s.name), ['C', 'A']);
  });

  test('missing numbers fall back; an empty catalogue offers one plain ride', () {
    final services = rideServicesFromCatalogue([
      _svc('x', {'name': ''}),
    ], const {});
    expect(services.single.name, 'Ride');
    expect(services.single.multiplier, 1.0);
    expect(services.single.seats, 4);
    expect(rideServicesFromCatalogue(const [], const {}), [fallbackRideService]);
  });
}
