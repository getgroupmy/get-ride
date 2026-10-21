// Scheduled rides (migration 0189): booking, cancelling and the driver's
// advance list. Every change goes through the server's functions; the
// rows are read under row-level security (the rider's own, the driver's
// accepted ones, or every one for an admin).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/scheduled_rides.dart';
import '../providers.dart';
import 'live_tables.dart';

/// A refusal from the server, as one sentence for the rider or driver.
class ScheduleError implements Exception {
  const ScheduleError(this.message);
  final String message;

  static Object wrap(Object e) =>
      e is PostgrestException ? ScheduleError(scheduleErrorMessage(e.message, hint: e.hint)) : e;

  @override
  String toString() => message;
}

class ScheduledRideRepository {
  ScheduledRideRepository(this._db);
  final SupabaseClient _db;

  static const _table = 'scheduled_rides';

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw ScheduleError.wrap(e);
    }
  }

  Future<ScheduledRidesConfig> config() async => ScheduledRidesConfig.fromJson(await _db.rpc('scheduled_rides_config'));

  /// Admin: saves, and returns the settings as stored (cleaned).
  Future<ScheduledRidesConfig> saveConfig(ScheduledRidesConfig c) async =>
      ScheduledRidesConfig.fromJson(await _db.rpc('set_scheduled_rides_config', params: {'p_config': c.toJson()}));

  /// Books [request] (the ride row the app would insert now) for [pickupAt].
  Future<ScheduledRide> schedule(Map<String, dynamic> request, DateTime pickupAt) => _call(() async {
    final row = await _db.rpc(
      'schedule_ride',
      params: {'p_request': request, 'p_pickup_at': pickupAt.toUtc().toIso8601String()},
    );
    return ScheduledRide.fromRow(Map<String, dynamic>.from(row as Map));
  });

  /// The rider's bookings, soonest first, the upcoming ones before the rest.
  /// The latest 100 by pickup are read (newest first, so a long history
  /// never crowds out what is still to come) and turned round here.
  Future<List<ScheduledRide>> mine(String uid) async => [
    for (final r in (await _db
            .from(_table)
            .select()
            .eq('rider_id', uid)
            .order('pickup_at', ascending: false)
            .limit(100))
        .reversed)
      ScheduledRide.fromRow(r),
  ];

  Future<ScheduledRide> cancel(String id, {String? reason}) => _call(() async {
    final row = await _db.rpc('scheduled_ride_cancel', params: {'p_id': id, 'p_reason': reason});
    return ScheduledRide.fromRow(Map<String, dynamic>.from(row as Map));
  });

  /// Fees the rider still owes (late scheduled cancels, freight cancels and
  /// city fees a short wallet left due, my_owed_fees); they go on the next ride.
  Future<double> owedFees() async {
    final v = await _db.rpc('my_owed_fees');
    return v is num ? v.toDouble() : 0;
  }

  // ---- Drivers -------------------------------------------------------------------------------

  /// Bookings open to pre-accept (advance mode, approved drivers).
  Future<List<ScheduledRide>> open() async {
    final rows = await _db.rpc('scheduled_rides_open');
    return [
      for (final r in rows as List)
        ScheduledRide.fromRow({...Map<String, dynamic>.from(r as Map), 'status': 'scheduled'}),
    ];
  }

  /// The bookings this driver has accepted (still to come).
  Future<List<ScheduledRide>> accepted(String uid) async => [
    for (final r
        in await _db
            .from(_table)
            .select(
              'id, pickup_at, status, service, pickup_address, drop_address, fare, scheduling_fee, currency, '
              'partner_id, ride_id, distance_km',
            )
            .eq('partner_id', uid)
            .inFilter('status', ['assigned', 'released'])
            .order('pickup_at', ascending: true))
      ScheduledRide.fromRow(r),
  ];

  Future<void> accept(String id) => _call(() => _db.rpc('scheduled_ride_accept', params: {'p_id': id}));

  /// Lets go of a booking before it is released: it goes back to the pool.
  Future<void> release(String id) => _call(() => _db.rpc('scheduled_ride_driver_cancel', params: {'p_id': id}));

  /// Every booking no driver has taken yet, soonest first, with this
  /// driver's interest (migration 0198).
  Future<List<UpcomingBooking>> upcoming() async => [
    for (final r in await _db.rpc('scheduled_rides_upcoming') as List)
      UpcomingBooking.fromRow(Map<String, dynamic>.from(r as Map)),
  ];

  Future<void> setInterest(String id, bool on) =>
      _call(() => _db.rpc('scheduled_ride_set_interest', params: {'p_id': id, 'p_on': on}));

  /// Offers the driver's booking to the driver with [code] (My Ride code or
  /// GET.me QR); it stays theirs until that driver accepts.
  Future<void> handOver(String id, String code) =>
      _call(() => _db.rpc('scheduled_ride_transfer', params: {'p_id': id, 'p_code': code}));

  /// The passenger asks the driver with [code] to take a booking.
  Future<void> requestDriver(String id, String code) =>
      _call(() => _db.rpc('scheduled_ride_request_driver', params: {'p_id': id, 'p_code': code}));

  /// Requests waiting for an answer that the caller made or was sent.
  Future<List<ScheduledOffer>> offers() async => [
    for (final r in await _db.rpc('scheduled_ride_offers_open') as List)
      ScheduledOffer.fromRow(Map<String, dynamic>.from(r as Map)),
  ];

  Future<void> answerOffer(String offerId, {required bool accept}) =>
      _call(() => _db.rpc('scheduled_ride_offer_respond', params: {'p_offer': offerId, 'p_accept': accept}));

  Future<void> withdrawOffer(String offerId) =>
      _call(() => _db.rpc('scheduled_ride_offer_cancel', params: {'p_offer': offerId}));

  // ---- Admin ---------------------------------------------------------------------------------

  Future<List<ScheduledRide>> all({bool upcomingOnly = true}) async {
    var q = _db.from(_table).select();
    if (upcomingOnly) q = q.inFilter('status', ['scheduled', 'assigned', 'released']);
    return [for (final r in await q.order('pickup_at', ascending: upcomingOnly).limit(200)) ScheduledRide.fromRow(r)];
  }
}

