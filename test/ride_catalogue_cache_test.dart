import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_services.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the catalogue and its arrangement survive the round trip', () {
    final entries = <CatalogueEntry>[
      (id: 'car', values: {'name': 'GET Car', 'costPerKm': 1.5, 'displayPriority': 1}),
      (id: 'xl', values: {'name': 'GET XL', 'costPerKm': 2.25, 'maxPax': 6}),
    ];
    final display = <String, dynamic>{'vehicleBar': true};
    final back = decodeRideCatalogue(encodeRideCatalogue(entries, display))!;
    expect(back.entries.map((e) => e.id), ['car', 'xl']);
    expect(back.entries[1].values['maxPax'], 6);
    expect(back.display, display);
    expect(
      rideServicesFromCatalogue(back.entries, back.display).map((s) => s.name),
      rideServicesFromCatalogue(entries, display).map((s) => s.name),
    );
  });

  test('nothing kept, or something unreadable, is no catalogue', () {
    expect(decodeRideCatalogue(null), isNull);
    expect(decodeRideCatalogue(''), isNull);
    expect(decodeRideCatalogue('not json'), isNull);
    expect(decodeRideCatalogue('[1, 2]'), isNull);
    expect(decodeRideCatalogue('{"display": {}}'), isNull);
    expect(decodeDisplayBlob(null), isNull);
    expect(decodeDisplayBlob('nope'), isNull);
    expect(decodeDisplayBlob('{"a": 1}'), {'a': 1});
  });

  test("the device's copy is what the vehicle bar can draw at once", () async {
    SharedPreferences.setMockInitialValues({
      'ride_catalogue_v1': encodeRideCatalogue([
        (id: 'car', values: {'name': 'GET Car', 'costPerKm': 1.5}),
      ], const {}),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final kept = await container.read(cachedRideServicesProvider.future);
    expect(kept?.map((s) => s.name), ['GET Car']);
  });

  test('a device with no copy draws the skeleton until the read lands', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(cachedRideServicesProvider.future), isNull);
  });
}
