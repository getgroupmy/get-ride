import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_logic.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_screens.dart';
import 'package:get_ride/src/admin/screens/security/security_data.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;

class _Repo implements SecurityRepository {
  _Repo(this.config);
  FareAiConfig config;
  final saved = <FareAiConfig>[];
  final tested = <WazeServer>[];

  @override
  Future<FareAiConfig> fareAiConfig() async => config;

  @override
  Future<Map<String, FareAiKeyState>> fareAiKeyStates() async => {};

  @override
  Future<List<Map<String, dynamic>>> fareAiTrendSample({int limit = 300}) async => const [];

  Map<String, WazeServerHealth> health = {};

  @override
  Future<Map<String, WazeServerHealth>> wazeServerHealth() async => health;

  @override
  Future<void> saveFareAiConfig(FareAiConfig c) async {
    config = normalizeFareAi(c.toJson());
    saved.add(config);
  }

  @override
  Future<Map<String, dynamic>> testWazeServer(
    WazeServer server, {
    required ({double lat, double lng}) origin,
    required ({double lat, double lng}) destination,
  }) async {
    tested.add(server);
    return {
      'latency_ms': 1200,
      'estimate': {'distance_km': 4.6, 'duration_min': 14, 'toll_total': 0, 'summary': 'Via Jalan Tun Razak'},
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('fare data source', () {
    test('a config from before chains behaves as it did', () {
      expect(normalizeFareAi(null).chain, ['ai']);
      expect(normalizeFareAi({'serviceEnabled': false}).chain, isEmpty);
      expect(normalizeFareAi({'serviceEnabled': false}).serviceEnabled, isFalse);
      expect(normalizeFareAi({'source': 'waze'}).chain, ['waze', 'ai']);
      expect(normalizeFareAi({'source': 'waze', 'wazeFallback': 'none'}).chain, ['waze']);
      expect(normalizeFareAi({'source': 'none'}).chain, isEmpty);
    });

    test('a chain keeps known steps once, OSRM last, and survives a save', () {
      expect(normalizeFareAi({'chain': ['osrm', 'waze', 'waze', 'google', 'ai']}).chain, ['waze', 'ai', 'osrm']);
      final c = normalizeFareAi(null).copyWith(chain: ['waze', 'ai', 'osrm']);
      expect(normalizeFareAi(c.toJson()).chain, ['waze', 'ai', 'osrm']);
      expect(fareChainLabel(c.chain), 'Waze → AI → OSRM');
      expect(fareChainLabel(const []), 'No data (apps use their own fallback)');
      expect([fareAiProviderLabel('waze'), fareAiProviderLabel('osrm')], ['Waze (GET.route)', 'OSRM (no traffic)']);
    });

    test('the old fields are still saved for a proxy from before chains', () {
      Map<String, dynamic> j(List<String> chain) => normalizeFareAi(null).copyWith(chain: chain).toJson();
      expect([j(['waze', 'ai', 'osrm'])['source'], j(['waze', 'ai', 'osrm'])['wazeFallback']], ['waze', 'ai']);
      expect([j(['waze', 'osrm'])['source'], j(['waze', 'osrm'])['wazeFallback']], ['waze', 'none']);
      expect([j(['ai', 'osrm'])['source'], j(['ai', 'osrm'])['serviceEnabled']], ['ai', true]);
      expect([j(const [])['source'], j(const [])['serviceEnabled']], ['none', false]);
    });

    test('Waze servers, their areas and the fallback survive a save', () {
      const area = RegionScope(country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya');
      final c = normalizeFareAi(null).copyWith(
        chain: ['waze', 'osrm'],
        wazeServers: [
          WazeServer.create(id: 's1', label: 'PJ', url: 'https://route1.getride.my', key: 'k1', area: area),
          WazeServer.create(id: 's2', label: 'Any', url: 'https://route2.getride.my', key: 'k2', enabled: false),
        ],
      );
      final back = normalizeFareAi(c.toJson());
      expect(back.chain, ['waze', 'osrm']);
      expect([for (final s in back.wazeServers) (s.id, s.label, s.url, s.key, s.enabled)], [
        ('s1', 'PJ', 'https://route1.getride.my', 'k1', true),
        ('s2', 'Any', 'https://route2.getride.my', 'k2', false),
      ]);
      expect(back.wazeServers[0].area, area);
      expect(back.wazeServers[1].area.isAll, isTrue);
      expect(c.toJson()['wazeServers'][1].containsKey('area'), isFalse);
      expect(back.activeWazeServerCount, 1);
    });

    test('a server needs an https address and a key to be used', () {
      WazeServer s(String url, [String key = 'k']) => WazeServer.create(url: url, key: key);
      expect(s('https://route1.getride.my').urlProblem, isNull);
      expect(s('https://route1.getride.my').isActive, isTrue);
      expect(s('').urlProblem, 'Add the server URL');
      expect(s('http://route1.getride.my').urlProblem, 'Must start with https://');
      expect(s('https://route1.getride.my/?x=1').urlProblem, isNotNull);
      expect(s('https://route1.getride.my', ' ').isActive, isFalse);
    });
  });

  testWidgets('admin picks Waze → AI → OSRM, adds a server, tests it unsaved and saves', (tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo(normalizeFareAi(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        securityRepositoryProvider.overrideWithValue(repo),
        adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      ],
      child: const MaterialApp(home: AdminFareAiScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Waze servers'), findsNothing, reason: 'only with Waze in the order');
    await tester.tap(find.text('AI'));                       // the current order
    await tester.pumpAndSettle();
    await tester.tap(find.text('Waze → AI → OSRM').last);
    await tester.pumpAndSettle();
    expect(find.text('Waze servers'), findsOneWidget);
    expect(find.text('AI provider (after Waze)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-waze-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Server URL'), 'http://route1.getride.my');
    await tester.pump();
    expect(find.text('Must start with https://'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Server URL'), 'https://route1.getride.my');
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 's3cret');
    await tester.pump();
    expect(find.text('All regions'), findsOneWidget);

    await tester.tap(find.textContaining('Test (KLCC'));
    await tester.pumpAndSettle();
    expect(repo.tested.single.url, 'https://route1.getride.my', reason: 'the unsaved server is what is tested');
    expect(find.textContaining('4.6 km, 14 min'), findsOneWidget);
    expect(repo.saved, isEmpty, reason: 'testing saves nothing');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final c = repo.saved.single;
    expect(c.chain, ['waze', 'ai', 'osrm']);
    expect(c.toJson()['serviceEnabled'], isTrue);
    expect([for (final s in c.wazeServers) (s.url, s.key, s.area.isAll)], [('https://route1.getride.my', 's3cret', true)]);
  });

  testWidgets('each server card shows its health', (tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo(normalizeFareAi(null).copyWith(chain: ['waze', 'ai', 'osrm'], wazeServers: [
      WazeServer.create(id: 's1', label: 'PJ', url: 'https://route1.getride.my', key: 'k'),
      WazeServer.create(id: 's2', label: 'KL', url: 'https://route2.getride.my', key: 'k'),
    ]))
      ..health = {
        's1': WazeServerHealth(
            state: 'offline',
            failingSince: DateTime.now().subtract(const Duration(minutes: 12)).toUtc().toIso8601String(),
            detail: 'Health check: HTTP 502.'),
        's2': WazeServerHealth(state: 'online', lastCheckedAt: DateTime.now().toUtc().toIso8601String()),
      };
    await tester.pumpWidget(ProviderScope(
      overrides: [
        securityRepositoryProvider.overrideWithValue(repo),
        adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      ],
      child: const MaterialApp(home: AdminFareAiScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Offline since 12m ago — Health check: HTTP 502.'), findsOneWidget);
    expect(find.text('Online · checked just now'), findsOneWidget);
  });
}