final scheduledRideRepositoryProvider = Provider((ref) => ScheduledRideRepository(ref.watch(supabaseProvider)));

/// The admin's settings; off when they can't be read (an older database).
final scheduledRidesConfigProvider = FutureProvider<ScheduledRidesConfig>((ref) async {
  ref.watchLive('app_settings');
  try {
    return await ref.watch(scheduledRideRepositoryProvider).config();
  } catch (_) {
    return ScheduledRidesConfig.off;
  }
});

/// The signed-in rider's bookings, kept live.
final myScheduledRidesProvider = FutureProvider<List<ScheduledRide>>((ref) async {
  ref.watchLive('scheduled_rides');
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  try {
    return await ref.watch(scheduledRideRepositoryProvider).mine(uid);
  } catch (_) {
    return const [];
  }
});

/// The rider's bookings still to come, soonest first.
final upcomingScheduledRidesProvider = Provider<List<ScheduledRide>>(
  (ref) => [
    for (final r in ref.watch(myScheduledRidesProvider).value ?? const <ScheduledRide>[])
      if (r.upcoming) r,
  ],
);

/// Fees owed from earlier rides (0 when none, or unreadable).
final owedFeesProvider = FutureProvider<double>((ref) async {
  ref.watchLive('scheduled_rides');
  if (ref.watch(currentUserIdProvider) == null) return 0;
  try {
    return await ref.watch(scheduledRideRepositoryProvider).owedFees();
  } catch (_) {
    return 0;
  }
});

/// The driver's advance list (empty outside advance mode).
final openScheduledRidesProvider = FutureProvider.autoDispose<List<ScheduledRide>>((ref) async {
  ref.watchLive('scheduled_rides');
  final c = await ref.watch(scheduledRidesConfigProvider.future);
  if (!c.enabled || !c.advance) return const [];
  return ref.watch(scheduledRideRepositoryProvider).open();
});

/// The bookings the driver has accepted.
final acceptedScheduledRidesProvider = FutureProvider.autoDispose<List<ScheduledRide>>((ref) async {
  ref.watchLive('scheduled_rides');
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  return ref.watch(scheduledRideRepositoryProvider).accepted(uid);
});

/// Drivers: every booking still without a driver (Upcoming).
final upcomingBookingsProvider = FutureProvider.autoDispose<List<UpcomingBooking>>((ref) async {
  ref.watchLive('scheduled_rides');
  ref.watchLive('scheduled_ride_offers');
  final c = await ref.watch(scheduledRidesConfigProvider.future);
  if (!c.enabled) return const [];
  return ref.watch(scheduledRideRepositoryProvider).upcoming();
});

/// Requests waiting for an answer: handovers and passengers' choices sent
/// to this driver, and the ones the signed-in account made.
final scheduledOffersProvider = FutureProvider.autoDispose<List<ScheduledOffer>>((ref) async {
  ref.watchLive('scheduled_ride_offers');
  ref.watchLive('scheduled_rides');
  if (ref.watch(currentUserIdProvider) == null) return const [];
  try {
    return await ref.watch(scheduledRideRepositoryProvider).offers();
  } catch (_) {
    return const [];
  }
});
