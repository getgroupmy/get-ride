// City ride (migration 0269): many offers at once, drivers rating riders,
// cancel and no-show rules, the driver's cancel rate, the route check and
// the trip-share choice. Every read is quiet on a database without 0269:
// the app then behaves as before (one bid on the row, no fees shown).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/city_cancel.dart';
import '../core/ride_offers.dart';
import '../core/rider_rating.dart';
import '../core/trip_safety.dart';
import '../providers.dart';
import 'live_tables.dart';

/// The admin's city ride settings (city_ride_config).
class CityRideConfig {
  const CityRideConfig({
    this.offers = OfferSettings.standard,
    this.riderRating = RiderRatingSettings.standard,
    this.driverCancel = DriverCancelLimit.standard,
  });

  static const standard = CityRideConfig();

  final OfferSettings offers;
  final RiderRatingSettings riderRating;
  final DriverCancelLimit driverCancel;

  factory CityRideConfig.fromJson(Object? json) => json is Map
      ? CityRideConfig(
          offers: OfferSettings.fromJson(json['offers']),
          riderRating: RiderRatingSettings.fromJson(json['riderRating']),
          driverCancel: DriverCancelLimit.fromJson(json['driverCancel']),
        )
      : standard;
}

class CityRideRepository {
  CityRideRepository(this._db);
  final SupabaseClient _db;

  Future<CityRideConfig> config() async => CityRideConfig.fromJson(await _db.rpc('city_ride_config'));

  /// Admin: one section ('offers', 'riderRating', 'driverCancel').
  Future<CityRideConfig> saveConfig(String section, Map<String, dynamic> values) async => CityRideConfig.fromJson(
    await _db.rpc('set_city_ride_config', params: {'p_section': section, 'p_config': values}),
  );

  // ---- Offers --------------------------------------------------------------------------------------

  /// The offers on [requestId], live (the rider reads them all, a driver
  /// their own).
  Stream<List<RideOfferRow>> offers(String requestId) => _db
      .from('ride_offers')
      .stream(primaryKey: ['id'])
      .eq('request_id', requestId)
      .map((rows) => [for (final r in rows) ?RideOfferRow.tryParse(r)]);

  /// This driver's offers, live, newest first: one that closes as "taken"
  /// tells them another driver got the ride.
  Stream<List<RideOfferRow>> myOffers(String partnerId) => _db
      .from('ride_offers')
      .stream(primaryKey: ['id'])
      .eq('partner_id', partnerId)
      .order('created_at', ascending: false)
      .limit(20)
      .map((rows) => [for (final r in rows) ?RideOfferRow.tryParse(r)]);

  Future<void> acceptOffer(String offerId) => _db.rpc('ride_offer_accept', params: {'p_offer': offerId});

  Future<void> declineOffer(String offerId) => _db.rpc('ride_offer_decline', params: {'p_offer': offerId});

  // ---- Rider ratings -------------------------------------------------------------------------------

  Future<void> rateRider(String requestId, int stars, Set<String> tags) =>
      _db.rpc('rate_rider', params: {'p_request_id': requestId, 'p_stars': stars, 'p_tags': tags.toList()});

