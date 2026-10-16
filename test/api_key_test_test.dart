// Admin → API Keys → Test: a test picked from the list, run on one key or on
// every key of the service, the answers shown and kept on the key.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/security/api_keys_logic.dart';
import 'package:get_ride/src/admin/screens/security/api_keys_screens.dart';
import 'package:get_ride/src/admin/screens/security/security_data.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _tests = [
  KeyTestDef(
    id: 'google_key',
    provider: 'google',
    label: 'Key check (any Google key)',
    services: ['maps_android', 'maps_ios'],
  ),
  KeyTestDef(
    id: 'google_tiles',
    provider: 'google',
    label: 'Map Tiles API',
    about: 'Starts a session.',
    services: ['maps'],
  ),
  KeyTestDef(
    id: 'google_maps_js',
    provider: 'google',
    label: 'Maps JavaScript (in this browser)',
    services: ['maps_js'],
    sendAs: KeySendAs.web,
    browser: true,
  ),
  KeyTestDef(id: 'mapbox_search', provider: 'mapbox', label: 'Mapbox · geocoding', services: ['*']),
];

List<ApiProviderDef> _providers() => [
  ApiProviderDef(
    id: 'google',
    name: 'Google',
    services: [
      const ApiServiceDef(
        id: 'maps',
        name: 'Maps SDK',
        keys: [
          ApiKeyEntry(id: 'k1', label: 'Key 1', value: 'AIzaSyFirstKey000000Jm_M'),
          ApiKeyEntry(id: 'k2', label: 'Key 2', value: 'AIzaSySecondKey00000cZiQ'),
        ],
      ),
      const ApiServiceDef(
        id: 'maps_android',
        name: 'Maps SDK for Android',
        keys: [ApiKeyEntry(id: 'a1', label: 'Key 1', value: 'AIzaSyAndroidKey000000001')],
      ),
    ],
  ),
];

class _Security implements SecurityRepository {
  List<ApiProviderDef> stored = _providers();
  final asked = <Map<String, Object?>>[];

  @override
  Future<List<ApiProviderDef>> apiProviders() async => stored;

  @override
  Future<List<ApiProviderDef>> mutateApiProviders(List<ApiProviderDef> Function(List<ApiProviderDef>) change) async =>
      stored = change(stored);

  @override
  Future<List<KeyTestDef>> keyTests() async => _tests;

