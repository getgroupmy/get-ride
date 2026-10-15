// Handing a trip over mid-way (migration 0199). Every step goes through the
// server's functions; the handover rows are read by the drivers and the
// passenger in each, and a partner asked sees only the offer.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/scheduled_rides.dart' show scheduleErrorMessage;
import '../core/trip_handover.dart';
import '../providers.dart';
import 'live_tables.dart';

/// A refusal from the server, as one sentence.
class HandoverError implements Exception {
  const HandoverError(this.message);
  final String message;

  static Object wrap(Object e) {
    if (e is! PostgrestException) return e;
    if (e.code == '42501') return const HandoverError("You can't do that for this trip.");
    // The code checks share their wording with scheduled rides (0198).
    return HandoverError(scheduleErrorMessage(e.message, hint: e.hint));
  }

  @override
  String toString() => message;
}

class TripHandoverRepository {
  TripHandoverRepository(this._db);
  final SupabaseClient _db;

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw HandoverError.wrap(e);
    }
  }

  Future<TripHandoverConfig> config() async => TripHandoverConfig.fromJson(await _db.rpc('trip_handover_config'));

  /// Admin: saves, and returns the settings as stored (cleaned).
  Future<TripHandoverConfig> saveConfig(TripHandoverConfig c) async =>
      TripHandoverConfig.fromJson(await _db.rpc('set_trip_handover_config', params: {'p_config': c.toJson()}));

  /// The driver asks to hand [rideId] over: to the partner with [code], or
  /// (null) to the first partner nearby to accept. The passenger approves
  /// first.
  Future<void> request(String rideId, {String? code, String? note}) =>
      _call(() => _db.rpc('trip_handover_request', params: {'p_ride': rideId, 'p_code': code, 'p_note': note}));

  /// The passenger's answer.
  Future<void> riderAnswer(String handoverId, {required bool approve}) =>
      _call(() => _db.rpc('trip_handover_rider_answer', params: {'p_handover': handoverId, 'p_approve': approve}));

  /// Trips the signed-in partner is asked to take over.
  Future<List<HandoverOffer>> offersForMe() async => [
    for (final r in await _db.rpc('trip_handover_offers_for_me') as List)
      HandoverOffer.fromRow(Map<String, dynamic>.from(r as Map)),
  ];

  Future<void> accept(String handoverId) =>
      _call(() => _db.rpc('trip_handover_accept', params: {'p_handover': handoverId}));

  Future<void> decline(String handoverId) =>
      _call(() => _db.rpc('trip_handover_decline', params: {'p_handover': handoverId}));

  /// The new driver has the passenger in their car.
  Future<void> boarded(String handoverId) =>
      _call(() => _db.rpc('trip_handover_boarded', params: {'p_handover': handoverId}));

  /// The driver who asked withdraws it while it is still open.
  Future<void> cancel(String handoverId) =>
      _call(() => _db.rpc('trip_handover_cancel', params: {'p_handover': handoverId}));

  /// Handovers the signed-in account is part of, newest first; [rideId]
  /// keeps to one trip.
  Future<List<TripHandover>> mine({String? rideId}) async => [
    for (final r in await _db.rpc('trip_handovers_mine', params: {'p_ride': rideId}) as List)
      TripHandover.fromRow(Map<String, dynamic>.from(r as Map)),
  ];
}

final tripHandoverRepositoryProvider = Provider((ref) => TripHandoverRepository(ref.watch(supabaseProvider)));

/// The admin's settings; off when they can't be read (an older database).
final tripHandoverConfigProvider = FutureProvider<TripHandoverConfig>((ref) async {
  ref.watchLive('app_settings');
  try {
    return await ref.watch(tripHandoverRepositoryProvider).config();
  } catch (_) {
    return TripHandoverConfig.off;
  }
});

/// The handovers of one trip the signed-in account is part of, kept live.
final rideHandoversProvider = FutureProvider.autoDispose.family<List<TripHandover>, String>((ref, rideId) async {
  ref.watchLive('trip_handovers');
  if (ref.watch(currentUserIdProvider) == null) return const [];
  try {
    return await ref.watch(tripHandoverRepositoryProvider).mine(rideId: rideId);
  } catch (_) {
    return const [];
  }
});

/// The handover that matters for [rideId] now: the open one, else the
/// latest. Null when none (or not yet read).
final rideHandoverProvider = Provider.autoDispose.family<TripHandover?, String>(
  (ref, rideId) => handoverForRide(ref.watch(rideHandoversProvider(rideId)).value ?? const [], rideId),
);

/// Partners: trips they are asked to take over, kept live.
final handoverOffersProvider = FutureProvider.autoDispose<List<HandoverOffer>>((ref) async {
  ref.watchLive('trip_handover_candidates');
  if (ref.watch(currentUserIdProvider) == null) return const [];
  try {
    return await ref.watch(tripHandoverRepositoryProvider).offersForMe();
  } catch (_) {
    return const [];
  }
});
