// The ride extras each driver turned off (Settings → Ride extras I take;
// migration 0253). The driver reads and writes their own row; admins read
// every driver's.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'live_tables.dart';

const driverRideExtrasTable = 'driver_ride_extras';

class DriverExtrasRepository {
  DriverExtrasRepository(this._db);
  final SupabaseClient _db;

  String? get _uid => _db.auth.currentUser?.id;

  /// What [driverId] turned off; none without a row (or before 0253).
  Future<Set<String>> of(String driverId) async {
    try {
      final row = await _db.from(driverRideExtrasTable).select('off').eq('driver_id', driverId).maybeSingle();
      final off = row?['off'];
      return {if (off is List) for (final k in off) if (k is String) k};
    } catch (_) {
      return const {};
    }
  }

  /// The signed-in driver's.
  Future<Set<String>> mine() async {
    final uid = _uid;
    return uid == null ? const {} : of(uid);
  }

  /// The signed-in driver turns off exactly [off].
  Future<void> setMine(Set<String> off) async {
    final uid = _uid;
    if (uid == null) return;
    await _db.from(driverRideExtrasTable).upsert({'driver_id': uid, 'off': [...off]..sort()}, onConflict: 'driver_id');
  }

  /// [keys] turned off too, keeping the rest.
  Future<void> turnOff(Iterable<String> keys) async {
    if (keys.isEmpty) return;
    await setMine({...await mine(), ...keys});
  }

  /// How many open requests since [since] the feed leaves out for an extra
  /// the driver turned off; 0 when it can't be asked.
  Future<int> hiddenCount(DateTime since) async {
    try {
      final n = await _db.rpc('ride_extras_hidden_count', params: {'p_since': since.toUtc().toIso8601String()});
      return n is num ? n.toInt() : 0;
    } catch (_) {
      return 0;
    }
  }
}

final driverExtrasRepositoryProvider = Provider((ref) => DriverExtrasRepository(ref.watch(supabaseProvider)));

/// The signed-in driver's extras turned off.
final myExtrasOffProvider = FutureProvider.autoDispose<Set<String>>((ref) {
  ref.watchLive(driverRideExtrasTable);
  return ref.watch(driverExtrasRepositoryProvider).mine();
});

/// A driver's, for their admin page.
final driverExtrasOffProvider = FutureProvider.autoDispose.family<Set<String>, String>((ref, driverId) {
  ref.watchLive(driverRideExtrasTable);
  return ref.watch(driverExtrasRepositoryProvider).of(driverId);
});