  @override
  Future<KeyTestResult> testKey({
    required String providerId,
    required String serviceId,
    required String keyId,
    required String testId,
    required KeySendAs sendAs,
    String? cert,
  }) async {
    asked.add({'key': keyId, 'test': testId, 'as': sendAs, 'cert': cert});
    return keyId == 'k2'
        ? const KeyTestResult(
            outcome: KeyTestOutcome.fail,
            title: "This API is turned off in the key's project",
            detail: 'Enable it in Google Cloud.',
            http: 403,
            ms: 210,
          )
        : const KeyTestResult(
            outcome: KeyTestOutcome.ok,
            title: 'Works',
            detail: 'Google answered.',
            http: 200,
            ms: 180,
          );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('tests meant for the service come first, then the rest of the provider', () {
    expect(keyTestsFor(_tests, 'google', 'maps').map((t) => t.id), ['google_tiles', 'google_key', 'google_maps_js']);
    expect(keyTestsFor(_tests, 'google', 'maps_android').first.id, 'google_key');
    expect(keyTestsFor(_tests, 'mapbox', 'tiles').single.id, 'mapbox_search');
    expect(defaultSendAs('maps_ios', null), KeySendAs.ios);
    expect(defaultSendAs('maps', _tests[2]), KeySendAs.web);
    expect(defaultSendAs('places', _tests[1]), KeySendAs.server);
  });

  test('a test result is kept on the key, other fields untouched', () {
    final next = recordKeyTest(
      _providers(),
      'google',
      'maps',
      'k1',
      _tests[1],
      const KeyTestResult(outcome: KeyTestOutcome.warn, title: 'Over the quota'),
      now: DateTime(2026, 10, 16, 9),
    );
    final k = next.first.services.first.keys.first;
    final last = KeyLastTest.fromKey(k)!;
    expect([last.label, last.outcome, last.title], ['Map Tiles API', KeyTestOutcome.warn, 'Over the quota']);
    expect(k.toJson()['value'], 'AIzaSyFirstKey000000Jm_M');
    expect(KeyLastTest.fromKey(next.first.services.first.keys.last), isNull);
  });

  test("the function's answers and refusals read", () {
    final r = KeyTestResult.fromJson({'result': 'warn', 'title': 'Over the quota', 'http': 429, 'ms': 40});
    expect([r.outcome, r.meta], [KeyTestOutcome.warn, 'HTTP 429 · 40 ms']);
    final refused = KeyTestResult.fromJson({'error': 'admin_only'});
    expect([refused.outcome, refused.detail], [KeyTestOutcome.fail, 'Only admins can test keys.']);
    expect(KeyTestResult.fromJson({'result': 'ok', 'title': 'Works', 'http': 0}).meta, '');
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<_Security> pump(WidgetTester tester, String service, {bool edit = true}) async {
      final security = _Security();
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            ...quietLiveOverrides,
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
            securityRepositoryProvider.overrideWithValue(security),
          ],
          child: MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: AdminApiKeysScreen(providerId: 'google', serviceId: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return security;
    }

    testWidgets('one key: the meant test picked, run, shown and kept on the key ($mode)', (tester) async {
      final security = await pump(tester, 'maps');
      await tester.tap(find.byKey(const ValueKey('api-key-test-k1')));
      await tester.pumpAndSettle();
      expect(find.text('Test Key 1'), findsOneWidget);
      expect(find.text('Map Tiles API'), findsOneWidget, reason: 'the test meant for Maps SDK first');
      expect(find.text('Starts a session.'), findsOneWidget);
      expect(find.byKey(const ValueKey('key-test-cert')), findsNothing, reason: 'sent as the server');

      await tester.tap(find.byKey(const ValueKey('key-test-run')));
      await tester.pumpAndSettle();
      expect(security.asked.single, {'key': 'k1', 'test': 'google_tiles', 'as': KeySendAs.server, 'cert': null});
      expect(
        find.descendant(of: find.byKey(const ValueKey('key-test-result-k1')), matching: find.text('Works')),
        findsOneWidget,
      );
      expect(find.text('HTTP 200 · 180 ms'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('api-key-last-test-k1')), findsOneWidget);
      expect(find.textContaining('Last test: Map Tiles API · Works'), findsOneWidget);
      expect(find.byKey(const ValueKey('api-key-last-test-k2')), findsNothing);
    });

    testWidgets('test all keys: each answer shown, the failed one with its reason ($mode)', (tester) async {
      final security = await pump(tester, 'maps');
      await tester.tap(find.byKey(const ValueKey('api-keys-test-all')));
      await tester.pumpAndSettle();
      expect(find.text('Test 2 keys'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('key-test-pick')));
      await tester.pumpAndSettle();
      expect(find.text('Maps JavaScript (in this browser)'), findsNothing, reason: 'one key at a time');
      await tester.tap(find.text('Key check (any Google key)').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('key-test-run')));
      await tester.pumpAndSettle();
      expect(security.asked.map((a) => '${a['key']} ${a['test']}'), ['k1 google_key', 'k2 google_key']);
      expect(find.text('Key 1: Works'), findsOneWidget);
      expect(find.text("Key 2: This API is turned off in the key's project"), findsOneWidget);
      expect(find.text('Enable it in Google Cloud.'), findsOneWidget);
      expect(find.text('Run again'), findsOneWidget);
    });

    testWidgets('an Android key is sent as the app, with the SHA-1 given ($mode)', (tester) async {
      final security = await pump(tester, 'maps_android');
      expect(find.byKey(const ValueKey('api-keys-test-all')), findsNothing, reason: 'only one key');
      await tester.tap(find.byKey(const ValueKey('api-key-test-a1')));
      await tester.pumpAndSettle();
      expect(find.text('Key check (any Google key)'), findsOneWidget);
      expect(find.text('Android app'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('key-test-cert')), 'AB:CD');
      await tester.tap(find.byKey(const ValueKey('key-test-run')));
      await tester.pumpAndSettle();
      expect(security.asked.single['as'], KeySendAs.android);
      expect(security.asked.single['cert'], 'AB:CD');
    });

    testWidgets('read-only admins can test, and nothing is saved ($mode)', (tester) async {
      final security = await pump(tester, 'maps', edit: false);
      expect(find.text('+ Use'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('api-key-test-k2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('key-test-run')));
      await tester.pumpAndSettle();
      expect(find.text("This API is turned off in the key's project"), findsOneWidget);
      expect(KeyLastTest.fromKey(security.stored.first.services.first.keys.last), isNull);
    });
  }
}
