import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/coin_trade.dart';
import 'package:get_ride/src/core/coin_transfer.dart';
import 'package:get_ride/src/core/credit_recharge.dart';
import 'package:get_ride/src/core/server_timeout.dart';
import 'package:get_ride/src/core/wallet_qr.dart';
import 'package:get_ride/src/data/timeout_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _base = 'https://x.supabase.co';

void main() {
  group('requestTimeoutFor', () {
    test('database reads and writes, and sign-in, get the default', () {
      for (final path in ['/rest/v1/ride_requests?select=*', '/auth/v1/token', '/rest/v1/rpc/resolve_qr']) {
        final t = requestTimeoutFor(Uri.parse('$_base$path'));
        expect(t.limit, defaultRequestTimeout, reason: path);
        expect(t.unconfirmed, isFalse, reason: path);
      }
    });

    test('edge functions and storage get longer', () {
      expect(requestTimeoutFor(Uri.parse('$_base/functions/v1/document-ai-verify')).limit, functionRequestTimeout);
      expect(
        requestTimeoutFor(Uri.parse('$_base/storage/v1/object/support-media/a/b.jpg')).limit,
        storageRequestTimeout,
      );
    });

    test('money calls that are not safe to repeat leave the outcome unknown', () {
      for (final rpc in unconfirmedMoneyRpcs) {
        final t = requestTimeoutFor(Uri.parse('$_base/rest/v1/rpc/$rpc'));
        expect(t.limit, moneyRequestTimeout, reason: rpc);
        expect(t.unconfirmed, isTrue, reason: rpc);
      }
      // The per-ride ones are idempotent: a plain retry is safe.
      expect(requestTimeoutFor(Uri.parse('$_base/rest/v1/rpc/wallet_redeem_fare_coins')).unconfirmed, isFalse);
      expect(requestTimeoutFor(Uri.parse('$_base/rest/v1/rpc/wallet_award_ride_coins')).unconfirmed, isFalse);
    });
  });

  group('TimeoutHttpClient', () {
    test('a request the server never answers fails once its limit passes', () {
      fakeAsync((clock) {
        final client = TimeoutHttpClient(MockClient.streaming((_, _) => Completer<http.StreamedResponse>().future));
        Object? failure;
        client.get(Uri.parse('$_base/rest/v1/settings_entries')).catchError((Object e) {
          failure = e;
          return http.Response('', 599);
        });
        clock.elapse(defaultRequestTimeout - const Duration(seconds: 1));
        expect(failure, isNull);
        clock.elapse(const Duration(seconds: 2));
        expect(failure, isA<ServerTimeout>());
        expect((failure! as ServerTimeout).unconfirmed, isFalse);
        expect('$failure', serverTimeoutMessage);
      });
    });

    test('a payment that times out says it may have gone through', () {
      fakeAsync((clock) {
        final client = TimeoutHttpClient(MockClient.streaming((_, _) => Completer<http.StreamedResponse>().future));
        Object? failure;
        client.post(Uri.parse('$_base/rest/v1/rpc/wallet_pay'), body: '{}').catchError((Object e) {
          failure = e;
          return http.Response('', 599);
        });
        clock.elapse(moneyRequestTimeout + const Duration(seconds: 1));
        expect(failure, isA<ServerTimeout>());
        expect((failure! as ServerTimeout).unconfirmed, isTrue);
        // Still a TimeoutException, for code that already catches those.
        expect(failure, isA<TimeoutException>());
      });
    });

    test('an answer in time passes straight through', () async {
      final client = TimeoutHttpClient(MockClient((_) async => http.Response('[]', 200)));
      final r = await client.get(Uri.parse('$_base/rest/v1/settings_entries'));
      expect(r.statusCode, 200);
      expect(r.body, '[]');
    });
  });

  test('every money screen tells the user to check before paying again', () {
    final unknown = ServerTimeout(limit: moneyRequestTimeout, unconfirmed: true);
    for (final message in [
      walletPayErrorMessage(unknown),
      coinTradeErrorMessage(unknown),
      coinSendErrorMessage(unknown),
      rechargeCreditErrorMessage(unknown),
    ]) {
      expect(message, unconfirmedTimeoutMessage);
      expect(message, isNot(contains('Please try again')));
    }
    // Other failures keep their own words.
    expect(walletPayErrorMessage(Exception('insufficient_balance')), 'Not enough balance in GET.wallet.');
  });
}
