// Hourly hire (migration 0326): the settings, the server's quote, a hire's
// extensions and its end, and a driver's "Take hourly hire" switch. Booking
// a hire is RideRepository.createRequest with its hours (a ride_requests row
// with hire columns), so it is the Ride module's repository too.
//
// Hire for several days (0327): a package's settings and quote, booking
// (hire_book, with the row RideRepository.createRequest builds), a driver
// taking a whole booking, the rider's bookings and cancelling one.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/hourly_hire.dart';
import '../core/multi_day_hire.dart';
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

extension MultiHireCalls on HourlyHireRepository {
  SupabaseClient get _client => _db;

  /// A package's settings ('daily'); off when it can't be read.
  Future<MultiHireConfig> packageConfig(String package) async {
    final v = await _client.rpc('hire_package_config', params: {'p_package': package});
    return MultiHireConfig.fromJson(package, v is Map ? Map<String, dynamic>.from(v) : null);
  }

  /// Admin › Settings › Daily hire: saved as the server keeps it.
  Future<MultiHireConfig> savePackage(MultiHireConfig c) => _call(() async {
    final v = await _client.rpc('set_hire_package_config', params: {'p_package': c.package, 'p_config': c.toJson()});
    return v is Map ? MultiHireConfig.fromJson(c.package, Map<String, dynamic>.from(v)) : c;
  });

  /// The server's price for [days] days of [hours] a day from [firstAt].
  Future<MultiHireQuote> multiQuote({
    required String package,
    required ({double lat, double lng}) pickup,
    ({double lat, double lng})? drop,
    required String service,
    required int days,
    double? hours,
    required DateTime firstAt,
    HirePlace place = (country: null, state: null, city: null, suburb: null),
    String? payment,
    bool overnight = false,
    String? timezone,
    Map<String, dynamic> options = const {},
  }) => _call(() async {
    final v = await _client.rpc('hire_multi_quote', params: {
      'p_package': package,
      'p_pickup_lat': pickup.lat,
      'p_pickup_lng': pickup.lng,
      'p_drop_lat': drop?.lat,
      'p_drop_lng': drop?.lng,
      'p_service': service,
      'p_days': days,
      'p_hours': hours,
      'p_first_at': firstAt.toUtc().toIso8601String(),
      'p_country': place.country,
      'p_state': place.state,
      'p_city': place.city,
      'p_suburb': place.suburb,
      'p_payment': payment,
      'p_overnight': overnight,
      'p_timezone': timezone,
      'p_options': options,
    });
    return MultiHireQuote.fromJson(v is Map ? Map<String, dynamic>.from(v) : const {});
  });

  /// Books [booking] ({package, first_at, days, hours, overnight,
  /// same_driver, payment_plan}) with the ride [row] the app would send for
  /// day 1: the booking and its days, the deposit taken.
  Future<HireDaysBooking> book(Map<String, dynamic> row, Map<String, dynamic> booking) => _call(() async {
    final v = await _client.rpc('hire_book', params: {'p_request': row, 'p_booking': booking});
    return HireDaysBooking.fromRow(Map<String, dynamic>.from(v as Map));
  });

