// The rides kept on this phone (lib/src/core/ride_cache.dart): read when the
// server can't be reached, written whenever it answers.
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/ride_cache.dart';

const _key = 'ride_cache_v1';

class RideCacheStore {
  RideCacheStore({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  /// Writes queue behind each other so two rows seen at once both land.
  Future<void> _last = Future.value();

  Future<Map<String, CachedRide>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return decodeRideCache(prefs.getString(_key), _now());
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Map<String, dynamic> row) => _last = _last.then((_) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cache = withCachedRide(decodeRideCache(prefs.getString(_key), _now()), row, _now());
      await prefs.setString(_key, encodeRideCache(cache));
    } catch (_) {}
  });

  /// The row each ride was last kept as by [saveSeen], and when.
  final _kept = <String, ({Map<String, dynamic> row, DateTime at})>{};
  final _waiting = <String, Map<String, dynamic>>{};
  final _timers = <String, Timer>{};

  /// [save] for a row seen again and again (a ride on screen, re-read on
  /// every realtime update): skipped when only the live positions moved,
  /// and otherwise written at most once per [rideCacheLiveGap] per ride --
  /// the latest row once the gap is up -- except a new status, written at
  /// once. Each write re-encodes the whole cache.
  Future<void> saveSeen(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String) return save(row);
    final kept = _kept[id];
    final delay = rideCacheSaveDelay(last: kept?.row, lastAt: kept?.at, row: row, now: _now());
    if (delay == null) {
      _waiting.remove(id);
      _timers.remove(id)?.cancel();
      return Future.value();
    }
    if (delay == Duration.zero) {
      _waiting.remove(id);
      _timers.remove(id)?.cancel();
      return _keep(id, row);
    }
    _waiting[id] = row;
    _timers[id] ??= Timer(delay, () {
      _timers.remove(id);
      final due = _waiting.remove(id);
      if (due != null) unawaited(_keep(id, due));
    });
    return Future.value();
  }

  Future<void> _keep(String id, Map<String, dynamic> row) {
    _kept[id] = (row: row, at: _now());
    return save(row);
  }

  Future<CachedRide?> ride(String id) async => (await read())[id];
}
