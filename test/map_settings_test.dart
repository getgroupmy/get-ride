// Admin → Settings → Maps (migration 0200): the setting and its rules, the
// profile the app gets, the geo service asking providers in order, and the
// admin page (light and dark).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/maps/maps_data.dart';
import 'package:get_ride/src/admin/screens/maps/maps_logic.dart';
import 'package:get_ride/src/admin/screens/maps/maps_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/admin/screens/security/api_keys_logic.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/map_profile_repository.dart' show mapRole;
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

class _FakeRepo implements MapsRepository {
  final saved = <MapSettings>[];

  @override
  Future<MapSettings> save(MapSettings s) async {
    saved.add(s);
    return s;
  }

  @override
  Future<Set<String>> fallbackSlots() async => fallbacks;
  Set<String> fallbacks = const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProbe implements MapTestProbe {
  final asked = <Map<String, String>>[];

  @override
  Future<Map<String, dynamic>?> ask(String role, String device, Map<String, String> params) async {
    asked.add({'role': role, 'device': device, ...params});
    return switch (params['action']) {
      'profile' => {
        'profile': {
          'tiles': {
            'light': {'url': 'https://tiles.example/{z}/{x}/{y}.png?key=SECRET'},
            'dark': null,
            'satellite': null,
            'traffic': {'off': true},
          },
        },
      },
      'search' => {
        'places': [
          {'name': 'KLCC', 'address': 'KL', 'lat': 3.15, 'lng': 101.71},
        ],
      },
      _ => {'error': 'No key for that provider.'},
    };
  }
}

final _keys = [
  ApiProviderDef(
    id: 'google',
    name: 'Google',
    services: [
      ApiServiceDef(
        id: 'maps',
        name: 'Maps SDK',
        keys: [ApiKeyEntry(id: 'g1', label: 'Prod', value: 'AIzaSyTILES1234')],
      ),
      ApiServiceDef(
        id: 'places',
        name: 'Places',
        keys: [ApiKeyEntry(id: 'p1', label: 'Prod', value: 'AIzaSyPLACES999')],
      ),
      const ApiServiceDef(id: 'geocoding', name: 'Geocoding'),
      const ApiServiceDef(id: 'directions', name: 'Directions'),
    ],
  ),
  ApiProviderDef(
    id: 'here',
    name: 'HERE',
    services: [
      ApiServiceDef(
        id: 'api',
        name: 'HERE API',
        keys: [
          ApiKeyEntry(id: 'h1', label: 'Main', value: 'HEREKEY0001'),
          ApiKeyEntry(id: 'h2', label: 'Spare', value: 'HEREKEY0002', disabled: true),
        ],
      ),
    ],
  ),
];

void main() {
  group('the setting', () {
    test('every profile, built in by default, and back to JSON', () {
      final s = MapSettings.fromJson(null);
      expect(s.profiles.length, 8);
      expect(s.profile('partner', 'web'), const MapProfileSetting());
      expect(s.keyRef('google_places'), 'google/places');
      expect(MapSettings.fromJson(s.toJson()), s);
      expect(s.googleApi, 'new_old', reason: 'Google: new first, old when it refuses');
      expect(MapSettings.fromJson({'googleApi': 'old'}).googleApi, 'old');
      expect(MapSettings.fromJson({'googleApi': 'bogus'}).googleApi, 'new_old');
      expect(s.withGoogleApi('new') == s, isFalse, reason: 'a change to save');
      expect(s.withGoogleApi('new').withKey('here', 'here/api').googleApi, 'new', reason: 'kept through other edits');
      final odd = MapSettings.fromJson({
        'profiles': {
          'rider.ios': {
            'tiles': {'light': 'bogus', 'satellite': 'esri'},
            'search': ['here', 'here', 'bogus', 'nominatim', 'tomtom', 'google'],
            'routing': [],
          },
        },
      });
      expect(odd.profile('rider', 'ios').tiles['light'], 'app');
      expect(odd.profile('rider', 'ios').search, ['here', 'nominatim', 'tomtom'], reason: 'known, once, three at most');
      expect(odd.profile('rider', 'ios').routing, ['osrm']);
    });

    test("Google's terms: its search or lookup only on Google's map", () {
      var s = MapSettings.fromJson(null)
          .withProfile('rider', 'android', const MapProfileSetting(search: ['google', 'nominatim']));
      expect(s.googleConflicts, ['Rider · Android']);
      s = s.withProfile(
        'rider',
        'android',
        s.profile('rider', 'android').withTile('light', 'google').withTile('dark', 'google'),
      );
      expect(s.googleConflicts, isEmpty);
    });

    test('copied to every device, and which keys are in use', () {
      final s = MapSettings.fromJson(null)
          .withProfile('partner', 'ios', const MapProfileSetting(reverse: ['here'], routing: ['google', 'osrm']))
          .copiedToAllDevices('partner', 'ios');
      for (final d in mapDevices) {
        expect(s.profile('partner', d).reverse, ['here']);
      }
      expect(s.profile('rider', 'ios').reverse, ['nominatim'], reason: 'riders untouched');
      expect(s.usedKeySlots, {'here', 'google_routes'});
    });

    test('key choices: the first active key, each key masked, and whether one works', () {
      const slot = MapKeySlot('here', 'HERE', 'here/api', providers: {'here'});
      final choices = mapKeyChoices(_keys, slot, 'here/api');
      expect(choices.first.label, 'HERE API: first active key (1)');
      expect(choices[1].ref, 'here/api#h1');
      expect(choices[1].label, isNot(contains('HEREKEY0001')), reason: 'never the whole secret');
      expect(choices[2].label, endsWith('(off)'));
      expect(mapKeyUsable(_keys, 'here/api'), isTrue);
      expect(mapKeyUsable(_keys, 'here/api#h2'), isFalse);
      expect(mapKeyUsable(_keys, 'google/geocoding'), isFalse);
      expect(mapKeyUsable(_keys, 'mapbox/tiles'), isFalse);
    });

    test('a sample tile for the test, and a template named by host only', () {
      expect(sampleTileUrl('https://t.example/{z}/{x}/{y}.png', 3.139, 101.6869), 'https://t.example/12/3204/2012.png');
      expect(tileHost('https://api.tomtom.com/map/{z}/{x}/{y}.png?key=SECRET'), 'api.tomtom.com');
    });
  });

  group('the profile the app gets', () {
    test('read from geo, with built-in where unset', () {
      final p = MapProfile.fromJson({
        'profile': {
          'tiles': {
            'light': {'url': 'https://a.example/{z}/{x}/{y}.png', 'attribution': '© A'},
            'dark': {'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', 'darken': true},
            'satellite': {'url': 'http://insecure/{z}/{x}/{y}'},
            'traffic': {'url': 'https://t.example/{z}/{x}/{y}', 'fallback': 'https://t.example/{z}/{x}/{y}'},
          },
          'search': ['google', 'nominatim'],
          'routing': [],
          'direct': {'nominatim': 'https://geo.example.my/', 'osrm': 'not a url'},
        },
      });
      expect(p.light?.url, 'https://a.example/{z}/{x}/{y}.png');
      expect(p.dark?.darken, isTrue);
      expect(p.satellite, isNull, reason: 'https only');
      expect(p.traffic?.fallback, isNull, reason: 'the same as the primary');
      expect(p.search, ['google', 'nominatim']);
      expect(p.routing, ['osrm']);
      expect(p.nominatimUrl, 'https://geo.example.my');
      expect(p.osrmUrl, isNull);
      expect(
        MapProfile.fromJson({
          'profile': {
            'tiles': {
              'traffic': {'off': true},
            },
          },
        }).traffic?.off,
        isTrue,
      );
    });

    test('the tiles a map draws: the profile first, else built in', () {
      const p = MapProfile(light: MapTileSpec(url: 'https://a.example/{z}/{x}/{y}.png'));
      expect(profileTileSource(p, dark: false)?.url, 'https://a.example/{z}/{x}/{y}.png');
      expect(profileTileSource(p, dark: true), isNull);
      expect(profileTileSource(MapProfile.builtIn, dark: false, satellite: true), isNull);
    });

    test('device and role', () {
      expect(currentMapDevice(web: true), MapDevice.web);
      expect(currentMapDevice(web: false, platform: TargetPlatform.android), MapDevice.android);
      expect(currentMapDevice(web: false, platform: TargetPlatform.iOS), MapDevice.ios);
      expect(currentMapDevice(web: false, platform: TargetPlatform.windows), MapDevice.desktop);
      expect(mapRole('partner'), 'partner');
      expect(mapRole(null), 'rider');
    });
  });

  group('the geo service asks providers in order', () {
    final nominatim = MockClient((req) async {
      if (req.url.path.endsWith('/search')) {
        return http.Response(
          jsonEncode([
            {'name': 'From OSM', 'display_name': 'From OSM, KL', 'lat': '3.1', 'lon': '101.6'},
          ]),
          200,
        );
      }
      if (req.url.path.endsWith('/reverse')) {
        return http.Response(jsonEncode({'name': 'OSM street', 'display_name': 'OSM street, KL'}), 200);
      }
      return http.Response('', 500);
    });

    test('a keyed provider through geo first, Nominatim when it has nothing', () async {
      final asked = <String>[];
      var answer = <String, dynamic>{
        'places': [
          {'name': 'From HERE', 'address': 'KL', 'lat': 3.15, 'lng': 101.71},
        ],
      };
      final geo = GeoService(
        client: nominatim,
        profile: () => const MapProfile(search: ['here', 'nominatim']),
        lookup: (p) async {
          asked.add('${p['action']} ${p['provider']} ${p['q']}');
          return answer;
        },
      );
      expect((await geo.search('klcc')).single.name, 'From HERE');
      answer = {'places': []};
      expect((await geo.search('klcc')).single.name, 'From OSM');
      expect(asked, ['search here klcc', 'search here klcc']);
    });

    test('without a way to geo, keyed providers are skipped', () async {
      final geo = GeoService(
        client: nominatim,
        profile: () => const MapProfile(search: ['google', 'nominatim']),
      );
      expect((await geo.search('klcc')).single.name, 'From OSM');
    });

    test('address lookup and area through geo, then the pinned point', () async {
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(reverse: ['tomtom', 'nominatim']),
        lookup: (_) async => {
          'place': {
            'name': 'Jalan Ampang',
            'address': 'Jalan Ampang, KL',
            'country': 'Malaysia',
            'state': 'KL',
            'city': 'Kuala Lumpur',
            'suburb': null,
          },
        },
      );
      final p = await geo.reverse(const LatLng(3.15, 101.71));
      expect([p.name, p.address], ['Jalan Ampang', 'Jalan Ampang, KL']);
      final a = await geo.reverseArea(const LatLng(3.15, 101.71));
      expect([a?.country, a?.city, a?.suburb], ['Malaysia', 'Kuala Lumpur', null]);

      final down = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(reverse: ['tomtom', 'nominatim']),
        lookup: (_) async => throw Exception('down'),
      );
      expect((await down.reverse(const LatLng(3.15, 101.71))).name, 'Pinned location');
      expect(await down.reverseArea(const LatLng(3.15, 101.71)), isNull);
    });

    test('routes through geo, else a straight-line estimate', () async {
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(routing: ['google', 'osrm']),
        lookup: (p) async => {
          'route': {
            'distanceKm': 12.5,
            'durationMin': 20,
            'points': [
              [3.1, 101.6],
              [3.2, 101.7],
            ],
          },
        },
      );
      final r = await geo.route(const LatLng(3.1, 101.6), const LatLng(3.2, 101.7));
      expect([r.distanceKm, r.durationMin, r.points.length], [12.5, 20, 2]);
      final none = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(routing: ['google', 'osrm']),
        lookup: (_) async => null,
      );
      final est = await none.route(const LatLng(3.1, 101.6), const LatLng(3.2, 101.7));
      expect(est.points.length, 2, reason: 'the straight line');
    });
  });

  Future<(_FakeRepo, _FakeProbe)> pump(
    WidgetTester tester, {
    bool dark = false,
    bool edit = true,
    Set<String> fallbacks = const {},
  }) async {
    final repo = _FakeRepo()..fallbacks = fallbacks;
    final probe = _FakeProbe();
    await tester.binding.setSurfaceSize(const Size(500, 5000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
          mapsRepositoryProvider.overrideWithValue(repo),
          adminMapSettingsProvider.overrideWith((_) async => MapSettings.fromJson(null)),
          adminMapApiKeysProvider.overrideWith((_) async => _keys),
          adminMapUsageProvider.overrideWith(
            (_) async => const [MapUsageRow(provider: 'here', kind: 'search', calls: 42, cached: 30, failures: 1)],
          ),
          mapTestProbeProvider.overrideWithValue(probe),
        ],
        child: MaterialApp(theme: appTheme(dark ? Brightness.dark : Brightness.light), home: const AdminMapsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return (repo, probe);
  }

  Future<void> choose(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    testWidgets('a device set, blocked by Google\'s terms until its map is Google, then saved ($mode)', (tester) async {
      final (repo, _) = await pump(tester, dark: dark);
      expect(find.byKey(const ValueKey('maps-device-rider-android')), findsOneWidget);
      expect(find.byKey(const ValueKey('maps-save')), findsNothing, reason: 'nothing changed');

      await choose(tester, 'maps-search-android-0', 'Google · key');
      expect(find.byKey(const ValueKey('maps-google-warning'), skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(const ValueKey('maps-missing-keys'), skipOffstage: false),
        findsNothing,
        reason: 'Places has a key',
      );
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved, isEmpty);

      await choose(tester, 'maps-tile-android-light', 'Google');
      await choose(tester, 'maps-tile-android-dark', 'Google');
      expect(find.byKey(const ValueKey('maps-google-warning'), skipOffstage: false), findsNothing);
      await choose(tester, 'maps-search-android-1', 'OpenStreetMap (Nominatim)');
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      final p = repo.saved.single.profile('rider', 'android');
      expect(p.search, ['google', 'nominatim']);
      expect([p.tiles['light'], p.tiles['dark']], ['google', 'google']);
      expect(repo.saved.single.profile('rider', 'ios').search, ['nominatim'], reason: 'other devices untouched');
    });

    testWidgets('partners set apart from riders, a provider without a key flagged ($mode)', (tester) async {
      final (repo, _) = await pump(tester, dark: dark);
      await tester.tap(find.text('Partner'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('maps-device-partner-web')), findsOneWidget);
      await choose(tester, 'maps-reverse-web-0', 'TomTom · key');
      expect(find.byKey(const ValueKey('maps-missing-keys'), skipOffstage: false), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('maps-copy-web')));
      await tester.tap(find.byKey(const ValueKey('maps-copy-web')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      final s = repo.saved.single;
      for (final d in mapDevices) {
        expect(s.profile('partner', d).reverse, ['tomtom'], reason: 'copied to $d');
        expect(s.profile('rider', d).reverse, ['nominatim']);
      }
    });

    testWidgets('a Google key missing here and on the server is flagged ($mode)', (tester) async {
      await pump(tester, dark: dark);
      await choose(tester, 'maps-reverse-android-0', 'Google · key');
      expect(find.byKey(const ValueKey('maps-missing-keys'), skipOffstage: false), findsOneWidget);
    });

    testWidgets('…and with it synced, no notice, and the Keys tab says where it comes from ($mode)', (tester) async {
      await pump(tester, dark: dark, fallbacks: {'google_geocoding'});
      await choose(tester, 'maps-reverse-android-0', 'Google · key');
      expect(find.byKey(const ValueKey('maps-missing-keys'), skipOffstage: false), findsNothing);
      await tester.tap(find.byKey(const ValueKey('maps-tab-keys')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('maps-key-google_geocoding')),
          matching: find.text('In use, key from GitHub'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Google API: New then Old by default, Old only saved ($mode)', (tester) async {
      final (repo, _) = await pump(tester, dark: dark);
      await tester.tap(find.byKey(const ValueKey('maps-tab-keys')));
      await tester.pumpAndSettle();
      expect(find.text('New, then Old if New refuses'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('maps-google-api-new_old')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Old only (Places API, Directions API)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.googleApi, 'old');
      expect(repo.saved.single.toJson()['googleApi'], 'old');
    });

    testWidgets('keys and usage ($mode)', (tester) async {
      await pump(tester, dark: dark);
      await tester.tap(find.byKey(const ValueKey('maps-tab-keys')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('maps-key-here')), findsOneWidget);
      expect(find.text('HERE API: first active key (1)'), findsOneWidget);
      expect(find.textContaining('HEREKEY0001'), findsNothing, reason: 'no secret on screen');
      await tester.tap(find.byKey(const ValueKey('maps-tab-usage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('maps-usage-here-search')), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('Test asks geo as that role and device, and names tiles by host ($mode)', (tester) async {
      final (_, probe) = await pump(tester, dark: dark);
      await choose(tester, 'maps-search-ios-0', 'HERE · key');
      await tester.ensureVisible(find.byKey(const ValueKey('maps-test-ios')));
      await tester.tap(find.byKey(const ValueKey('maps-test-ios')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('maps-test-dialog')), findsOneWidget);
      expect(find.text('tiles.example'), findsOneWidget);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.text('HERE · place search'), findsOneWidget);
      expect(probe.asked.map((a) => '${a['role']} ${a['device']} ${a['action']}'), [
        'rider ios profile',
        'rider ios search',
      ]);
    });
  }

  testWidgets('read-only without edit access', (tester) async {
    await pump(tester, edit: false);
    expect(find.byKey(const ValueKey('maps-copy-android')), findsNothing);
    final field = tester.widget<DropdownButtonFormField<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('maps-tile-android-light')),
        matching: find.byType(DropdownButtonFormField<String>),
      ),
    );
    expect(field.onChanged, isNull);
  });
}
