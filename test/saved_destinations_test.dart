import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/destination_store.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

Place place(String name, double lat) => Place(name: name, address: '$name addr', point: LatLng(lat, 101.7));

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  final home = place('Home', 3.10),
      klcc = place('KLCC', 3.15),
      airport = place('KLIA', 2.74),
      mall = place('Mall', 3.05);

  test('newest first, a repeat moves up, never more than three', () {
    var saved = addSavedDestination(const [], home);
    saved = addSavedDestination(saved, klcc);
    saved = addSavedDestination(saved, airport);
    expect(saved.map((p) => p.name), ['KLIA', 'KLCC', 'Home']);
    saved = addSavedDestination(saved, home);
    expect(saved.map((p) => p.name), ['Home', 'KLIA', 'KLCC']);
    saved = addSavedDestination(saved, mall);
    expect(saved.map((p) => p.name), ['Mall', 'Home', 'KLIA'], reason: 'the oldest drops off');
    expect(samePlace(home, place('Home', 3.1002)), isTrue, reason: '~20 m');
    expect(samePlace(home, place('Home', 3.11)), isFalse);
  });

  group('store', () {
    Future<ProviderContainer> open(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(destinationModeProvider);
      await settle();
      return c;
    }

    test('the single destination of older builds carries over', () async {
      final c = await open({
        'partner_destination': jsonEncode({'name': 'Home', 'address': 'x', 'lat': 3.1, 'lng': 101.7, 'on': true}),
      });
      final d = c.read(destinationModeProvider);
      expect(d.saved.map((p) => p.name), ['Home']);
      expect(d.place?.name, 'Home');
      expect(d.on, isTrue);
    });

    test('picking, switching, removing and the round trip through storage', () async {
      final c = await open({});
      final n = c.read(destinationModeProvider.notifier);
      await n.setPlace(home);
      await n.setPlace(klcc);
      expect(c.read(destinationModeProvider).place?.name, 'KLCC');

      await n.select(home);
      expect(c.read(destinationModeProvider).place?.name, 'Home');
      await n.select(home);
      expect(c.read(destinationModeProvider).on, isFalse, reason: 'picking the active one turns it off');

      await n.select(klcc);
      await n.remove(klcc);
      final d = c.read(destinationModeProvider);
      expect(d.place, isNull);
      expect(d.on, isFalse);
      expect(d.saved.map((p) => p.name), ['Home']);

      await n.select(home);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('partner_destination'), isNull, reason: 'the old key is retired');
      final again = await open({'partner_destinations': prefs.getString('partner_destinations')!});
      expect(again.read(destinationModeProvider).place?.name, 'Home');
      expect(again.read(destinationModeProvider).on, isTrue);
    });
  });
}
