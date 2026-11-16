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
  final testedKinds = <String>[];

  @override
  Future<FareAiConfig> fareAiConfig() async => config;

  @override
  Future<Map<String, FareAiKeyState>> fareAiKeyStates() async => {};

  @override
  Future<List<Map<String, dynamic>>> fareAiTrendSample({int limit = 300}) async => const [];

  Map<String, WazeServerHealth> health = {};

  @override
  Future<Map<String, WazeServerHealth>> wazeServerHealth() async => health;

  FareLiveBalanceState? balanceState;

  @override
  Future<FareLiveBalanceState?> fareLiveBalanceState() async => balanceState;

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
    String kind = 'waze',
  }) async {
    tested.add(server);
    testedKinds.add(kind);
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
      expect(fareChainLabel(c.chain), 'Waze, then AI, then OSRM');
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

    test('Google Maps is a step of its own, with its own servers', () {
      expect(fareChains.first, ['waze', 'gmap', 'ai', 'osrm']);
      expect(fareChainLabel(fareChains.first), 'Waze, then Google Maps, then AI, then OSRM');
      expect(fareAiProviderLabel('gmap'), 'Google Maps (Traffic Scraper)');
      expect(normalizeFareAi({'chain': ['osrm', 'gmap', 'waze', 'gmap', 'ai']}).chain, ['gmap', 'waze', 'ai', 'osrm']);
      // configs saved before the step existed don't gain it
      expect(normalizeFareAi({'source': 'waze'}).chain, ['waze', 'ai']);

      final c = normalizeFareAi(null).copyWith(
        chain: ['waze', 'gmap', 'ai', 'osrm'],
        wazeServers: [WazeServer.create(id: 'w1', label: 'Waze NAS', url: 'https://route.getride.my', key: 'kw')],
        gmapServers: [WazeServer.create(id: 'g1', label: 'Maps NAS', url: 'https://traffic.getride.my', key: 'kg')],
      );
      final back = normalizeFareAi(c.toJson());
      expect(back.chain, ['waze', 'gmap', 'ai', 'osrm']);
      expect([for (final s in back.wazeServers) (s.id, s.url)], [('w1', 'https://route.getride.my')]);
      expect([for (final s in back.gmapServers) (s.id, s.label, s.url, s.key)],
          [('g1', 'Maps NAS', 'https://traffic.getride.my', 'kg')]);
      expect(back.activeGmapServerCount, 1);
      expect(normalizeFareAi({'gmapServers': [{'url': 'https://traffic.getride.my', 'key': 'k'}]}).gmapServers.single.label,
          'Google Maps server');
      expect(normalizeFareAi(null).gmapServers, isEmpty);
    });

    test('Apple Maps is a step of its own, with its own servers', () {
      expect(fareSteps['apple'], 'Apple Maps');
      expect(fareAiProviderLabel('apple'), 'Apple Maps (GET.route Apple Maps)');
      expect(fareChainLabel(['waze', 'gmap', 'apple', 'ai', 'osrm']),
          'Waze, then Google Maps, then Apple Maps, then AI, then OSRM');
      expect(normalizeFareAi({'chain': ['osrm', 'apple', 'waze', 'apple']}).chain, ['apple', 'waze', 'osrm']);

      final c = normalizeFareAi(null).copyWith(
        chain: ['waze', 'gmap', 'apple', 'ai', 'osrm'],
        appleServers: [WazeServer.create(id: 'a1', label: 'Apple NAS', url: 'https://apple.getride.my', key: 'ka')],
      );
      final back = normalizeFareAi(c.toJson());
      expect(back.chain, ['waze', 'gmap', 'apple', 'ai', 'osrm']);
      expect([for (final s in back.appleServers) (s.id, s.label, s.url, s.key)],
          [('a1', 'Apple NAS', 'https://apple.getride.my', 'ka')]);
      expect(back.activeAppleServerCount, 1);
      expect(back.wazeServers, isEmpty, reason: 'Apple servers are not Waze servers');
      expect(normalizeFareAi({'appleServers': [{'url': 'https://apple.getride.my', 'key': 'k'}]}).appleServers.single.label,
          'Apple Maps server');
      expect(normalizeFareAi(null).appleServers, isEmpty);
    });

    test('every fare order is offered: common ones first, OSRM only last, each once, No data last', () {
      expect(fareChains.first, ['waze', 'gmap', 'ai', 'osrm']);
      expect(fareChains.last, isEmpty);
      final keys = [for (final c in fareChains) c.join(',')];
      expect(keys.toSet().length, keys.length, reason: 'no order twice');
      // 64 orders of Waze, Google Maps, Apple Maps and AI (1 to 4 of them),
      // each with and without OSRM after, plus OSRM alone and No data.
      expect(fareChains.length, 130);
      for (final c in fareChains) {
        expect(cleanFareChain(c), c, reason: '$c is saved as offered');
      }
      expect(keys, containsAll(['apple', 'apple,osrm', 'gmap,apple,waze,ai,osrm', 'ai,apple', 'waze,gmap,apple,ai,osrm']));
      // after the common ones, longest first
      final rest = fareChains.sublist(14, fareChains.length - 1);
      for (var i = 1; i < rest.length; i++) {
        expect(rest[i].length <= rest[i - 1].length, isTrue, reason: '${rest[i]} after ${rest[i - 1]}');
      }
    });

    test('the Apple Maps share: off by default, fixed or automatic, saved apart from Google Maps\' share', () {
      expect(normalizeFareAi(null).liveBalance.appleLabel, 'Apple Maps keeps its place in the order');
      expect(normalizeFareAi(null).toJson().containsKey('liveBalance'), isFalse);
      final fixed = normalizeFareAi(null).copyWith(liveBalance: const FareLiveBalance(gmapFirstPct: 20, appleFirstPct: 10));
      expect(fixed.toJson()['liveBalance'], {
        'mode': 'fixed',
        'gmapFirstPct': 20,
        'minPct': 5,
        'maxPct': 40,
        'apple': {'mode': 'fixed', 'firstPct': 10, 'minPct': 0, 'maxPct': 30},
      });
      expect(normalizeFareAi(fixed.toJson()).liveBalance, const FareLiveBalance(gmapFirstPct: 20, appleFirstPct: 10));
      expect(fixed.liveBalance.appleLabel, 'Apple Maps first for 10% of fares');
      // Only Google Maps' share: no apple block, as before.
      expect(normalizeFareAi(null).copyWith(liveBalance: const FareLiveBalance(gmapFirstPct: 20)).toJson()['liveBalance'],
          {'mode': 'fixed', 'gmapFirstPct': 20, 'minPct': 5, 'maxPct': 40});
      final auto = normalizeFareAi({'liveBalance': {'apple': {'mode': 'auto', 'minPct': 40, 'maxPct': 10}}}).liveBalance;
      expect([auto.appleAuto, auto.appleMinPct, auto.appleMaxPct, auto.auto], [true, 10, 40, false]);
      expect(auto.appleLabel, 'Automatic, 10–40% Apple Maps first');
      final st = FareLiveBalanceState.fromRow({'gmap_first_pct': 5, 'apple_first_pct': 12, 'apple_reason': 'Apple Maps answers more often'});
      expect([st.appleFirstPct, st.appleReason], [12, 'Apple Maps answers more often']);
      expect(FareLiveBalanceState.fromRow({'gmap_first_pct': 5}).appleFirstPct, 0, reason: 'a database before 0416');
      expect(appleBalanceApplies(['waze', 'apple', 'osrm']), isTrue);
      expect(appleBalanceApplies(['apple', 'ai', 'osrm']), isFalse);
      expect(liveBalanceTitle(['waze', 'gmap', 'apple', 'ai', 'osrm']), 'Waze / Google Maps / Apple Maps balance');
    });

    test('the Waze / Google Maps balance: Waze first by default, fixed or automatic, survives a save', () {
      expect(normalizeFareAi(null).liveBalance, FareLiveBalance.off);
      expect(normalizeFareAi(null).toJson().containsKey('liveBalance'), isFalse, reason: 'unset stays unset');
      expect(FareLiveBalance.off.label, 'Waze always first');

      final fixed = normalizeFareAi(null).copyWith(liveBalance: const FareLiveBalance(gmapFirstPct: 20));
      expect(normalizeFareAi(fixed.toJson()).liveBalance, const FareLiveBalance(gmapFirstPct: 20));
      expect(fixed.toJson()['liveBalance'], {'mode': 'fixed', 'gmapFirstPct': 20, 'minPct': 5, 'maxPct': 40});
      expect(fixed.liveBalance.label, 'Google Maps first for 20% of fares');

      final auto = normalizeFareAi({'liveBalance': {'mode': 'auto', 'minPct': 60, 'maxPct': 10}});
      expect(auto.liveBalance, const FareLiveBalance(auto: true, minPct: 10, maxPct: 60), reason: 'range put in order');
      expect(auto.liveBalance.label, 'Automatic, 10–60% Google Maps first');
      expect(normalizeFareAi({'liveBalance': {'gmapFirstPct': 250}}).liveBalance.gmapFirstPct, 100);

      final st = FareLiveBalanceState.fromRow({'gmap_first_pct': 15, 'reason': 'Waze answers more often', 'updated_at': null});
      expect([st.gmapFirstPct, st.reason], [15, 'Waze answers more often']);
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
    await tester.tap(find.text('Waze, then AI, then OSRM').last);
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

  testWidgets('admin picks Waze → Google Maps → AI → OSRM and adds a Google Maps server', (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
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

    expect(find.text('Google Maps servers'), findsNothing, reason: 'only with Google Maps in the order');
    await tester.tap(find.text('AI'));                       // the current order
    await tester.pumpAndSettle();
    await tester.tap(find.text('Waze, then Google Maps, then AI, then OSRM').last);
    await tester.pumpAndSettle();
    expect(find.text('Waze servers'), findsOneWidget);
    expect(find.text('Google Maps servers'), findsOneWidget);
    expect(find.text('AI provider (after Waze and Google Maps)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-gmap-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Server URL'), 'https://traffic.getride.my');
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'm4ps');
    await tester.pump();

    await tester.tap(find.textContaining('Test (KLCC'));
    await tester.pumpAndSettle();
    expect(repo.testedKinds, ['gmap'], reason: 'the proxy is asked to test it as a Google Maps server');
    expect(repo.tested.single.label, 'Google Maps server 1');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final c = repo.saved.single;
    expect(c.chain, ['waze', 'gmap', 'ai', 'osrm']);
    expect(c.wazeServers, isEmpty);
    expect([for (final s in c.gmapServers) (s.url, s.key)], [('https://traffic.getride.my', 'm4ps')]);
  });

  testWidgets('admin picks Waze, Apple Maps, AI, OSRM from the search and adds an Apple Maps server', (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
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

    expect(find.text('Apple Maps servers'), findsNothing, reason: 'only with Apple Maps in the order');
    await tester.tap(find.text('AI'));                       // the current order
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'apple maps, then ai');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Waze, then Apple Maps, then AI, then OSRM').last);
    await tester.pumpAndSettle();
    expect(find.text('Apple Maps servers'), findsOneWidget);
    expect(find.text('Google Maps servers'), findsNothing);
    expect(find.text('Waze / Google Maps balance'), findsNothing);
    expect(find.text('Waze / Apple Maps balance'), findsOneWidget, reason: 'Apple Maps has a share of its own');
    expect(find.byKey(const ValueKey('live-balance-fixed')), findsNothing, reason: 'no Google Maps share without it');

    await tester.tap(find.byKey(const ValueKey('add-apple-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Server URL'), 'https://apple.getride.my');
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'appl3');
    await tester.pump();

    await tester.tap(find.textContaining('Test (KLCC'));
    await tester.pumpAndSettle();
    expect(repo.testedKinds, ['apple'], reason: 'the proxy is asked to test it as an Apple Maps server');
    expect(repo.tested.single.label, 'Apple Maps server 1');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final c = repo.saved.single;
    expect(c.chain, ['waze', 'apple', 'ai', 'osrm']);
    expect(c.wazeServers, isEmpty);
    expect([for (final s in c.appleServers) (s.url, s.key)], [('https://apple.getride.my', 'appl3')]);
  });

  testWidgets('the balance card: only with both steps; Fixed, then Automatic with the live share', (tester) async {
    tester.view.physicalSize = const Size(900, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo(normalizeFareAi(null).copyWith(chain: ['waze', 'gmap', 'ai', 'osrm']))
      ..balanceState = const FareLiveBalanceState(gmapFirstPct: 12, reason: 'Waze answers more often: Waze 95% of 40, Google Maps 70% of 10 answered');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        securityRepositoryProvider.overrideWithValue(repo),
        adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      ],
      child: const MaterialApp(home: AdminFareAiScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Waze / Google Maps balance'), findsOneWidget);
    expect(find.text('Waze always first (Google Maps only when Waze has no answer)'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-balance-fixed')), findsOneWidget);

    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-balance-range')), findsOneWidget);
    expect(find.text('Google Maps first for between 5% and 40% of fares'), findsOneWidget);
    expect(find.textContaining('Now: Google Maps first for 12%'), findsOneWidget);
    expect(find.textContaining('Waze answers more often'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(repo.saved.single.liveBalance, const FareLiveBalance(auto: true, minPct: 5, maxPct: 40));
    expect(repo.saved.single.toJson()['liveBalance']['mode'], 'auto');

    // Without both steps there is nothing to balance.
    repo.config = normalizeFareAi(null).copyWith(chain: ['gmap', 'ai', 'osrm']);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        securityRepositoryProvider.overrideWithValue(repo),
        adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      ],
      child: const MaterialApp(home: AdminFareAiScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Waze / Google Maps balance'), findsNothing);
  });

  testWidgets('the Waze / Google Maps / Apple Maps balance: Google\'s share as before, Apple\'s own', (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo(normalizeFareAi(null).copyWith(
        chain: ['waze', 'gmap', 'apple', 'ai', 'osrm'], liveBalance: const FareLiveBalance(gmapFirstPct: 20)))
      ..balanceState = FareLiveBalanceState(
          gmapFirstPct: 12,
          appleFirstPct: 9,
          appleReason: 'Apple Maps answers more often: Waze 90% of 40, Apple Maps 100% of 8 answered',
          appleUpdatedAt: DateTime.now().toUtc().toIso8601String());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        securityRepositoryProvider.overrideWithValue(repo),
        adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      ],
      child: const MaterialApp(home: AdminFareAiScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Waze / Google Maps / Apple Maps balance'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-balance-fixed')), findsOneWidget, reason: 'Google Maps\' share is still there');
    expect(find.text('Apple Maps keeps its place in the order'), findsOneWidget);

    // Fixed Apple share: drag to the right end, capped by Google Maps' 20%.
    await tester.drag(find.byKey(const ValueKey('apple-balance-fixed')), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(find.text('Apple Maps first for 80% of fares, Google Maps 20%, Waze 0%'), findsOneWidget);

    // Automatic, with the live share and its reason.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('apple-balance-mode')), matching: find.text('Automatic')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('apple-balance-range')), findsOneWidget);
    expect(find.text('Apple Maps first for between 0% and 30% of fares'), findsOneWidget);
    expect(find.textContaining('Now: Apple Maps first for 9%'), findsOneWidget);
    expect(find.textContaining('Apple Maps answers more often'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final b = repo.saved.single.liveBalance;
    expect([b.auto, b.gmapFirstPct, b.appleAuto, b.appleMinPct, b.appleMaxPct], [false, 20, true, 0, 30]);
    expect(repo.saved.single.toJson()['liveBalance']['apple']['mode'], 'auto');
  });

  testWidgets('Time limits: each step\'s seconds, the iPhone switch, a warning when too long', (tester) async {
    tester.view.physicalSize = const Size(900, 7000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo(normalizeFareAi(null).copyWith(chain: ['waze', 'gmap', 'apple', 'ai', 'osrm']));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        securityRepositoryProvider.overrideWithValue(repo),
        adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      ],
      child: const MaterialApp(home: AdminFareAiScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Time limits'), findsOneWidget);
    for (final k in ['wazeSeconds', 'gmapSeconds', 'appleSeconds', 'aiSeconds', 'osrmSeconds', 'appWaitSeconds', 'deviceAppleSeconds']) {
      expect(find.byKey(ValueKey('timing-$k')), findsOneWidget, reason: k);
    }
    // 2 + 2 + 1.5 s: past the app's 5 s.
    expect(find.byKey(const ValueKey('timing-too-long')), findsOneWidget);
    expect(find.textContaining('can take 5.5 s'), findsOneWidget);

    // Google Maps down to the bottom (0.5 s): 4 s, inside the wait.
    await tester.drag(find.byKey(const ValueKey('timing-gmapSeconds')), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timing-too-long')), findsNothing);

    // Waze to the top (15 s): past it again.
    await tester.drag(find.byKey(const ValueKey('timing-wazeSeconds')), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timing-too-long')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timing-deviceApple')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timing-deviceAppleSeconds')), findsNothing);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final f = repo.saved.single.timing;
    expect([f.wazeSeconds, f.gmapSeconds, f.deviceApple], [15, 0.5, false]);
    expect(repo.saved.single.toJson()['timing']['wazeSeconds'], 15);
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

