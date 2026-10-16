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
import 'package:get_ride/src/admin/screens/security/security_data.dart';
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

class _FakeSecurity implements SecurityRepository {
  List<ApiProviderDef> stored = _keys;

  @override
  Future<List<ApiProviderDef>> mutateApiProviders(List<ApiProviderDef> Function(List<ApiProviderDef>) change) async =>
      stored = change(stored);

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

    test('distance in search results: OSRM by default, its own list, Google only on a Google map', () {
      final s = MapSettings.fromJson(null);
      expect(s.profile('rider', 'android').distance, ['osrm']);
      final p = MapSettings.fromJson({
        'profiles': {
          'rider.android': {
            'distance': ['here', 'bogus', 'straight', 'here', 'google', 'tomtom'],
          },
        },
      }).profile('rider', 'android');
      expect(p.distance, ['here', 'straight', 'google'], reason: 'known, once, three at most');
      expect(p.toJson()['distance'], ['here', 'straight', 'google']);
      expect(p.breaksGoogleTerms, isTrue, reason: "Google's distances over OpenStreetMap");
      expect(p.withTile('light', 'google').withTile('dark', 'google_js').breaksGoogleTerms, isFalse);
      expect(p == p.copyWith(distance: ['osrm']), isFalse, reason: 'a change to save');
      final used = s.withProfile('partner', 'web', const MapProfileSetting(distance: ['google'])).usedKeySlots;
      expect(used, contains('google_routes'), reason: "Google's distances use the routes key");
      expect(mapProviderLabel('straight'), 'Straight line (no roads)');
      expect(freeProviders, contains('straight'));
    });

    test('a key added from the page lands in API Keys under the slot, and is picked', () {
      final places = mapKeySlots.firstWhere((s) => s.id == 'google_places');
      final r = addMapKey(_keys, places, 'Prod 2', ' AIzaNEWPLACES ', id: 'k9');
      expect(r.ref, 'google/places#k9');
      final svc = r.list.firstWhere((p) => p.id == 'google').services.firstWhere((s) => s.id == 'places');
      expect(svc.keys.map((k) => (k.id, k.label, k.value)), contains(('k9', 'Prod 2', 'AIzaNEWPLACES')));
      expect(mapKeyUsable(r.list, r.ref), isTrue);

      final js = mapKeySlots.firstWhere((s) => s.id == 'google_js');
      final made = addMapKey(const [], js, '', 'AIzaBROWSER', id: 'b1');
      expect(made.ref, 'google/maps_js#b1', reason: 'provider and service made when missing');
      expect(mapKeyUsable(made.list, made.ref), isTrue);
      expect(made.list.single.services.single.keys.single.label, 'Key 1');
    });

