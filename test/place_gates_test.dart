import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

const _mall = (
  id: 'mall',
  values: <String, dynamic>{'name': 'Mid Valley Megamall', 'lat': '3.1178', 'lon': '101.6772'},
);
const _airport = (
  id: 'klia',
  values: <String, dynamic>{'name': 'KLIA Terminal 1', 'lat': 2.7456, 'lon': 101.7072, 'gateRequired': false},
);
const _off = (
  id: 'off',
  values: <String, dynamic>{'name': 'Closed Arena', 'lat': 3.05, 'lon': 101.69, 'active': false},
);

GateRow _gate(String id, String place, String name, {Object? mode, Object? priority, Object? active, Object? lat}) => (
  id: id,
  values: <String, dynamic>{
    'placeId': place,
    'name': name,
    'mode': ?mode,
    'displayPriority': ?priority,
    'active': ?active,
    'lat': ?lat,
    if (lat != null) 'lon': 101.678,
  },
);

final _gates = [
  _gate('north', 'mall', 'North Court', priority: 2, lat: 3.119),
  _gate('south', 'mall', 'South Court', priority: 1, mode: 'pickup'),
  _gate('east', 'mall', 'East Wing', priority: 3, mode: 'drop'),
  _gate('shut', 'mall', 'Loading Bay', active: false),
  _gate('door4', 'klia', 'Door 4'),
];

class _Geo extends GeoService {
  _Geo(this.results);
  final List<Place> results;

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => results;
}

void main() {
  group('matchGatedPlace', () {
    final places = [_mall, _airport, _off];

    test('the nearest place within 1.5 km, gates in display order', () {
      final m = matchGatedPlace(places: places, gates: _gates, point: const LatLng(3.1185, 101.6775));
      expect(m?.id, 'mall');
      expect(m?.gates.map((g) => g.name), ['South Court', 'North Court', 'East Wing']);
      expect(m?.gateRequired, isTrue, reason: 'required unless the admin says otherwise');
      expect(m?.blocksPlace, isTrue);
    });

    test('only gates open for the usage', () {
      final pickup = matchGatedPlace(
        places: places,
        gates: _gates,
        point: const LatLng(3.1178, 101.6772),
        usage: GateUsage.pickup,
      );
      expect(pickup?.gates.map((g) => g.id), ['south', 'north']);
      final drop = matchGatedPlace(
        places: places,
        gates: _gates,
        point: const LatLng(3.1178, 101.6772),
        usage: GateUsage.drop,
      );
      expect(drop?.gates.map((g) => g.id), ['north', 'east']);
    });

    test('falls back to the name when the coordinates are elsewhere', () {
      final m = matchGatedPlace(
        places: places,
        gates: _gates,
        point: const LatLng(1.3, 103.8),
        name: 'KLIA terminal 1, Sepang',
      );
      expect(m?.id, 'klia');
      expect(m?.blocksPlace, isFalse, reason: 'the admin made the gate optional');
    });

    test('nothing for a place too far away, unknown or switched off', () {
      expect(matchGatedPlace(places: places, gates: _gates, point: const LatLng(3.14, 101.69)), isNull);
      expect(matchGatedPlace(places: places, gates: _gates, name: 'Somewhere else'), isNull);
      expect(matchGatedPlace(places: places, gates: _gates, point: const LatLng(3.05, 101.69)), isNull);
      expect(matchGatedPlace(places: const [], gates: _gates, point: const LatLng(3.1178, 101.6772)), isNull);
    });

    test('a place with no gates never blocks', () {
      final m = matchGatedPlace(places: [_mall], gates: const [], point: const LatLng(3.1178, 101.6772));
      expect(m?.gates, isEmpty);
      expect(m?.blocksPlace, isFalse);
    });
  });

  test('gatePlace names the gate and uses its own point when mapped', () {
    const base = Place(name: 'Mid Valley', address: 'Lingkaran Syed Putra', point: LatLng(3.1178, 101.6772));
    final m = matchGatedPlace(places: [_mall], gates: _gates, point: base.point)!;
    final north = gatePlace(base, m, m.gates.firstWhere((g) => g.id == 'north'));
    expect(north.name, 'Mid Valley Megamall - North Court');
    expect(north.point, const LatLng(3.119, 101.678));
    expect(north.address, base.address);
    final south = gatePlace(base, m, m.gates.firstWhere((g) => g.id == 'south'));
    expect(south.point, base.point, reason: 'no coordinates on the gate');
  });

  testWidgets('a gated result is picked by gate, not by the place', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.reset);
    const mall = Place(name: 'Mid Valley', address: 'Lingkaran Syed Putra', point: LatLng(3.1178, 101.6772));
    PlacePick? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentPlacesProvider.overrideWith((ref) async => const []),
          geoServiceProvider.overrideWithValue(_Geo(const [mall])),
          placeGatesProvider.overrideWith((ref) async => (places: [_mall], gates: _gates)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    picked = await showPlaceSearch(context, title: 'Pickup', usage: GateUsage.pickup),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mid valley');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('Choose a gate'), findsOneWidget);
    expect(find.byKey(const ValueKey('gate-south')), findsOneWidget);
    expect(find.byKey(const ValueKey('gate-east')), findsNothing, reason: 'drop-off only');

    await tester.tap(find.text('Mid Valley'));
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: 'the place itself is blocked');

    await tester.tap(find.byKey(const ValueKey('gate-north')));
    await tester.pumpAndSettle();
    expect(picked?.place?.name, 'Mid Valley Megamall - North Court');
    expect(picked?.place?.point, const LatLng(3.119, 101.678));
  });
}
