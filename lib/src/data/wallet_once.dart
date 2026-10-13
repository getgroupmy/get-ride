import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Money calls that are safe to repeat (migration 0164).
///
/// Each money RPC has a `_once` twin that takes a request id and runs at most
/// once per id. The app keeps an id for an action only while its outcome is
/// unknown -- the call timed out or the connection failed -- so the next tap
/// on the same action (same RPC, same arguments) reuses it and the server
/// answers with the first call's result instead of moving the money again.
/// Once the server has answered, either way, the id is dropped: paying the
/// same amount again on purpose is a new payment.
class WalletRequestIds {
  final _pending = <String, String>{};
  final _uuid = const Uuid();

  /// The id for [action]: the one kept from an unanswered attempt, else new.
  String idFor(String action) => _pending[action] ??= _uuid.v4();

  /// The server answered [action]; its next attempt is a new request.
  void settled(String action) => _pending.remove(action);

  /// Whether [action] has an unanswered attempt (for tests).
  bool isPending(String action) => _pending.containsKey(action);
}

/// The ids kept this session.
final walletRequestIds = WalletRequestIds();

/// What makes two attempts the same action: the RPC and its arguments,
/// keys in order. Pure.
String walletActionKey(String fn, Map<String, dynamic> params) {
  final keys = params.keys.toList()..sort();
  return '$fn ${jsonEncode({for (final k in keys) k: params[k]})}';
}

/// Whether [error] means the database has no `_once` twin (a project
/// without 0164): the plain RPC is called instead. Pure.
bool isMissingOnceRpc(Object error) {
  if (error is! PostgrestException) return false;
  final m = error.message.toLowerCase();
  return error.code == 'PGRST202' || m.contains('could not find the function');
}

/// Whether [error] is the server's own answer -- a refusal it made, so the
/// call did not run and a retry is a new request. Anything else (a timeout,
/// a dropped connection) leaves the outcome unknown. Pure.
bool isServerAnswer(Object error) => error is PostgrestException;

/// Calls [fn] once per action: through its `_once` twin with the action's
/// request id, or the plain RPC on a database without the twins.
Future<dynamic> callWalletOnce(
  SupabaseClient db,
  String fn,
  Map<String, dynamic> params, {
  WalletRequestIds? ids,
}) async {
  final kept = ids ?? walletRequestIds;
  final action = walletActionKey(fn, params);
  final id = kept.idFor(action);
  try {
    dynamic result;
    try {
      result = await db.rpc('${fn}_once', params: {'p_request_id': id, ...params});
    } catch (e) {
      if (!isMissingOnceRpc(e)) rethrow;
      result = await db.rpc(fn, params: params);
    }
    kept.settled(action);
    return result;
  } catch (e) {
    if (isServerAnswer(e)) kept.settled(action);
    rethrow;
  }
}
