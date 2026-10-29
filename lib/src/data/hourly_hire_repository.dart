// Hourly hire (migration 0326): the settings, the server's quote, a hire's
// extensions and its end, and a driver's "Take hourly hire" switch. Booking
// a hire is RideRepository.createRequest with its hours (a ride_requests row
// with hire columns), so it is the Ride module's repository too.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/hourly_hire.dart';
import '../providers.dart';
import 'driver_extras_repository.dart' show driverRideExtrasTable;
import 'live_tables.dart';

/// A refusal from the server (its HIRE_* code), as one sentence.
class HireError implements Exception {
  const HireError(this.message);
  final String message;

  static Object wrap(Object e) {
    if (e is! PostgrestException) return e;
    final hint = e.hint?.trim();
    return HireError(hint != null && hint.isNotEmpty ? hint : hireRefusalText(e.message) ?? e.message);
  }

  @override
  String toString() => message;
}

/// The place a quote is for (the pickup's country, state, city, suburb).
typedef HirePlace = ({String? country, String? state, String? city, String? suburb});

class HourlyHireRepository {
  HourlyHireRepository(this._db);
  final SupabaseClient _db;

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw HireError.wrap(e);
    }
  }

  Future<HourlyHireConfig> config() async {
    final v = await _db.rpc('hourly_hire_config');
    return v is Map ? HourlyHireConfig.fromJson(Map<String, dynamic>.from(v)) : HourlyHireConfig.off;
  }

  /// Admin › Settings › Hourly hire: saved as the server keeps it.
  Future<HourlyHireConfig> save(HourlyHireConfig c) => _call(() async {
    final v = await _db.rpc('set_hourly_hire_config', params: {'p_config': c.toJson()});
    return v is Map ? HourlyHireConfig.fromJson(Map<String, dynamic>.from(v)) : c;
  });

  /// The server's price for [hours] of [service] from [pickup] (and to
  /// [drop], for its place fee) at [at] (null: now).
  Future<HireQuote> quote({
    required ({double lat, double lng}) pickup,
    ({double lat, double lng})? drop,
    required String service,
    double? hours,
    DateTime? at,
    HirePlace place = (country: null, state: null, city: null, suburb: null),
    String? payment,
  }) => _call(() async {
    final v = await _db.rpc('hire_quote', params: {
      'p_pickup_lat': pickup.lat,
      'p_pickup_lng': pickup.lng,
      'p_drop_lat': drop?.lat,
      'p_drop_lng': drop?.lng,
      'p_service': service,
      'p_hours': hours,
      'p_at': at?.toUtc().toIso8601String(),
      'p_country': place.country,
      'p_state': place.state,
      'p_city': place.city,
      'p_suburb': place.suburb,
      'p_payment': payment,
    });
    return HireQuote.fromJson(v is Map ? Map<String, dynamic>.from(v) : const {});
  });

  /// The rider or the driver asks for [minutes] more.
  Future<HireExtension> extend(String rideId, int minutes) => _call(() async {
    final v = await _db.rpc('hire_extend_ask', params: {'p_ride': rideId, 'p_minutes': minutes});
    return HireExtension.fromJson(Map<String, dynamic>.from(v as Map));
  });

  /// The rider (or the Family host) answers the driver's ask.
  Future<void> answer(String rideId, String extensionId, {required bool approve}) => _call(() async {
    await _db.rpc('hire_extend_answer', params: {'p_ride': rideId, 'p_id': extensionId, 'p_approve': approve});
  });

  /// Ends the hire: the driver with the km driven, or the rider.
  Future<void> end(String rideId, {double? kmUsed}) => _call(() async {
    await _db.rpc('hire_end', params: {'p_ride': rideId, 'p_km_used': kmUsed});
  });

  /// The driver's "Take hourly hire".
  Future<bool> takesHire() async {
    try {
      return await _db.rpc('my_takes_hire') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setTakesHire(bool on) => _call(() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db.from(driverRideExtrasTable).upsert({'driver_id': uid, 'takes_hire': on}, onConflict: 'driver_id');
  });
}

final hourlyHireRepositoryProvider = Provider((ref) => HourlyHireRepository(ref.watch(supabaseProvider)));

/// The settings, kept live; off when they can't be read.
final hourlyHireConfigProvider = FutureProvider<HourlyHireConfig>((ref) async {
  ref.watchLive('app_settings');
  try {
    return await ref.watch(hourlyHireRepositoryProvider).config();
  } catch (_) {
    return HourlyHireConfig.off;
  }
});

/// The signed-in driver's "Take hourly hire".
final myTakesHireProvider = FutureProvider.autoDispose<bool>((ref) {
  ref.watchLive(driverRideExtrasTable);
  return ref.watch(hourlyHireRepositoryProvider).takesHire();
});
