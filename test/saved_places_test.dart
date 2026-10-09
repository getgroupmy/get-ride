import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/saved_places.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const eco = LatLng(2.93, 101.83), klcc = LatLng(3.158, 101.712);

  test('rows read back, Home and Work titled by their kind', () {
    final home = SavedPlace.fromRow({
      'id': 'h',
      'kind': 'home',
      'name': 'Home',
      'address': '25, Jalan Eco Majestic 1/2C',
      'lat': 2.93,
      'lng': 101.83,
      'entrance': ' Gate B ',
    })!;
    expect([home.title, home.entrance, home.kind], ['Home', 'Gate B', SavedPlaceKind.home]);
    expect(SavedPlace.fromRow({'kind': 'other', 'name': 'KLCC', 'lat': 'x', 'lng': 1}), isNull);
    expect(SavedPlace.fromRow({'kind': 'weird', 'name': '', 'lat': 1, 'lng': 2})!.title, 'Saved place');
    const work = SavedPlace(kind: SavedPlaceKind.work, name: '', address: 'Menara', point: klcc);
    expect(work.toRow()['name'], 'Work');
    expect(work.toRow()['kind'], 'work');
  });

  test('the Saved tab: Home, Work, then the others in order', () {
    const a = SavedPlace(kind: SavedPlaceKind.other, name: 'KLCC', address: 'KLCC', point: klcc);
    const h = SavedPlace(kind: SavedPlaceKind.home, name: 'Home', address: 'Eco', point: eco);
    const b = SavedPlace(kind: SavedPlaceKind.other, name: 'Gym', address: 'Gym', point: eco);
    final v = arrangeSavedPlaces([a, h, b]);
    expect(v.home, h);
    expect(v.work, isNull);
    expect([for (final p in v.others) p.name], ['KLCC', 'Gym']);
  });

  test('distance from where the rider is', () {
    expect(savedPlaceDistance(eco, eco), '0km');
    expect(savedPlaceDistance(eco, klcc), matches(RegExp(r'^\d+\.\dkm$')));
    expect(savedPlaceDistance(eco, const LatLng(1.49, 103.74)), matches(RegExp(r'^\d{3}km$')));
    expect(savedPlaceDistance(null, klcc), '');
  });

  test('what stops a save', () {
    expect(savedPlaceProblem(kind: SavedPlaceKind.other, name: '', address: 'KLCC'), 'Give the place a name');
    expect(savedPlaceProblem(kind: SavedPlaceKind.home, name: '', address: 'Eco'), isNull);
    expect(savedPlaceProblem(kind: SavedPlaceKind.work, name: '', address: ' '), 'Choose the address first');
  });
}