  /// The requests this driver already rated, of [requestIds].
  Future<Set<String>> ratedRides(List<String> requestIds) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null || requestIds.isEmpty) return {};
    final rows = await _db.from('rider_ratings').select('request_id').eq('rater_id', uid).inFilter('request_id', requestIds);
    return {for (final r in rows) '${r['request_id']}'};
  }

  /// The signed-in rider's own rating.
  Future<({double? rating, int ratings})> myRiderRating() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return (rating: null, ratings: 0);
    final row = await _db.from('profiles').select('rider_rating, rider_ratings_count').eq('id', uid).maybeSingle();
    return (
      rating: (row?['rider_rating'] as num?)?.toDouble(),
      ratings: (row?['rider_ratings_count'] as num?)?.toInt() ?? 0,
    );
  }

  // ---- Cancel and no-show ------------------------------------------------------------------------

  Future<CancelTerms> cancelTerms(String rideId) async =>
      CancelTerms.fromJson(await _db.rpc('ride_cancel_terms', params: {'p_ride': rideId}));

  Future<void> noShow(String rideId) => _db.rpc('ride_no_show', params: {'p_ride': rideId});

  Future<DriverCancelStats> driverCancelStats() async =>
      DriverCancelStats.fromJson(await _db.rpc('driver_cancel_stats'));

  /// Admin: every place's rules, Default first.
  Future<List<CancelPlace>> cancelPlaces() async {
    final rows = await _db.from('ride_cancel_places').select().order('place_key', ascending: true);
    return [for (final r in rows) CancelPlace.fromRow(r)];
  }

  Future<void> saveCancelPlace(CancelPlace p) async {
    if (p.id == null) {
      await _db.from('ride_cancel_places').insert(p.toRow());
    } else {
      await _db.from('ride_cancel_places').update({'rules': p.rules}).eq('id', p.id!);
    }
  }

  Future<void> deleteCancelPlace(String id) => _db.from('ride_cancel_places').delete().eq('id', id);

  // ---- Safety --------------------------------------------------------------------------------------

  /// The route check's question and its answer ('asked', 'ok', 'sos', 'no_answer').
  Future<void> routeReport(String rideId, RouteAlertKind kind, String answer, {int? offM, double? lat, double? lng}) =>
      _db.rpc('trip_route_report', params: {
        'p_ride': rideId,
        'p_kind': kind.db,
        'p_answer': answer,
        'p_off_m': offM,
        'p_lat': lat,
        'p_lng': lng,
      });

  Future<TripShareMode> tripShareMode() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return TripShareMode.night;
    final row = await _db.from('profiles').select('trip_share_mode').eq('id', uid).maybeSingle();
    return TripShareMode.parse(row?['trip_share_mode']);
  }

  Future<void> setTripShareMode(TripShareMode m) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db.from('profiles').update({'trip_share_mode': m.name}).eq('id', uid);
  }
}

final cityRideRepositoryProvider = Provider((ref) => CityRideRepository(ref.watch(supabaseProvider)));

/// The admin's settings; the defaults when they can't be read (no signal,
/// a database without 0269, a test without a server).
final cityRideConfigProvider = FutureProvider<CityRideConfig>((ref) async {
  try {
    ref.watchLive('app_settings');
    return await ref.watch(cityRideRepositoryProvider).config();
  } catch (_) {
    return CityRideConfig.standard;
  }
});

/// A request's offers, live; empty when they can't be read (the single bid
/// on the row is then the one shown).
final rideOffersProvider = StreamProvider.autoDispose.family<List<RideOfferRow>, String>((ref, requestId) {
  try {
    return ref.watch(cityRideRepositoryProvider).offers(requestId).handleError((_) {});
  } catch (_) {
    return Stream.value(const <RideOfferRow>[]);
  }
});

/// The signed-in driver's latest offers, live; empty when unreadable.
final myRideOffersProvider = StreamProvider.autoDispose<List<RideOfferRow>>((ref) {
  try {
    final uid = ref.watch(currentUserIdProvider);
    if (uid == null) return Stream.value(const <RideOfferRow>[]);
    return ref.watch(cityRideRepositoryProvider).myOffers(uid).handleError((_) {});
  } catch (_) {
    return Stream.value(const <RideOfferRow>[]);
  }
});

/// A ride's cancel terms; null when unreadable (a database without 0269
/// charges no fee, so none is shown).
final cancelTermsProvider = FutureProvider.autoDispose.family<CancelTerms?, String>((ref, rideId) async {
  try {
    ref.watchLive('ride_cancel_places');
    return await ref.watch(cityRideRepositoryProvider).cancelTerms(rideId);
  } catch (_) {
    return null;
  }
});

/// The driver's own cancel rate; null when unreadable.
final driverCancelStatsProvider = FutureProvider.autoDispose<DriverCancelStats?>((ref) async {
  try {
    return await ref.watch(cityRideRepositoryProvider).driverCancelStats();
  } catch (_) {
    return null;
  }
});

/// The rider's own rating, for Profile; null when unreadable.
final myRiderRatingProvider = FutureProvider.autoDispose<({double? rating, int ratings})?>((ref) async {
  try {
    ref.watchLive('profiles');
    return await ref.watch(cityRideRepositoryProvider).myRiderRating();
  } catch (_) {
    return null;
  }
});

/// The rider's trip-share choice; "at night" when unreadable.
final tripShareModeProvider = FutureProvider.autoDispose<TripShareMode>((ref) async {
  try {
    return await ref.watch(cityRideRepositoryProvider).tripShareMode();
  } catch (_) {
    return TripShareMode.night;
  }
});
