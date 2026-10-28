// Office NAS maps (migration 0319): the settings and rules as the server
// keeps them, the NAS's status, 'nas' in Admin > Maps and the keyless web
// map, and the Office NAS > Maps tab in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/maps/maps_logic.dart';
import 'package:get_ride/src/admin/screens/office_nas/office_nas_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/core/nas_maps.dart';
import 'package:get_ride/src/core/office_nas.dart' show officeNasPage, officeNasPath;
import 'package:get_ride/src/data/nas_maps_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends NasMapsRepository {
  _Repo(this.state) : super(_db);
  NasMapsStatus state;
  final saves = <NasMapsSettings>[];
  final removed = <String>[];
  final codes = <String>[];

  @override
  Future<NasMapsStatus> status() async => state;

  @override
  Future<NasMapsSettings> save(NasMapsSettings s) async {
    saves.add(s);
    // As the server: through its JSON.
    return NasMapsSettings.fromJson(s.toJson());
  }

  @override
  Future<({String code, DateTime? expiresAt})> pairingCode(String label) async {
    codes.add(label);
    return (code: 'ABCD-EFGH', expiresAt: null);
  }

  @override
  Future<void> remove(String id) async => removed.add(id);
}

String _now() => DateTime.now().toUtc().toIso8601String();

Map<String, dynamic> _statusJson({bool refreshing = false}) => {
  'settings': {
    'default': {'routes': true, 'search': true, 'tiles': true, 'timeoutMs': 1500},
    'regions': [
      {'country': 'Singapore', 'search': false},
    ],
    'googleCost': {'route': 5, 'search': 17},
  },
  'service': {
    'last_seen': _now(),
    'status': refreshing ? 'refreshing' : 'ok',
    'online': true,
    'version': '1.0.0',
    'detail': {
      'osrm': {'ok': true, 'ms': 12},
      'photon': {'ok': true, 'ms': 40},
      'tiles': {'ok': true, 'ms': 3, 'bytes': 734003200},
      'tunnel': {'ok': true, 'ms': 180},
      'refresh': refreshing
          ? {'running': true, 'stage': 'routes', 'percent': 15}
          : {'running': false, 'lastOkAt': '2026-10-25T12:00:00Z', 'dataDate': '2026-10-25T00:00:00Z'},
      'mapsUrl': 'https://maps.getride.my',
      'tilesUrl': 'https://tiles.getride.my',
      'secretSet': true,
    },
  },
  'servers': [
    {
      'id': 's1',
      'label': 'DS224+ office',
      'model': 'nas · Intel(R) Celeron(R) J4125',
      'app_version': '1.0.0',
      'last_seen_at': _now(),
      'online': true,
      'maps_url': 'https://maps.getride.my',
      'tiles_url': 'https://tiles.getride.my',
      'secret_set': true,
    },
  ],
  'usage': {
    'routing': {
      'today': {'served': 120, 'failed': 0, 'timedOut': 1, 'avgMs': 35},
      'days30': {'served': 3000, 'failed': 2, 'timedOut': 10, 'avgMs': 40},
    },
    'search': {
      'today': {'served': 50},
      'days30': {'served': 1000, 'avgMs': 90},
    },
  },
};

