// A Google Maps link (or coordinates) pasted into place search gives the
// place it points to.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_link.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('reading a link', () {
    test("a place link: the place's own pin and name, not where the map looked", () {
      final l = parseMapLink(
        'https://www.google.com/maps/place/Kuala+Lumpur+International+Airport/@2.7400,101.7000,15z/'
        'data=!4m6!3m5!1s0x31cdc!8m2!3d2.7456!4d101.7072!16zL20vMDFq',
      )!;
      expect(l.point, const LatLng(2.7456, 101.7072));
      expect(l.name, 'Kuala Lumpur International Airport');
      expect(l.exact, isTrue);
      expect(l.short, isFalse);
    });

    test('query and coordinate links', () {
      expect(parseMapLink('https://maps.google.com/?q=3.139,101.6869')!.point, const LatLng(3.139, 101.6869));
      expect(
        parseMapLink('https://www.google.com/maps/search/?api=1&query=3.1579%2C101.7116')!.point,
        const LatLng(3.1579, 101.7116),
      );
      expect(
        parseMapLink('https://www.google.com.my/maps/dir/?api=1&destination=2.9,101.8')!.point,
        const LatLng(2.9, 101.8),
      );
      expect(parseMapLink(' 3.1390, 101.6869 ')!.point, const LatLng(3.139, 101.6869));
    });

    test('a named place without a pin is searched near where the map looked', () {
      final l = parseMapLink('https://www.google.com/maps/search/Petronas+Twin+Towers/@3.157,101.711,17z')!;
      expect([l.point, l.query, l.near], [null, 'Petronas Twin Towers', const LatLng(3.157, 101.711)]);
      expect(parseMapLink('https://maps.google.com/?q=Mid+Valley+Megamall')!.query, 'Mid Valley Megamall');
      expect(parseMapLink('https://www.google.com/maps/@3.13,101.68,15z')!.point, const LatLng(3.13, 101.68));
    });

    test('share links are expanded first', () {
      final l = parseMapLink('https://maps.app.goo.gl/AbC123xyz')!;
      expect([l.short, l.url], [true, 'https://maps.app.goo.gl/AbC123xyz']);
      expect(parseMapLink('goo.gl/maps/XyZ987')!.short, isTrue);
      expect(parseMapLink('https://goo.gl/other'), isNull, reason: 'not a maps link');
    });

    test('anything else is text to search', () {
      for (final s in [
        'klia',
        'Jalan Eco Majestic 1/2D',
        'https://example.com/maps/place/x',
        '91.5, 10',
        '3.1 101.6',
      ]) {
        expect(parseMapLink(s), isNull, reason: s);
      }
    });
  });

  group('searching with a link', () {
    final asked = <Map<String, String>>[];
    GeoService geo({Map<String, dynamic>? expanded}) => GeoService(
      profile: () => const MapProfile(search: ['google'], reverse: ['google']),
      lookup: (p) async {
        asked.add(p);
        return switch (p['action']) {
          'expand' => expanded,
          'reverse' => {
            'place': {'name': 'KLIA Terminal 1', 'address': 'KLIA, 64000 Sepang, Selangor'},
          },
          'search' => {
            'places': [
              {'name': 'Petronas Twin Towers', 'address': 'KLCC, Kuala Lumpur', 'lat': 3.1579, 'lng': 101.7116},
            ],
          },
          _ => null,
        };
      },
    );

    setUp(asked.clear);

    test("a place link: its name, the pin's address", () async {
      final r = await geo().search('https://www.google.com/maps/place/KLIA/@2.7,101.7,15z/data=!3d2.7456!4d101.7072');
      expect(r.single.name, 'KLIA');
      expect(r.single.address, 'KLIA, 64000 Sepang, Selangor');
      expect(r.single.point, const LatLng(2.7456, 101.7072));
      expect(asked.map((a) => a['action']), ['reverse']);
    });

    test('coordinates: named by address lookup', () async {
      final r = await geo().search('2.7456, 101.7072');
      expect(r.single.name, 'KLIA Terminal 1');
    });

    test('a share link is expanded by geo, then read', () async {
      final g = geo(
        expanded: {'url': 'https://www.google.com/maps/place/KLIA/@2.7,101.7,15z/data=!3d2.7456!4d101.7072?g_st=ic'},
      );
      final r = await g.search('https://maps.app.goo.gl/AbC123xyz');
      expect(r.single.point, const LatLng(2.7456, 101.7072));
      expect(asked.first, containsPair('url', 'https://maps.app.goo.gl/AbC123xyz'));
      expect(await geo().search('https://maps.app.goo.gl/Nope'), isEmpty, reason: 'geo could not expand it');
    });

    test('a named place is searched for, the first answer taken', () async {
      final r = await geo().search('https://maps.google.com/?q=Petronas+Twin+Towers');
      expect(r.single.name, 'Petronas Twin Towers');
      expect(asked.single, containsPair('q', 'Petronas Twin Towers'));
    });
  });
}