    test("Google's JavaScript map and its traffic: web only, traffic only on that map", () {
      expect(tileOptionsFor('light', 'web'), contains('google_js'));
      expect(tileOptionsFor('light', 'android'), isNot(contains('google_js')));
      expect(tileOptionsFor('traffic', 'web'), contains('google'));
      expect(tileOptionsFor('traffic', 'ios'), isNot(contains('google')));
      const js = MapProfileSetting(
        tiles: {'light': 'google_js', 'dark': 'google_js', 'satellite': 'google_js', 'traffic': 'google'},
        search: ['google'],
      );
      expect(js.breaksGoogleTerms, isFalse, reason: "Google search on Google's JavaScript map");
      expect(js.googleTrafficWithoutItsMap, isFalse);
      expect(js.withTile('dark', 'osm').googleTrafficWithoutItsMap, isTrue);
      expect(js.forDevice('android').tiles.values.toSet(), {'app'}, reason: 'copied to the phone apps: as built');
      expect(js.forDevice('web'), js);
      final s = MapSettings.fromJson(null).withProfile('rider', 'web', js.withTile('dark', 'osm'));
      expect(s.googleTrafficConflicts, ['Rider · Web']);
      expect(s.copiedToAllDevices('rider', 'web').profile('rider', 'android').tiles['light'], 'app');
      expect(s.keyRef('google_js'), 'google/maps_js');
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
      expect(p.distance, ['osrm'], reason: 'OpenStreetMap by default');
      expect(MapProfile.fromJson({
        'profile': {
          'distance': ['here', 'straight'],
        },
      }).distance, ['here', 'straight']);
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
    SecurityRepository? security,
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
          if (security != null) securityRepositoryProvider.overrideWithValue(security),
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

    testWidgets("Google's search on Google's map: no note ($mode)", (tester) async {
      await pump(tester, dark: dark);
      await choose(tester, 'maps-search-android-0', 'Google · key');
      await choose(tester, 'maps-tile-android-light', 'Google');
      await choose(tester, 'maps-tile-android-dark', 'Google');
      expect(find.byKey(const ValueKey('maps-google-warning'), skipOffstage: false), findsNothing);
    });

    testWidgets("a device set, Google's search over another map noted but saved ($mode)", (tester) async {
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
      expect(repo.saved.single.profile('rider', 'android').search, ['google'], reason: 'over OpenStreetMap, saved');
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

    testWidgets("web: Google's JavaScript map and Google traffic, held until both maps are Google's ($mode)", (
      tester,
    ) async {
      final (repo, _) = await pump(tester, dark: dark);
      await choose(tester, 'maps-tile-web-traffic', 'Google traffic (on Google Maps JavaScript)');
      expect(find.byKey(const ValueKey('maps-google-traffic-warning'), skipOffstage: false), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved, isEmpty, reason: 'not saved without the JavaScript map');
      await choose(tester, 'maps-tile-web-light', 'Google Maps (JavaScript)');
      await choose(tester, 'maps-tile-web-dark', 'Google Maps (JavaScript)');
      expect(find.byKey(const ValueKey('maps-google-traffic-warning'), skipOffstage: false), findsNothing);
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.profile('rider', 'web').tiles, {
        'light': 'google_js',
        'dark': 'google_js',
        'satellite': 'app',
        'traffic': 'google',
      });
    });

    testWidgets('a key added on the Keys tab goes to API Keys and is picked for that slot ($mode)', (tester) async {
      final security = _FakeSecurity();
      final (repo, _) = await pump(tester, dark: dark, security: security);
      await tester.tap(find.byKey(const ValueKey('maps-tab-keys')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('maps-key-add-google_geocoding')));
      await tester.tap(find.byKey(const ValueKey('maps-key-add-google_geocoding')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('maps-add-key-dialog')), findsOneWidget);
      final save = find.byKey(const ValueKey('maps-add-key-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull, reason: 'nothing to add yet');
      await tester.enterText(find.byKey(const ValueKey('maps-add-key-label')), 'Prod');
      await tester.enterText(find.byKey(const ValueKey('maps-add-key-value')), 'AIzaGEOCODE1234');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('maps-add-key-value'))).obscureText,
        isTrue,
        reason: 'hidden while typed',
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      final svc = security.stored.firstWhere((p) => p.id == 'google').services.firstWhere((s) => s.id == 'geocoding');
      final added = svc.keys.single;
      expect([added.label, added.value], ['Prod', 'AIzaGEOCODE1234']);
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.keyRef('google_geocoding'), 'google/geocoding#${added.id}');
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

    testWidgets('distance in search results: its own order, tested through geo, saved ($mode)', (tester) async {
      final (repo, probe) = await pump(tester, dark: dark);
      expect(find.text('Distance in search results'), findsWidgets);
      await choose(tester, 'maps-distance-android-0', 'HERE · key');
      await choose(tester, 'maps-distance-android-1', 'Straight line (no roads)');
      await tester.ensureVisible(find.byKey(const ValueKey('maps-test-android')));
      await tester.tap(find.byKey(const ValueKey('maps-test-android')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('HERE · distance'), findsOneWidget);
      expect(find.text('Straight line (no roads) · distance'), findsNothing, reason: 'worked out on the phone');
      expect(probe.asked.last['action'], 'distance');
      expect(probe.asked.last['to'], isNotEmpty);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.profile('rider', 'android').distance, ['here', 'straight']);
    });

    testWidgets('Amazon Location: its region and key slots on the Keys tab, saved ($mode)', (tester) async {
      final (repo, _) = await pump(tester, dark: dark);
      await tester.tap(find.byKey(const ValueKey('maps-tab-keys')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('maps-key-amazon')), findsOneWidget);
      expect(find.byKey(const ValueKey('maps-key-amazon_maps')), findsOneWidget);
      await choose(tester, 'maps-amazon-region-ap-southeast-5', 'Asia Pacific (Singapore) · ap-southeast-1');
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.amazonRegion, 'ap-southeast-1');
    });

    testWidgets('place search results: Autocomplete and each smart address option, saved ($mode)', (tester) async {
      final (repo, _) = await pump(tester, dark: dark);
      expect(find.byKey(const ValueKey('maps-search-results')), findsOneWidget);
      await choose(tester, 'maps-google-search-text', 'Autocomplete (suggestions as the rider types)');
      await choose(tester, 'maps-smart-address-normal', 'Combination: A, B and C');
      await tester.tap(find.byKey(const ValueKey('maps-save')));
      await tester.pumpAndSettle();
      expect([repo.saved.single.googleSearch, repo.saved.single.smartAddress], ['autocomplete', 'all']);
      expect(repo.saved.single.usedKeySlots, contains('google_address'), reason: 'C needs the Address Validation key');
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
