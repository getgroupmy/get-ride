// A push that lands while the app is closed is acknowledged from the
// background handler with the stored session's token, never a refresh
// (lib/src/data/background_ack.dart, lib/src/core/push_logic.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/data/background_ack.dart';
import 'package:get_ride/src/data/reliability_repository.dart' show backgroundAckPrefsKey;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String session(DateTime expires, {String token = 'tok'}) =>
    jsonEncode({'access_token': token, 'expires_at': expires.millisecondsSinceEpoch ~/ 1000, 'refresh_token': 'r'});

void main() {
  final now = DateTime.utc(2026, 10, 11, 9);

  test('the session key is the one supabase_flutter stores it under', () {
    expect(supabaseSessionKey('https://abcdef.supabase.co'), 'sb-abcdef-auth-token');
  });

  test('a stored token is used only while it has time left', () {
    expect(storedAccessToken(session(now.add(const Duration(minutes: 10))), now), 'tok');
    expect(storedAccessToken(session(now.add(const Duration(seconds: 20))), now), isNull, reason: 'nearly out');
    expect(storedAccessToken(session(now.subtract(const Duration(minutes: 1))), now), isNull);
    expect(storedAccessToken(null, now), isNull);
    expect(storedAccessToken('nonsense', now), isNull);
    expect(storedAccessToken(jsonEncode({'access_token': 'tok'}), now), isNull, reason: 'no expiry');
  });

  group('acknowledging in the background', () {
    final key = supabaseSessionKey(AppConfig.supabaseUrl);
    late List<http.Request> sent;
    late MockClient client;
    setUp(() {
      sent = [];
      client = MockClient((r) async {
        sent.add(r);
        return http.Response('1', 200);
      });
    });

    test('a push with an event is acknowledged as delivered, signed in as the person', () async {
      SharedPreferences.setMockInitialValues({key: session(DateTime.now().add(const Duration(hours: 1)))});
      await ackPushInBackground({'type': 'ride_message', 'event_id': 'msg:m1'}, client: client, backendUrl: (d) async => d);
      expect(sent, hasLength(1));
      expect(sent.single.url.path, endsWith('/rest/v1/rpc/ack_notification'));
      expect(sent.single.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(sent.single.body), {'p_event_id': 'msg:m1', 'p_state': 'delivered'});
    });

    test('nothing is sent without an event, a session, or with an expired one', () async {
      SharedPreferences.setMockInitialValues({key: session(DateTime.now().add(const Duration(hours: 1)))});
      await ackPushInBackground({'type': 'ride_message'}, client: client, backendUrl: (d) async => d);
      SharedPreferences.setMockInitialValues({});
      await ackPushInBackground({'event_id': 'msg:m1'}, client: client, backendUrl: (d) async => d);
      SharedPreferences.setMockInitialValues({key: session(DateTime.now().subtract(const Duration(minutes: 5)))});
      await ackPushInBackground({'event_id': 'msg:m1'}, client: client, backendUrl: (d) async => d);
      expect(sent, isEmpty);
    });

    test('nothing is sent when Admin → Reliability has it off', () async {
      SharedPreferences.setMockInitialValues({
        key: session(DateTime.now().add(const Duration(hours: 1))),
        backgroundAckPrefsKey: false,
      });
      await ackPushInBackground({'event_id': 'msg:m1'}, client: client, backendUrl: (d) async => d);
      expect(sent, isEmpty);
    });

    test('a failing network is swallowed', () async {
      SharedPreferences.setMockInitialValues({key: session(DateTime.now().add(const Duration(hours: 1)))});
      await ackPushInBackground({'event_id': 'msg:m1'}, client: MockClient((_) async => throw Exception('offline')));
    });
  });
}
