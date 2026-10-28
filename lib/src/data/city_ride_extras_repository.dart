// City ride extras (migration 0314): the settings by place, the tip terms
// of a ride, tipping, and the driver's cash tip mark. Every read is quiet
// on a database without 0314: the app then shows no tip card, no luggage
// charge and no waiting clock, as before.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/city_ride_extras.dart';
import '../providers.dart';
import 'live_tables.dart';

class CityRideExtrasRepository {
  CityRideExtrasRepository(this._db);
  final SupabaseClient _db;

  /// Every place's rules, Default first.
  Future<List<ExtrasPlace>> places() async {
    final rows = await _db.from('city_ride_extra_places').select().order('place_key', ascending: true);
    return [for (final r in rows) ExtrasPlace.fromRow(r)];
  }

  /// Admin: a new place, or one place's rules.
  Future<void> savePlace(ExtrasPlace p) async {
    if (p.id == null) {
      await _db.from('city_ride_extra_places').insert(p.toRow());
    } else {
      await _db.from('city_ride_extra_places').update({'rules': p.rules}).eq('id', p.id!);
    }
  }

  Future<void> deletePlace(String id) => _db.from('city_ride_extra_places').delete().eq('id', id);

  Future<TipTerms> tipTerms(String rideId) async =>
      TipTerms.fromJson(await _db.rpc('ride_tip_terms', params: {'p_ride': rideId}));

  /// The rider's tip; the server answers "already" for a ride tipped
  /// before, so a retry never pays twice.
  Future<void> tip(String rideId, double amount, TipMethod method) =>
      _db.rpc('ride_tip', params: {'p_ride': rideId, 'p_amount': amount, 'p_method': method.db});

  /// The driver's "Got a cash tip" mark.
  Future<void> cashTip(String rideId, {required bool on, double? amount}) =>
      _db.rpc('ride_cash_tip', params: {'p_ride': rideId, 'p_on': on, 'p_amount': amount});
}

final cityRideExtrasRepositoryProvider = Provider((ref) => CityRideExtrasRepository(ref.watch(supabaseProvider)));

/// Every place's rules, live; empty when unreadable (the built-in values
/// then hold).
final cityRideExtraPlacesProvider = FutureProvider<List<ExtrasPlace>>((ref) async {
  try {
    ref.watchLive('city_ride_extra_places');
    return await ref.watch(cityRideExtrasRepositoryProvider).places();
  } catch (_) {
    return const [];
  }
});

/// The admin page's list: errors shown, not swallowed.
final adminCityRideExtraPlacesProvider = FutureProvider.autoDispose<List<ExtrasPlace>>((ref) async {
  ref.watchLive('city_ride_extra_places');
  return ref.watch(cityRideExtrasRepositoryProvider).places();
});

/// A ride's tip terms; null when unreadable (no tip card then).
final tipTermsProvider = FutureProvider.autoDispose.family<TipTerms?, String>((ref, rideId) async {
  try {
    ref.watchLive('ride_tips');
    return await ref.watch(cityRideExtrasRepositoryProvider).tipTerms(rideId);
  } catch (_) {
    return null;
  }
});
