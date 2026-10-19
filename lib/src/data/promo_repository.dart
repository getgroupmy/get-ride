// Rider promo codes (lib/src/core/promo_codes.dart; migration 0242). Every
// answer comes from the server's functions; a database without them answers
// "no promo" (an empty list, false, or a refusal) instead of throwing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/promo_codes.dart';
import '../providers.dart' show supabaseProvider;

/// A database without migration 0242.
bool isMissingPromo(PostgrestException e) =>
    e.code == 'PGRST202' || e.code == '42883' || e.message.contains('promo_');

class PromoRepository {
  PromoRepository(this._db);
  final SupabaseClient? _db;

  Map<String, dynamic> _trip(double pickupLat, double pickupLng, double? dropLat, double? dropLng, String? service,
          double? fare) =>
      {
        'p_pickup_lat': pickupLat,
        'p_pickup_lng': pickupLng,
        'p_drop_lat': dropLat,
        'p_drop_lng': dropLng,
        'p_service': service,
        'p_fare': fare == null ? null : double.parse(fare.toStringAsFixed(2)),
      };

  /// The codes that apply to the rider's trip now, the auto-applied one
  /// first. Empty when none does.
  Future<List<PromoOffer>> offers({
    required double pickupLat,
    required double pickupLng,
    double? dropLat,
    double? dropLng,
    String? service,
    double? fare,
  }) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = await db.rpc('promo_offers', params: _trip(pickupLat, pickupLng, dropLat, dropLng, service, fare));
      return [
        for (final r in (rows is List ? rows : const []))
          if (r is Map) PromoOffer.fromRow(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      if (isMissingPromo(e)) return const [];
      rethrow;
    }
  }

  /// A code the rider typed, checked against the trip.
  Future<PromoCheckResult> check(
    String code, {
    required double pickupLat,
    required double pickupLng,
    double? dropLat,
    double? dropLng,
    String? service,
    double? fare,
  }) async {
    final c = normalizePromoCode(code);
    if (!isPromoCodeShape(c)) return const PromoCheckResult.refused('not_found', "This code isn't valid.");
    final db = _db;
    if (db == null) return const PromoCheckResult.refused('not_found', "This code isn't valid.");
    try {
      final v = await db.rpc('promo_check', params: {
        'p_code': c,
        ..._trip(pickupLat, pickupLng, dropLat, dropLng, service, fare),
      });
      return v is Map ? PromoCheckResult.fromJson(Map<String, dynamic>.from(v)) : const PromoCheckResult.refused('not_found');
    } on PostgrestException catch (e) {
      if (isMissingPromo(e)) return const PromoCheckResult.refused('not_found', "This code isn't valid.");
      rethrow;
    }
  }

  /// Whether the rider stands in an auto-apply code's pickup area.
  Future<bool> zoneHere(double lat, double lng) async {
    final db = _db;
    if (db == null) return false;
    try {
      return await db.rpc('promo_zone_here', params: {'p_lat': lat, 'p_lng': lng}) == true;
    } on PostgrestException catch (e) {
      if (isMissingPromo(e)) return false;
      rethrow;
    }
  }
}

final promoRepositoryProvider = Provider<PromoRepository>((ref) => PromoRepository(ref.watch(supabaseProvider)));
