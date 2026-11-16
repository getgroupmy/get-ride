import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare_timing.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('FareTiming', () {
    test('defaults as the server has them; seconds bounded; two settings', () {
      const d = FareTiming.defaults;
      expect([d.liveSeconds, d.appleSeconds, d.aiSeconds, d.osrmSeconds, d.appWaitSeconds, d.deviceApple, d.deviceAppleSeconds],
          [3, 1.5, 5, 3, 5, true, 1.5]);
      expect(d.appWait, const Duration(seconds: 5));
      final t = FareTiming.fromJson(
        server: {'liveSeconds': 2, 'appleSeconds': 99, 'aiSeconds': 'x', 'osrmSeconds': 0.1},
        app: {'appWaitSeconds': 7.5, 'deviceApple': false, 'deviceAppleSeconds': 1},
      );
      expect([t.liveSeconds, t.appleSeconds, t.aiSeconds, t.osrmSeconds], [2, 10, 5, 0.5]);
      expect([t.appWaitSeconds, t.deviceApple, t.deviceAppleSeconds], [7.5, false, 1]);
      expect(FareTiming.fromJson(server: t.serverJson(), app: t.appJson()), t);
      expect(t.appJson().keys, ['appWaitSeconds', 'deviceApple', 'deviceAppleSeconds']);
    });

    test('an iPhone answer is badged Apple Maps', () {
      final e = deviceAppleEstimate(41.43, 47.2, 1);
      expect([e.distanceKm, e.durationMin, e.provider, e.stops], [41.4, 48, 'apple_device', 1]);
      expect(EstimateSource.of(e), EstimateSource.apple);
    });
  });

  group('the iPhone hand-off', () {
    late List<Map<String, dynamic>> bodies;
    late List<Map<String, dynamic>> answers;

    RouteEstimateRepository repo({required Future<({double km, double minutes})?> Function() apple}) {
      final db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) async {
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          final a = answers.isEmpty ? {'ok': true} : answers.removeAt(0);
          return http.Response(jsonEncode(a), 200, headers: {'content-type': 'application/json'}, request: r);
        }),
      );
      addTearDown(db.dispose);
      return RouteEstimateRepository(db, onIphone: true, deviceApple: (points, within) => apple());
    }

    setUp(() {
      bodies = [];
      answers = [];
    });

    const a = LatLng(3.158, 101.712), b = LatLng(2.93, 101.87);

    test('Waze answers: the phone only says it can ask Apple Maps', () async {
      answers = [
        {'ok': true, 'estimate': {'distance_km': 46.9, 'duration_min': 46, 'provider': 'waze'}},
      ];
      final r = await repo(apple: () async => fail('not asked')).estimateDetailed(a, b);
      expect(r?.estimate?.provider, 'waze');
      expect(bodies.single['device'], 'ios_mapkit');
    });

    test('the order reaches Apple Maps: the phone answers and reports it', () async {
      answers = [
        {'ok': true, 'estimate': null, 'reason': 'device_apple', 'remaining': ['ai', 'osrm']},
      ];
      final r = await repo(apple: () async => (km: 41.4, minutes: 47.0)).estimateDetailed(a, b);
      expect(r?.estimate?.provider, 'apple_device');
      expect(r?.estimate?.distanceKm, 41.4);
      for (var i = 0; i < 50 && bodies.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(bodies.length, 2);
      expect(bodies[1]['report'], {'success': true, 'distance_km': 41.4, 'duration_min': 47.0, 'latency_ms': isA<int>()});
      expect(bodies[1].containsKey('resume'), isFalse);
    });

    test('Apple Maps on the phone misses: the server goes on with the rest', () async {
      answers = [
        {'ok': true, 'estimate': null, 'reason': 'device_apple', 'remaining': ['ai', 'osrm']},
        {'ok': true}, // the report
        {'ok': true, 'estimate': {'distance_km': 40, 'duration_min': 50, 'provider': 'gemini'}},
      ];
      final r = await repo(apple: () async => null).estimateDetailed(a, b);
      expect(r?.estimate?.provider, 'gemini');
      final resume = bodies.firstWhere((x) => x.containsKey('resume'));
      expect(resume['resume'], ['ai', 'osrm']);
      expect(bodies.any((x) => x['report']?['success'] == false), isTrue);
    });

    test('switched off in Admin: an ordinary request', () async {
      answers = [{'ok': true, 'estimate': null, 'reason': 'no_keys'}];
      final r = await repo(apple: () async => fail('not asked'))
          .estimateDetailed(a, b, timing: FareTiming.defaults.copyWith(deviceApple: false));
      expect(r?.unavailable, isTrue);
      expect(bodies.single.containsKey('device'), isFalse);
    });
  });
}
