// The rides kept on this phone (lib/src/core/ride_cache.dart): read when the
// server can't be reached, written whenever it answers.
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

  Future<CachedRide?> ride(String id) async => (await read())[id];
}
