import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_logic.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_request_screen.dart';
import 'package:get_ride/src/admin/screens/security/security_data.dart';

// What ai-route-proxy sent before the request was editable, word for word
// (the same string supabase/functions/_shared/fare_ai_request_test.ts pins).
const _legacy =
    'You are a driving route estimator with access to real-time traffic and toll road data. '
    'For the trip "3.158,101.712 to 3.134,101.686 realtime minute and distance with traffic", estimate the total driving distance, the '
    'current driving time including live traffic, and the toll booths/plazas along the route '
    'with their individual charges in local currency. '
    'Respond with ONLY a compact JSON object, no markdown, no extra text, of the form: '
    '{"distance_km": <number>, "duration_min": <number>, "summary": "<short text>", '
    '"toll_count": <integer>, "toll_total": <number>, "tolls": [{"name": "<booth name>", "charge": <number>, "lat": <number>, "lng": <number>}]}. '
    'distance_km is total kilometres (number). duration_min is total minutes with traffic (integer). '
    'toll_count is the number of toll booths/plazas on the route (integer, 0 if none). '
    'toll_total is the sum of all toll charges (number, 0 if none). '
    'tolls is an array of each real toll booth/plaza that physically exists on this route, in travel order, '
    'each with its name, charge, and exact geographic coordinates (lat and lng as decimal degrees) of the booth location. '
    'Use real, known toll plaza coordinates; do not invent coordinates. Empty array if none.';

const _a = (lat: 3.158, lng: 101.712);
const _b = (lat: 3.134, lng: 101.686);

class _Repo implements SecurityRepository {
  _Repo(this.config);
  FareAiConfig config;
  final saved = <FareAiConfig>[];
  final tested = <FareAiRequest>[];

  @override
  Future<FareAiConfig> fareAiConfig() async => config;

  @override
  Future<void> saveFareAiConfig(FareAiConfig c) async {
    config = normalizeFareAi(c.toJson());
    saved.add(config);
  }

