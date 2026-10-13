import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/wallet_once.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A Supabase client whose server is [answer], recording every RPC call.
({SupabaseClient db, List<({String fn, Map<String, dynamic> body})> calls}) _server(
  Future<http.Response> Function(String fn, Map<String, dynamic> body, int n) answer,
) {
  final calls = <({String fn, Map<String, dynamic> body})>[];
  final client = MockClient((req) async {
    final fn = req.url.pathSegments.last;
    final body = req.body.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(req.body) as Map);
    calls.add((fn: fn, body: body));
    final r = await answer(fn, body, calls.length);
    // The client reads the request back off the response.
    return http.Response(r.body, r.statusCode, headers: r.headers, request: req);
  });
  final db = SupabaseClient('https://x.supabase.co', 'anon', httpClient: client);
  return (db: db, calls: calls);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const _params = {
  'p_user': 'u1',
  'p_amount': 10.0,
  'p_note': 'QR payment',
  'p_method': 'qr_scan',
  'p_redeem_coins': false,
};

void main() {
  test('the action key ignores argument order', () {
    expect(walletActionKey('wallet_pay', {'a': 1, 'b': 2}), walletActionKey('wallet_pay', {'b': 2, 'a': 1}));
    expect(walletActionKey('wallet_pay', {'a': 1}), isNot(walletActionKey('wallet_pay', {'a': 2})));
  });

  test('a retry after an unanswered call reuses its request id; an answer drops it', () async {
    final ids = WalletRequestIds();
    final s = _server((fn, body, n) async {
      if (n == 1) throw http.ClientException('connection reset');
      return _json({'wallet_paid': 10});
    });

    // The first attempt never gets an answer.
    await expectLater(callWalletOnce(s.db, 'wallet_pay', _params, ids: ids), throwsA(isA<Exception>()));
    // The user taps again: same action, same id -- the server pays at most once.
    final r = await callWalletOnce(s.db, 'wallet_pay', _params, ids: ids);
    expect(r, {'wallet_paid': 10});
    expect(s.calls.map((c) => c.fn), ['wallet_pay_once', 'wallet_pay_once']);
    expect(s.calls[0].body['p_request_id'], isNotNull);
    expect(s.calls[1].body['p_request_id'], s.calls[0].body['p_request_id']);

    // Answered: paying the same again on purpose is a new payment.
    await callWalletOnce(s.db, 'wallet_pay', _params, ids: ids);
    expect(s.calls[2].body['p_request_id'], isNot(s.calls[0].body['p_request_id']));
  });

  test('an unanswered attempt is retried with its id only for a while', () {
    var now = DateTime(2026, 10, 13, 9);
    final ids = WalletRequestIds(clock: () => now);
    final action = walletActionKey('wallet_pay', _params);
    final first = ids.idFor(action);
    now = now.add(const Duration(minutes: 9));
    expect(ids.idFor(action), first);
    // Long after: the same amount to the same place is a new payment.
    now = now.add(WalletRequestIds.keepFor + const Duration(minutes: 1));
    expect(ids.idFor(action), isNot(first));
  });

  test("a refusal is the server's answer: the next attempt is a new request", () async {
    final ids = WalletRequestIds();
    final s = _server((fn, body, n) async {
      if (n == 1) return _json({'code': 'P0001', 'message': 'insufficient_balance'}, 400);
      return _json({'wallet_paid': 10});
    });
    await expectLater(callWalletOnce(s.db, 'wallet_pay', _params, ids: ids), throwsA(isA<PostgrestException>()));
    expect(ids.isPending(walletActionKey('wallet_pay', _params)), isFalse);
    await callWalletOnce(s.db, 'wallet_pay', _params, ids: ids);
    expect(s.calls[1].body['p_request_id'], isNot(s.calls[0].body['p_request_id']));
  });

  test('a database without the _once twins gets the plain call', () async {
    final ids = WalletRequestIds();
    final s = _server((fn, body, n) async {
      if (fn == 'wallet_pay_once') {
        return _json({'code': 'PGRST202', 'message': 'Could not find the function public.wallet_pay_once'}, 404);
      }
      return _json({'wallet_paid': 10});
    });
    final r = await callWalletOnce(s.db, 'wallet_pay', _params, ids: ids);
    expect(r, {'wallet_paid': 10});
    expect(s.calls.map((c) => c.fn), ['wallet_pay_once', 'wallet_pay']);
    // The plain call takes exactly its own arguments.
    expect(s.calls[1].body.containsKey('p_request_id'), isFalse);
    expect(s.calls[1].body['p_amount'], 10.0);
  });
}
