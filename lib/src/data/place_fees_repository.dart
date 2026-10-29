// Place fees (migration 0324): the admin's list of each place's fees
// (public.place_fees, admins only), the place fee settings
// (place_fees_config / set_place_fees_config) and the server's quote of a
// trip's fees before booking (place_fees_quote).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/place_fees.dart';
import '../providers.dart';
import 'live_tables.dart';

class PlaceFeesRepository {
  PlaceFeesRepository(this._db);
  final SupabaseClient _db;

  /// Every place's fees (admins only; empty for anyone else).
  Future<List<PlaceFee>> fees() async {
    final rows = await _db
        .from('place_fees')
        .select()
        .order('sort_order', ascending: true)
        .order('created_at', ascending: true);
    return [for (final r in rows) PlaceFee.fromRow(r)];
  }

  Future<void> save(PlaceFee f) => _db.from('place_fees').upsert(f.toRow(), onConflict: 'id');

  Future<void> delete(String id) => _db.from('place_fees').delete().eq('id', id);

  Future<void> setEnabled(String id, bool on) => _db.from('place_fees').update({'enabled': on}).eq('id', id);

  /// New sort orders by fee id ([reorderPlaceFees]).
  Future<void> reorder(Map<String, int> orders) async {
    for (final e in orders.entries) {
      await _db.from('place_fees').update({'sort_order': e.value}).eq('id', e.key);
    }
  }

  Future<PlaceFeeSettings> settings() async => PlaceFeeSettings.fromJson(await _db.rpc('place_fees_config'));

  Future<PlaceFeeSettings> saveSettings(PlaceFeeSettings s) async =>
      PlaceFeeSettings.fromJson(await _db.rpc('set_place_fees_config', params: {'p_config': s.toJson()}));

  /// The place fees a trip would be booked with: [fare] is the route fare
  /// (the fare less the option charges), [at] the pickup time for a ride
  /// booked for later (null: now). [stops] as the ride stores them.
  Future<PlaceFeesQuote> quote({
    required LatLng pickup,
    required LatLng drop,
    List<LatLng> stops = const [],
    required String service,
    required double fare,
    DateTime? at,
  }) async {
    final res = await _db.rpc(
      'place_fees_quote',
      params: {
        'p_pickup_lat': pickup.latitude,
        'p_pickup_lng': pickup.longitude,
        'p_drop_lat': drop.latitude,
        'p_drop_lng': drop.longitude,
        'p_stops': [
          for (final s in stops) {'lat': s.latitude, 'lng': s.longitude},
        ],
        'p_service': service,
        'p_fare': double.parse(fare.toStringAsFixed(2)),
        'p_at': at?.toUtc().toIso8601String(),
      },
    );
    return PlaceFeesQuote.fromJson(res);
  }
}

final placeFeesRepositoryProvider = Provider((ref) => PlaceFeesRepository(ref.watch(supabaseProvider)));

/// Every place's fees, for the admin; followed live. Empty when unreadable.
final placeFeesProvider = FutureProvider<List<PlaceFee>>((ref) async {
  ref.watchLive('place_fees');
  try {
    return await ref.watch(placeFeesRepositoryProvider).fees();
  } catch (_) {
    return const [];
  }
});

/// The place fee settings; the defaults when unreadable.
final placeFeeSettingsProvider = FutureProvider<PlaceFeeSettings>((ref) async {
  ref.watchLive('app_settings');
  try {
    return await ref.watch(placeFeesRepositoryProvider).settings();
  } catch (_) {
    return PlaceFeeSettings.defaults;
  }
});

/// What asks for a quote: the trip, the service, its route fare and when.
typedef PlaceFeesQuoteArgs = ({
  double pickupLat,
  double pickupLng,
  double dropLat,
  double dropLng,
  String stops,
  String service,
  double fare,
  DateTime? at,
});

PlaceFeesQuoteArgs placeFeesQuoteArgs({
  required LatLng pickup,
  required LatLng drop,
  List<LatLng> stops = const [],
  required String service,
  required double fare,
  DateTime? at,
}) => (
  pickupLat: pickup.latitude,
  pickupLng: pickup.longitude,
  dropLat: drop.latitude,
  dropLng: drop.longitude,
  stops: [for (final s in stops) '${s.latitude},${s.longitude}'].join(';'),
  service: service,
  fare: (fare * 100).roundToDouble() / 100,
  at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch ~/ 60000 * 60000),
);

/// The server's place fees for a trip (Freight, Courier); none when it
/// can't be reached.
final placeFeesQuoteProvider = FutureProvider.autoDispose.family<PlaceFeesQuote, PlaceFeesQuoteArgs>((ref, a) async {
  try {
    return await ref
        .watch(placeFeesRepositoryProvider)
        .quote(
          pickup: LatLng(a.pickupLat, a.pickupLng),
          drop: LatLng(a.dropLat, a.dropLng),
          stops: [
            for (final s in a.stops.split(';'))
              if (s.contains(','))
                LatLng(double.parse(s.split(',').first), double.parse(s.split(',').last)),
          ],
          service: a.service,
          fare: a.fare,
          at: a.at,
        );
  } catch (_) {
    return PlaceFeesQuote.none;
  }
});