  /// The signed-in rider's bookings, newest first.
  Future<List<HireDaysBooking>> myBookings() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _client
        .from(hireBookingsTable)
        .select()
        .eq('rider_id', uid)
        .order('first_at', ascending: false)
        .limit(50);
    return [for (final r in rows) HireDaysBooking.fromRow(r)];
  }

  /// One booking (the rider's, its driver's, or an admin's view).
  Future<HireDaysBooking?> booking(String id) async {
    final r = await _client.from(hireBookingsTable).select().eq('id', id).maybeSingle();
    return r == null ? null : HireDaysBooking.fromRow(r);
  }

  /// What cancelling now costs.
  Future<({bool free, double fee, double refund, DateTime? freeUntil, bool started})> cancelQuote(String id) =>
      _call(() async {
        final v = Map<String, dynamic>.from(
          await _client.rpc('hire_booking_cancel_quote', params: {'p_booking': id}) as Map,
        );
        double n(Object? x) => x is num ? x.toDouble() : double.tryParse('$x') ?? 0;
        return (
          free: v['free'] == true,
          fee: n(v['fee']),
          refund: n(v['refund']),
          freeUntil: DateTime.tryParse('${v['freeUntil']}')?.toLocal(),
          started: v['started'] == true,
        );
      });

  Future<void> cancelBooking(String id, {String? reason}) => _call(() async {
    await _client.rpc('hire_booking_cancel', params: {'p_booking': id, 'p_reason': reason});
  });

  /// A booking's days (its rider's, its drivers' or an admin's view): the
  /// day, the pickup, the status, the driver and the ride once released.
  Future<List<({String id, int day, DateTime at, String status, String? partnerId, String? rideId})>> bookingDays(
    String id,
  ) async {
    final rows = await _client
        .from('scheduled_rides')
        .select('id, hire_day_no, pickup_at, status, partner_id, ride_id')
        .eq('hire_booking_id', id)
        .order('hire_day_no', ascending: true);
    return [
      for (final r in rows)
        (
          id: '${r['id']}',
          day: (r['hire_day_no'] as num?)?.toInt() ?? 0,
          at: DateTime.tryParse('${r['pickup_at']}')?.toLocal() ?? DateTime.now(),
          status: '${r['status']}',
          partnerId: r['partner_id'] as String?,
          rideId: r['ride_id'] as String?,
        ),
    ];
  }

  /// Admin (0328): approved drivers who take hire, free on every day of
  /// [bookingId] still to come (or on its day [day]) first.
  Future<List<({String id, String name, String? phone, bool free})>> adminDrivers(String bookingId, {int? day}) =>
      _call(() async {
        final rows = await _client.rpc('hire_booking_admin_drivers', params: {'p_booking': bookingId, 'p_day': day});
        return [
          if (rows is List)
            for (final r in rows)
              if (r is Map) (id: '${r['id']}', name: '${r['name'] ?? 'Driver'}', phone: r['phone'] as String?,
                  free: r['free'] == true),
        ];
      });

  /// Admin (0328): [driverId] takes every day still to come, or day [day].
  Future<void> adminAssign(String bookingId, String driverId, {int? day}) => _call(() async {
    await _client.rpc('hire_booking_admin_assign', params: {'p_booking': bookingId, 'p_driver': driverId, 'p_day': day});
  });

  /// Admin › Hire bookings (0328): newest first, a page of [limit], with
  /// how many match.
  Future<({List<AdminHireBooking> rows, int total})> adminBookings({
    String? status,
    String? package,
    String? query,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  }) => _call(() async {
    String? d(DateTime? x) => x == null
        ? null
        : '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final rows = await _client.rpc('hire_bookings_admin', params: {
      'p_status': status,
      'p_package': package,
      'p_query': (query ?? '').trim().isEmpty ? null : query!.trim(),
      'p_from': d(from),
      'p_to': d(to),
      'p_limit': limit,
      'p_offset': 0,
    });
    final list = [
      if (rows is List)
        for (final r in rows)
          if (r is Map) AdminHireBooking.fromRow(Map<String, dynamic>.from(r)),
    ];
    return (rows: list, total: list.isEmpty ? 0 : list.first.total);
  });

  /// Public holidays (0328), soonest first.
  Future<List<({String id, DateTime day, String name, String country})>> holidays() async {
    final rows = await _client.from(publicHolidaysTable).select().order('day', ascending: true).limit(500);
    return [
      for (final r in rows)
        (
          id: '${r['id']}',
          day: DateTime.tryParse('${r['day']}') ?? DateTime(2000),
          name: '${r['name'] ?? ''}',
          country: '${r['country'] ?? ''}',
        ),
    ];
  }

  Future<void> addHoliday(DateTime day, String name, {String country = ''}) => _call(() async {
    final d = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    await _client.from(publicHolidaysTable).insert({'day': d, 'name': name.trim(), 'country': country.trim()});
  });

  Future<void> removeHoliday(String id) => _call(() async {
    await _client.from(publicHolidaysTable).delete().eq('id', id);
  });

  /// Bookings a driver can take for all their days.
  Future<List<OpenHireBooking>> openBookings() async {
    final rows = await _client.rpc('hire_bookings_open');
    return [
      if (rows is List)
        for (final r in rows)
          if (r is Map) OpenHireBooking.fromRow(Map<String, dynamic>.from(r)),
    ];
  }

  /// The driver takes every day of a booking.
  Future<void> acceptBooking(String id) => _call(() async {
    await _client.rpc('hire_booking_accept', params: {'p_booking': id});
  });
}

const hireBookingsTable = 'hire_bookings';
const publicHolidaysTable = 'public_holidays';

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

/// A package's settings ('daily'), kept live; off when they can't be read.
final multiHireConfigProvider = FutureProvider.family<MultiHireConfig, String>((ref, package) async {
  ref.watchLive('app_settings');
  try {
    return await ref.watch(hourlyHireRepositoryProvider).packageConfig(package);
  } catch (_) {
    return MultiHireConfig(package: package);
  }
});

/// The signed-in rider's bookings for several days, kept live.
final myHireBookingsProvider = FutureProvider.autoDispose<List<HireDaysBooking>>((ref) async {
  ref.watchLive(hireBookingsTable);
  try {
    return await ref.watch(hourlyHireRepositoryProvider).myBookings();
  } catch (_) {
    return const [];
  }
});

/// Bookings waiting for one driver for all their days (drivers' Upcoming).
final openHireBookingsProvider = FutureProvider.autoDispose<List<OpenHireBooking>>((ref) async {
  ref.watchLive(hireBookingsTable);
  try {
    return await ref.watch(hourlyHireRepositoryProvider).openBookings();
  } catch (_) {
    return const [];
  }
});

/// Public holidays (0328), kept live.
final publicHolidaysProvider =
    FutureProvider.autoDispose<List<({String id, DateTime day, String name, String country})>>((ref) {
  ref.watchLive(publicHolidaysTable);
  return ref.watch(hourlyHireRepositoryProvider).holidays();
});
