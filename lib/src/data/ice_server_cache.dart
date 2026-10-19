// The ICE servers for a call, fetched ahead and kept in memory (PERF-70).
// turn-credentials took 0.4 s at the median and 1.6 s at p95, and every call
// waited for it before it could open its connection. Its credentials last
// hours (`ttl` in the answer), so they are fetched as a call comes up (the
// call button pressed, the phone ringing, the call screen opening) and the
// same set serves every call until shortly before it expires.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/support_call.dart' show parseIceServers;
import 'function_region.dart';

/// How long before the relay credentials expire a cached set stops being
/// handed out, so a call never starts on credentials about to lapse (or
/// already lapsed by a phone clock a little off). Never more than half the
/// credentials' lifetime.
const iceServersRenewBefore = Duration(minutes: 30);

/// Until when a set fetched at [fetchedAt] with a lifetime of [ttlSeconds]
/// may be handed out; null when the answer named no usable lifetime (it is
/// then not kept at all). Pure.
DateTime? iceServersUsableUntil(DateTime fetchedAt, Object? ttlSeconds) {
  if (ttlSeconds is! num || !ttlSeconds.isFinite || ttlSeconds <= 0) return null;
  final life = Duration(milliseconds: (ttlSeconds * 1000).floor());
  final margin = life > iceServersRenewBefore * 2 ? iceServersRenewBefore : life ~/ 2;
  return fetchedAt.add(life - margin);
}

class _Cached {
  _Cached(this.user, this.servers, this.until);
  final String? user;
  final List<Map<String, dynamic>> servers;
  final DateTime until;
}

/// The ICE servers of one client, one set at a time, for the signed-in
/// account (the relay credentials name it). A fetch that fails is not kept:
/// the call gets STUN only, as before, and the next asks again.
class IceServerCache {
  /// A cache over [fetch] (turn-credentials' answer), for whoever [user]
  /// says is signed in; [clock] is for tests. [IceServerCache.of] for a
  /// client.
  IceServerCache(this._fetch, {String? Function()? user, DateTime Function()? clock})
    : _user = user ?? (() => null),
      _clock = clock ?? DateTime.now;

  static final _caches = Expando<IceServerCache>();

  /// The cache of [db]: support calls and ride calls share it.
  static IceServerCache of(SupabaseClient db) => _caches[db] ??= IceServerCache(
    () async => (await db.functions.invokeNearDb('turn-credentials')).data,
    user: () => db.auth.currentUser?.id,
  );

  final Future<Object?> Function() _fetch;
  final String? Function() _user;
  final DateTime Function() _clock;

  _Cached? _cached;
  Future<List<Map<String, dynamic>>>? _loading;
  String? _loadingUser;

  /// Fetches ahead if nothing usable is kept; never throws.
  void prefetch() {
    if (_usable() != null) return;
    unawaited(_load().then((_) {}, onError: (Object _) {}));
  }

  /// The servers for a call starting now: the kept set while it is still
  /// good for this account, else a fresh fetch (sharing one under way), else
  /// STUN only.
  Future<List<Map<String, dynamic>>> get() async {
    final kept = _usable();
    if (kept != null) return kept;
    try {
      return await _load();
    } catch (_) {
      return parseIceServers(null);
    }
  }

  List<Map<String, dynamic>>? _usable() {
    final c = _cached;
    if (c == null) return null;
    if (c.user != _user() || !_clock().isBefore(c.until)) {
      _cached = null;
      return null;
    }
    return c.servers;
  }

  Future<List<Map<String, dynamic>>> _load() {
    final user = _user();
    final loading = _loading;
    if (loading != null && _loadingUser == user) return loading;
    final at = _clock();
    late final Future<List<Map<String, dynamic>>> f;
    f = _fetch()
        .then((body) {
          final servers = parseIceServers(body);
          final until = iceServersUsableUntil(at, body is Map ? body['ttl'] : null);
          if (until != null && body is Map && body['iceServers'] is List) _cached = _Cached(user, servers, until);
          return servers;
        })
        .whenComplete(() {
          if (identical(_loading, f)) _loading = null;
        });
    _loading = f;
    _loadingUser = user;
    return f;
  }
}
