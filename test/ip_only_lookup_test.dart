// The device blacklist check asks `ip-lookup` for the address alone
// (`ip_only`: no rate check and no ISP provider on the server), once per
// launch, and reuses the full answer when the session rows already have it.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/session_telemetry.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/session_tracker.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

SupabaseClient _client(List<http.Request> seen, {String ip = '203.0.113.9', bool fail = false}) => SupabaseClient(
  'http://localhost',
  'anon',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
  httpClient: MockClient((r) async {
    seen.add(r);
    final json = {'content-type': 'application/json'};
    if (r.url.path.endsWith('/functions/v1/ip-lookup')) {
      if (fail) return http.Response('{"error":"boom"}', 500, headers: json, request: r);
      return http.Response(jsonEncode({'public_ip': ip}), 200, headers: json, request: r);
    }
    if (r.url.path.endsWith('/rest/v1/ip_access_rules')) {
      final asked = r.url.queryParameters['ip_address'];
      final rows = asked == 'eq.$ip' ? [{'list_type': 'blacklist'}] : <Object>[];
      return http.Response(jsonEncode(rows), 200, headers: json, request: r);
    }
    return http.Response('[]', 200, headers: json, request: r);
  }),
);

bool _isLookup(http.Request r) => r.url.path.endsWith('/functions/v1/ip-lookup');

void main() {
  test('lookupCallerIp asks for the address only', () async {
    final seen = <http.Request>[];
    final db = _client(seen);
    addTearDown(db.dispose);
    expect(await lookupCallerIp(db), '203.0.113.9');
    expect(seen.where(_isLookup), hasLength(1));
    expect(jsonDecode(seen.single.body), {'ip_only': true});
  });

  test('lookupCallerIp is null when ip-lookup fails', () async {
    final seen = <http.Request>[];
    final db = _client(seen, fail: true);
    addTearDown(db.dispose);
    expect(await lookupCallerIp(db), isNull);
  });

  group('LaunchIpCache.publicIp', () {
    test('asks once, shares the answer, and asks again after a failure', () async {
      final cache = LaunchIpCache();
      var calls = 0;
      Future<String?> lookup() async {
        calls++;
        return calls == 1 ? null : '5.6.7.8';
      }

      expect(await cache.publicIp(lookup), isNull);
      final a = cache.publicIp(lookup), b = cache.publicIp(lookup);
      expect(await a, '5.6.7.8');
      expect(await b, '5.6.7.8');
      expect(await cache.publicIp(lookup), '5.6.7.8');
      expect(calls, 2);
      // The address-only answer does not stand in for the full one.
      expect(cache.value, isNull);
      expect(cache.knownIp, '5.6.7.8');
    });

    test('the full answer, once in, is used without another lookup', () async {
      final cache = LaunchIpCache();
      await cache.get(() async => const IpInfo(publicIp: '1.2.3.4', ispProvider: 'TM Net'));
      var calls = 0;
      expect(
        await cache.publicIp(() async {
          calls++;
          return '9.9.9.9';
        }),
        '1.2.3.4',
      );
      expect(calls, 0);
    });

    test('the full lookup still runs for the session rows after an address-only one', () async {
      final cache = LaunchIpCache();
      expect(await cache.publicIp(() async => '1.2.3.4'), '1.2.3.4');
      var full = 0;
      final info = await cache.get(() async {
        full++;
        return const IpInfo(publicIp: '1.2.3.4', ispProvider: 'Maxis');
      });
      expect(info?.ispProvider, 'Maxis');
      expect(full, 1);
    });
  });

  test('the device check uses one address-only ip-lookup per launch', () async {
    final seen = <http.Request>[];
    final db = _client(seen);
    addTearDown(db.dispose);
    final container = ProviderContainer(
      overrides: [supabaseProvider.overrideWithValue(db), ...quietLiveOverrides],
    );
    addTearDown(container.dispose);

    expect(await container.read(deviceBlockedProvider.future), isTrue);
    container.invalidate(deviceBlockedProvider);
    expect(await container.read(deviceBlockedProvider.future), isTrue);

    final lookups = seen.where(_isLookup).toList();
    expect(lookups, hasLength(1));
    expect(jsonDecode(lookups.single.body), {'ip_only': true});
    expect(launchIp.value, isNull, reason: 'the session rows still get the full lookup');
  });
}
