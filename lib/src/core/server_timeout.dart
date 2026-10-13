/// How long the app waits on a Supabase request before giving up on it, and
/// what it tells the user when it does.
///
/// Every request (the database, edge functions, storage, sign-in) goes
/// through one HTTP client with these limits (`data/timeout_http_client.dart`),
/// so a request the server never answers ends in an error the screen already
/// handles instead of a spinner that turns until the app is closed. During
/// the October 2026 Supabase slowdown single requests hung for minutes.
library;

import 'dart:async';

/// The database and sign-in: a normal answer takes well under a second.
const defaultRequestTimeout = Duration(seconds: 20);

/// Edge functions: some call out again (document AI, the store APIs).
const functionRequestTimeout = Duration(seconds: 60);

/// Storage: photo, voice-note and document uploads on a slow connection.
const storageRequestTimeout = Duration(seconds: 120);

/// The calls that move money without a guard against being made twice.
const moneyRequestTimeout = Duration(seconds: 45);

/// Database functions that move money and are not safe to repeat: when one
/// times out it may still have gone through, so the user is told to check
/// before trying again. (The per-ride ones -- fare coins, commission, ride
/// reward -- are idempotent and are not listed.)
const unconfirmedMoneyRpcs = {
  'wallet_pay',
  'wallet_topup',
  'wallet_recharge_credit',
  'wallet_trade_coins',
  'wallet_transfer_coins',
  'wallet_request_coin_transfer',
  // Their repeat-safe twins (0164): still unknown when they time out, but a
  // retry of the same action reuses its request id and cannot pay twice.
  'wallet_pay_once',
  'wallet_recharge_credit_once',
  'wallet_trade_coins_once',
  'wallet_transfer_coins_once',
  'wallet_request_coin_transfer_once',
};

/// The limit for one request, and whether a timeout leaves its outcome
/// unknown (a money call that may have gone through). Pure.
({Duration limit, bool unconfirmed}) requestTimeoutFor(Uri url) {
  final path = url.path;
  if (path.contains('/storage/v1/')) return (limit: storageRequestTimeout, unconfirmed: false);
  if (path.contains('/functions/v1/')) return (limit: functionRequestTimeout, unconfirmed: false);
  final rpc = RegExp(r'/rest/v1/rpc/([A-Za-z0-9_]+)').firstMatch(path)?.group(1);
  if (rpc != null && unconfirmedMoneyRpcs.contains(rpc)) {
    return (limit: moneyRequestTimeout, unconfirmed: true);
  }
  return (limit: defaultRequestTimeout, unconfirmed: false);
}

/// A request the server did not answer in time. A [TimeoutException], so
/// code that already catches those still does; its text is fit to show.
class ServerTimeout extends TimeoutException {
  ServerTimeout({required Duration limit, required this.unconfirmed})
    : super(unconfirmed ? unconfirmedTimeoutMessage : serverTimeoutMessage, limit);

  /// True when the request may still have succeeded (see [unconfirmedMoneyRpcs]).
  final bool unconfirmed;

  @override
  String toString() => message ?? serverTimeoutMessage;
}

const serverTimeoutMessage = 'The server is taking too long to answer. Please try again.';
const unconfirmedTimeoutMessage =
    "The server didn't confirm this in time. It may still have gone through, so check your "
    'wallet history before trying again.';

/// The words for [error] when it is a [ServerTimeout], else null -- for the
/// screens that map errors to their own messages and would otherwise say
/// "failed, please try again" about a payment that may have gone through.
String? serverTimeoutText(Object error) => error is ServerTimeout ? error.message : null;
