// Post-trip star ratings (lib/src/core/ride_rating.dart; migration 0159).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ride_rating.dart';
import '../providers.dart' show supabaseProvider;

class RideRatingRepository {
  RideRatingRepository(this._db);
  final SupabaseClient _db;

  /// Rates (or re-rates) the ride's driver through `rate_ride`; the server
  /// checks the caller is the ride's passenger and reads the driver off the
  /// ride. [RatingUnavailable] on a database without the function; a refusal
  /// is thrown.
  Future<RateRideResult> rate(String requestId, int stars, {String? comment}) async {
    final clean = cleanRatingComment(comment);
    try {
      final res = await _db.rpc('rate_ride', params: {'p_request_id': requestId, 'p_stars': stars, 'p_comment': clean});
      final m = res is Map ? res : const {};
      return RatingSaved(
        RideRating(stars: stars, comment: clean, updatedAt: DateTime.now()),
        partnerRating: (m['partner_rating'] as num?)?.toDouble(),
      );
    } on PostgrestException catch (e) {
      if (isMissingRatingFunction(e)) return const RatingUnavailable();
      rethrow;
    }
  }

  /// This passenger's rating of the ride; null when there is none, or on a
  /// database without the table.
  Future<RideRating?> mine(String requestId, String riderId) async {
    try {
      final row = await _db
          .from('ride_ratings')
          .select('stars, comment, updated_at')
          .eq('request_id', requestId)
          .eq('rater_id', riderId)
          .maybeSingle();
      return row == null ? null : RideRating.fromRow(row);
    } on PostgrestException catch (e) {
      if (e.code == '42P01' || e.code == 'PGRST205') return null;
      rethrow;
    }
  }
}

/// "No such function" from PostgREST (schema cache) or Postgres.
bool isMissingRatingFunction(PostgrestException e) =>
    e.code == 'PGRST202' || e.code == '42883' || e.message.contains('Could not find the function');

final rideRatingRepositoryProvider = Provider((ref) => RideRatingRepository(ref.watch(supabaseProvider)));

/// The passenger's rating of a ride (row-level security shows it to that
/// passenger and the driver); null when there is none.
final myRideRatingProvider = FutureProvider.autoDispose.family<RideRating?, ({String requestId, String riderId})>(
  (ref, key) => ref.watch(rideRatingRepositoryProvider).mine(key.requestId, key.riderId),
);