Future<_Repo> _pump(
  WidgetTester tester, {
  NasMapsStatus? status,
  bool fullAdmin = true,
  bool edit = true,
  Brightness brightness = Brightness.light,
}) async {
  final repo = _Repo(status ?? NasMapsStatus.fromJson(_statusJson()));
  await tester.binding.setSurfaceSize(const Size(1000, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith(
          (_) async => AdminAccess([AdminGrant(page: fullAdmin ? '*' : officeNasPage, edit: edit)]),
        ),
        nasMapsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(theme: appTheme(brightness), home: const OfficeNasScreen(initialTab: 'maps')),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

String _text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  group('settings', () {
    test('read leniently, like nas_maps_normalize', () {
      final s = NasMapsSettings.fromJson({
        'default': {'search': false, 'timeoutMs': 99999},
        'regions': [
          {'country': ' Malaysia ', 'state': 'Sabah', 'routes': false},
          {'state': 'no country'},
          'junk',
        ],
        'googleCost': {'route': -3},
      });
      expect(s.defaultRule, const NasMapsRule(routes: true, search: false, tiles: true, timeoutMs: 5000));
      expect(s.regions.single.name, 'Sabah, Malaysia');
      expect(s.regions.single.rule, const NasMapsRule(routes: false));
      expect([s.routeCost, s.searchCost], [0, 17]);
      expect(NasMapsSettings.fromJson(null).defaultRule, NasMapsRule.defaults);
      expect(NasMapsSettings.fromJson(s.toJson()), s, reason: 'round trip');
      expect(s.regions.single.toJson(), {'country': 'Malaysia', 'state': 'Sabah', 'routes': false});
    });

    test('the most specific region wins; a rule changes only what it sets', () {
      final s = const NasMapsSettings()
          .withRegion(const NasMapsRegion(country: 'Malaysia', rule: NasMapsRule(search: false, timeoutMs: 2000)))
          .withRegion(
            const NasMapsRegion(
              country: 'Malaysia',
              state: 'Kuala Lumpur',
              city: 'Kuala Lumpur',
              rule: NasMapsRule(search: true),
            ),
          )
          .withRegion(const NasMapsRegion(country: 'Singapore', rule: NasMapsRule(routes: false)));
      expect(
        s.ruleFor(country: 'malaysia', state: 'Kuala Lumpur', city: 'Kuala  Lumpur'),
        const NasMapsRule(routes: true, search: true, tiles: true, timeoutMs: 2000),
      );
      expect(
        s.ruleFor(country: 'Malaysia', state: 'Johor', city: 'Johor Bahru'),
        const NasMapsRule(routes: true, search: false, tiles: true, timeoutMs: 2000),
      );
      expect(s.ruleFor(country: 'Brunei'), NasMapsRule.defaults);
      // The same place again replaces its rule; removing it takes it out.
      final again = s.withRegion(const NasMapsRegion(country: 'SINGAPORE', rule: NasMapsRule(tiles: false)));
      expect(again.regions.length, 3);
      expect(again.ruleFor(country: 'Singapore').routes, isTrue);
      expect(again.withoutRegion(const NasMapsRegion(country: 'Singapore')).regions.length, 2);
    });

    test('timeouts in steps of 100 ms, 0.3 to 5 s; the summary names only what is set', () {
      expect(const NasMapsRule().withTimeout(1234).timeoutMs, 1200);
      expect(const NasMapsRule().withTimeout(10).timeoutMs, nasTimeoutMin);
      expect(const NasMapsRule().withTimeout(null).timeoutMs, isNull);
      expect(nasRuleSummary(const NasMapsRule()), 'As the Default rule');
      expect(nasRuleSummary(const NasMapsRule(search: false, timeoutMs: 2000)), 'Search off, wait 2.0 s');
    });
  });

  group('status', () {
    test('services, refresh, usage and what it saved', () {
      final s = NasMapsStatus.fromJson(_statusJson());
      final svc = s.service!;
      expect(svc.headline, 'Working');
      expect([for (final p in NasMapsPart.values) svc.serves(p)], [true, true, true]);
      expect(svc.tiles!.bytes, 734003200);
      expect(nasBytes(svc.tiles!.bytes), '700 MB');
      expect(svc.refresh.running, isFalse);
      expect(s.servers.single.label, 'DS224+ office');
      expect(s.today['routing']!.served, 120);
      expect(s.days30['search']!.avgMs, 90);
      // 3,000 routes at USD 5 and 1,000 searches at USD 17 per 1,000.
      expect(s.savedUsd30, closeTo(32, 0.001));
      expect(nasUsd(s.savedUsd30), 'USD 32.00');
    });

    test('offline, a part down, refreshing', () {
      final json = _statusJson(refreshing: true);
      final refreshing = NasMapsStatus.fromJson(json).service!;
      expect(refreshing.headline, 'Refreshing the maps');
      expect(refreshing.refresh.stageLabel, 'Building routes (15%)');
      ((json['service'] as Map)['detail'] as Map)['photon'] = {'ok': false};
      (json['service'] as Map)['online'] = false;
      final off = NasMapsStatus.fromJson(json).service!;
      expect(off.headline, 'Offline');
      expect(off.serves(NasMapsPart.routes), isFalse, reason: 'nothing while offline');
      expect(NasMapsStatus.fromJson({}).service, isNull);
    });
  });

  group('Admin > Maps and the app', () {
    test("'nas' in every list, its map on the web only, no key", () {
      expect(placeProviders, contains('nas'));
      expect(routeProviders, contains('nas'));
      expect(distanceProviders, contains('nas'));
      expect(tileOptionsFor('light', 'web'), contains('nas'));
      expect(tileOptionsFor('dark', 'web'), contains('nas'));
      for (final d in ['android', 'ios', 'desktop']) {
        expect(tileOptionsFor('light', d), isNot(contains('nas')), reason: d);
      }
      expect(tileOptionsFor('satellite', 'web'), isNot(contains('nas')));
      expect(mapProviderLabel('nas'), 'Office NAS (OpenStreetMap)');
      expect(keylessProviders, contains('nas'));
      expect(freeProviders, isNot(contains('nas')), reason: 'asked through the geo function, so it is tested');
    });

    test('a keyless MapLibre style is the NAS map; a keyed one still needs its key', () {
      const style = 'https://tiles.getride.my/styles/light.json';
      final spec = MapTileSpec.fromJson({
        'engine': 'maplibre',
        'style': style,
        'key': '',
        'keyless': true,
        'attribution': '© OpenStreetMap contributors, Protomaps',
      })!;
      expect([spec.isMapLibre, spec.isBrowserMap, spec.url, spec.maplibreKey], [true, true, style, '']);
      expect(MapTileSpec.fromJson({'engine': 'maplibre', 'style': style, 'key': ''}), isNull);
      expect(
        MapTileSpec.fromJson({'engine': 'maplibre', 'style': 'http://x/s.json', 'key': '', 'keyless': true}),
        isNull,
      );
    });

    test('listed under Security & integrations and grantable', () {
      final e = allAdminEntries.singleWhere((e) => e.path == officeNasPath);
      expect(e.section, 'Security & integrations');
      expect(e.pages, [officeNasPage]);
      expect(grantablePages, contains(officeNasPage));
    });
  });

  group('the tab', () {
    for (final b in Brightness.values) {
      testWidgets('status, refresh, usage (${b.name})', (tester) async {
        await _pump(tester, brightness: b);
        expect(_text(tester, 'nas-maps-headline'), startsWith('Working · last seen'));
        expect(find.text('Routes (OSRM)'), findsOneWidget);
        expect(find.text('Tunnel, from outside'), findsOneWidget);
        expect(find.text('3 ms · 700 MB'), findsOneWidget);
        expect(_text(tester, 'nas-maps-refresh'), contains('Last refreshed 25 Oct 2026'));
        expect(_text(tester, 'nas-maps-saved'), 'Saved in 30 days: about USD 32.00');
        expect(_text(tester, 'nas-maps-passed-on'), contains('10 too slow, 2 failed'));
        expect(find.text('Singapore'), findsOneWidget);
        expect(find.text('Search off'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a switch saves at once', (tester) async {
      final repo = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('nas-maps-default-search')));
      await tester.pumpAndSettle();
      expect(repo.saves.single.defaultRule.search, isFalse);
      expect(repo.saves.single.regions.single.name, 'Singapore', reason: 'region rules kept');
      expect(_text(tester, 'nas-maps-default-note'), endsWith('Saved.'));
    });

    testWidgets('a region rule is edited part by part', (tester) async {
      final repo = await _pump(tester);
      await tester.tap(find.text('Singapore'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nas-maps-region-dialog')), findsOneWidget);
      // Routes: off; search back to the Default rule; its own wait.
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('nas-maps-region-routes')), matching: find.text('Off')),
      );
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('nas-maps-region-search')), matching: find.text('Default (on)')),
      );
      await tester.tap(find.byKey(const ValueKey('nas-maps-region-own-wait')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nas-maps-region-save')));
      await tester.pumpAndSettle();
      expect(repo.saves.single.regions.single.rule, const NasMapsRule(routes: false, timeoutMs: 1500));
      expect(find.text('Routes off, wait 1.5 s'), findsOneWidget);
    });

    testWidgets('a full admin connects with a code and can disconnect', (tester) async {
      final repo = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('nas-maps-connect')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('nas-maps-label')), 'DS224+');
      await tester.tap(find.byKey(const ValueKey('nas-maps-get-code')));
      await tester.pumpAndSettle();
      expect(repo.codes, ['DS224+']);
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nas-maps-disconnect-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(repo.removed, ['s1']);
    });

    testWidgets('a sub-admin with view only sees it all and changes nothing', (tester) async {
      final repo = await _pump(tester, fullAdmin: false, edit: false);
      expect(find.byKey(const ValueKey('nas-maps-connect')), findsNothing);
      expect(find.byKey(const ValueKey('nas-maps-disconnect-s1')), findsNothing);
      expect(find.byKey(const ValueKey('nas-maps-add-region')), findsNothing);
      expect(find.byKey(const ValueKey('nas-maps-prices')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nas-maps-default-search')));
      await tester.pumpAndSettle();
      expect(repo.saves, isEmpty);
    });

    testWidgets('not connected yet', (tester) async {
      await _pump(tester, status: NasMapsStatus.fromJson({'settings': {}}));
      expect(_text(tester, 'nas-maps-headline'), 'Not connected');
      expect(find.text('Connect the NAS'), findsOneWidget);
      expect(_text(tester, 'nas-maps-saved'), 'Saved in 30 days: about USD 0.00');
    });

    testWidgets('a failed refresh and a missing tunnel are shown', (tester) async {
      final json = _statusJson();
      final detail = (json['service'] as Map)['detail'] as Map;
      detail['refresh'] = {'running': false, 'lastError': 'The search stage failed (exit 1).'};
      detail['secretSet'] = false;
      await _pump(tester, status: NasMapsStatus.fromJson(json));
      expect(_text(tester, 'nas-maps-refresh-error'), 'The search stage failed (exit 1).');
      expect(find.byKey(const ValueKey('nas-maps-no-tunnel')), findsOneWidget);
    });
  });
}
