// PERF-71: the edge functions that chain database calls are run in the
// database's region (lib/src/data/function_region.dart); the others are not.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/function_region.dart';
import 'package:get_ride/src/data/map_profile_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<http.BaseRequest> seen;
  late SupabaseClient db;

  setUp(() {
    seen = [];
    db = SupabaseClient(
      'http://localhost',
      'anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        seen.add(r);
        return http.Response('{}', 200, headers: {'content-type': 'application/json'}, request: r);
      }),
    );
    addTearDown(db.dispose);
  });

  http.BaseRequest call(String name) => seen.singleWhere((r) => r.url.path == '/functions/v1/$name');

  void expectPinned(http.BaseRequest r) {
    expect(r.headers['x-region'], 'ap-northeast-2');
    expect(r.url.queryParameters['forceFunctionRegion'], 'ap-northeast-2');
  }

  test('the database-heavy functions only', () {
    expect(dbPinnedFunctions, {'geo', 'pin-login', 'ip-lookup', 'ai-route-proxy'});
    expect(functionRegionHeaders('geo', isWeb: false), {'x-region': 'ap-northeast-2'});
    for (final name in ['send-push', 'turn-credentials', 'document-ai-verify', 'region-defaults', 'key-test']) {
      expect(functionRegionHeaders(name, isWeb: false), isEmpty, reason: name);
      expect(functionRegionQuery(name), isEmpty, reason: name);
    }
  });

  test('on the web only the query parameter, so CORS does not refuse the call', () {
    expect(functionRegionHeaders('geo', isWeb: true), isEmpty);
    expect(functionRegionQuery('geo'), {'forceFunctionRegion': 'ap-northeast-2'});
  });

  test('geo lookups keep their own parameters and are pinned', () async {
    await GeoProxy(() => db, role: () => 'rider').get({'action': 'reverse', 'lat': '3.1', 'lng': '101.6'});
    final r = call('geo');
    expectPinned(r);
    expect(r.method, 'GET');
    expect(r.url.queryParameters['action'], 'reverse');
    expect(r.url.queryParameters['role'], 'rider');
  });

  test('pin sign-in is pinned', () async {
    await AuthRepository(db).signInWithPin('+60123456789', '123456');
    expectPinned(call('pin-login'));
  });

  test('ip lookup is pinned', () async {
    await RideRepository(db).publicIp();
    expectPinned(call('ip-lookup'));
  });

  test('the AI fare estimate is pinned', () async {
    await RouteEstimateRepository(db).estimateDetailed(const LatLng(3.1, 101.6), const LatLng(3.2, 101.7));
    final r = call('ai-route-proxy');
    expectPinned(r);
    expect(r.method, 'POST');
  });

  test('other functions are left where they run', () async {
    await db.functions.invokeNearDb('send-push', body: {'x': 1});
    final r = call('send-push');
    expect(r.headers.containsKey('x-region'), isFalse);
    expect(r.url.queryParameters, isEmpty);
  });
}