  @override
  Future<Map<String, dynamic>> testFareAiRequest(
    FareAiRequest draft, {
    required ({double lat, double lng}) origin,
    required ({double lat, double lng}) destination,
  }) async {
    tested.add(draft);
    return {
      'provider': 'gemini',
      'model': 'gemini-2.5-flash',
      'key_label': 'Key 1',
      'latency_ms': 840,
      'raw': '{"distance_km": 4.2, "duration_min": 11}',
      'estimate': {'distance_km': 4.2, 'duration_min': 11},
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('request', () {
    test('nothing configured sends the original prompt, word for word', () {
      expect(fareAiPrompt(FareAiRequest.defaults, _a, _b), _legacy);
      expect(FareAiRequest.fromJson(null).isDefault, isTrue);
    });

    test('an untouched request is not stored, an edited one is, and survives a save', () {
      final plain = normalizeFareAi(null);
      expect(plain.toJson().containsKey('request'), isFalse);
      final edited = plain.copyWith(request: plain.request.copyWith(includeTolls: false, temperature: 0.3));
      final back = normalizeFareAi(edited.toJson());
      expect(back.request.includeTolls, isFalse);
      expect(back.request.includeTollCoords, isFalse, reason: 'no tolls means no toll locations');
      expect(back.request.temperature, 0.3);
    });

    test('a prompt has to say where the trip starts and ends', () {
      expect(fareAiTemplateProblem('Estimate a drive.'), isNotNull);
      expect(fareAiTemplateProblem('From {origin_lat} to {destination}.'), isNotNull);
      expect(fareAiTemplateProblem('{origin_lat},{origin_lng} → {dest_lat},{dest_lng}'), isNull);
      expect(FareAiRequest.fromJson({'promptTemplate': 'Estimate a drive.'}).promptTemplate, fareAiDefaultTemplate);
    });

    test('the format always asks for distance and time', () {
      final bare = fareAiFormatClause(const FareAiRequest(includeSummary: false, includeTolls: false));
      expect(bare, contains('{"distance_km": <number>, "duration_min": <number>}'));
      expect(bare, isNot(contains('toll')));
      expect(fareAiFillTemplate('{origin_lat}/{origin_lng} {destination}', _a, _b), '3.158/101.712 3.134,101.686');
    });

    test('numbers stay in range', () {
      final r = FareAiRequest.fromJson({'temperature': 5, 'maxTokens': 1});
      expect((r.temperature, r.maxTokens), (1.0, 128));
    });
  });

  group('fare range and traffic', () {
    test('off by default, so the prompt is unchanged', () {
      expect(FareAiRequest.defaults.includeFareRange, isFalse);
      expect(FareAiRequest.defaults.includeTraffic, isFalse);
      expect(fareAiFormatClause(FareAiRequest.defaults), isNot(contains('current_duration_is')));
      expect(fareAiFormatClause(FareAiRequest.defaults), isNot(contains('traffic_congestion')));
    });

    test('switched on, both are asked for and survive a save', () {
      const r = FareAiRequest(includeFareRange: true, includeTraffic: true);
      final clause = fareAiFormatClause(r);
      expect(
        clause,
        contains(
          '"current_duration_is_baseline": <boolean>, "current_duration_is_low": <boolean>, '
          '"current_duration_is_heavy": <boolean>',
        ),
      );
      expect(clause, contains('"traffic_congestion": "<none|light|moderate|heavy>"'));
      expect(clause, contains('"traffic_congestion_stretch_location_details": [{"road": "<road name>"'));
      expect(r.isDefault, isFalse);
      final back = FareAiRequest.fromJson(r.toJson());
      expect((back.includeFareRange, back.includeTraffic), (true, true));
    });

    test('the answers read as lines', () {
      expect(fareAiTrafficLines(null), isEmpty);
      expect(
        fareAiTrafficLines({
          'current_duration_is_baseline': false,
          'current_duration_is_low': false,
          'current_duration_is_heavy': true,
          'traffic_congestion': 'heavy',
          'traffic_congestion_stretch_location_details': [
            {'road': 'MEX', 'from': 'Seri Kembangan', 'to': 'Putrajaya', 'delay_min': 8},
            {'road': 'ELITE'},
          ],
        }),
        ['Drive time: heavier than usual', 'Traffic: heavy', '• MEX (Seri Kembangan → Putrajaya) · +8 min', '• ELITE'],
      );
    });
  });

  group('retry', () {
    test('minutes are a unit', () {
      final c = normalizeFareAi({'retryAfterValue': 15, 'retryAfterUnit': 'minute'});
      expect(c.retryAfterUnit, 'minute');
      expect(retryLabel(c), '15 minutes');
      expect(retryPolicyMs(15, 'minute'), 15 * 60 * 1000);
      expect(retryUnits.keys.first, 'minute');
    });
  });

  group('Request & format screen', () {
    Future<_Repo> pump(WidgetTester tester, {FareAiConfig? config}) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo(
        config ?? normalizeFareAi(null).withKeys('gemini', [FareAiKey.create(id: 'k1', label: 'Key 1', key: 'AIza')]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            securityRepositoryProvider.overrideWithValue(repo),
            adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          ],
          child: const MaterialApp(home: AdminFareAiRequestScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('a prompt without the trip cannot be saved or tested', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const ValueKey('fare-ai-template')), 'Estimate a drive.');
      await tester.pump();
      expect(find.textContaining('must include {origin}'), findsWidgets);
      FilledButton save() => tester.widget(
        find.descendant(of: find.byKey(const ValueKey('fare-ai-request-save')), matching: find.byType(FilledButton)),
      );
      expect(save().onPressed, isNull);
    });

    testWidgets('a test request runs the draft and shows the answer', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('ask-tolls')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fare-ai-run-test')));
      await tester.pumpAndSettle();
      expect(repo.tested.single.includeTolls, isFalse, reason: 'the unsaved draft is what is tested');
      expect(find.byKey(const ValueKey('fare-ai-test-result')), findsOneWidget);
      expect(find.text('4.2 km · 11 min'), findsOneWidget);
      expect(repo.saved, isEmpty, reason: 'testing saves nothing');
    });

    testWidgets('fare range and traffic switches go into the test and the save', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('ask-fare-range')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ask-traffic')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fare-ai-run-test')));
      await tester.pumpAndSettle();
      expect(repo.tested.single.includeFareRange, isTrue);
      expect(repo.tested.single.includeTraffic, isTrue);
      await tester.tap(find.byKey(const ValueKey('fare-ai-request-save')));
      await tester.pumpAndSettle();
      expect(repo.config.request.includeFareRange, isTrue);
      expect(repo.config.request.includeTraffic, isTrue);
    });

    testWidgets('saving keeps the keys and provider, and reset brings back the default', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('ask-summary')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fare-ai-request-save')));
      await tester.pumpAndSettle();
      expect(repo.saved, hasLength(1));
      expect(repo.config.request.includeSummary, isFalse);
      expect(repo.config.keysFor('gemini').single.key, 'AIza');

      await tester.tap(find.byKey(const ValueKey('fare-ai-request-reset')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fare-ai-request-save')));
      await tester.pumpAndSettle();
      expect(repo.config.request.isDefault, isTrue);
      expect(repo.config.toJson().containsKey('request'), isFalse);
    });
  });
}
