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
  ///
  /// [tags]: the tags picked (0297); null leaves those already given. A
  /// database before 0297 has no tags: the stars and comment are saved
  /// without them.
  Future<RateRideResult> rate(String requestId, int stars, {String? comment, List<String>? tags}) async {
    final clean = cleanRatingComment(comment);
    try {
      Object? res;
      try {
        res = await _db.rpc('rate_ride', params: {
          'p_request_id': requestId,
          'p_stars': stars,
          'p_comment': clean,
          'p_tags': ?tags,
        });
      } on PostgrestException catch (e) {
        if (tags == null || !isMissingRatingFunction(e)) rethrow;
        res = await _db.rpc('rate_ride', params: {'p_request_id': requestId, 'p_stars': stars, 'p_comment': clean});
      }
      final m = res is Map ? res : const {};
      final saved = m['tags'];
      return RatingSaved(
        RideRating(
          stars: stars,
          comment: clean,
          updatedAt: DateTime.now(),
          tags: saved is List ? [for (final t in saved) if (t is String) t] : (tags ?? const []),
        ),
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
          .select('*')
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

/// The tags a rider picks (0297), as the admin keeps them; the built-in
/// list when they can't be read (a database before 0297, offline).
final driverRatingTagsProvider = FutureProvider<DriverRatingTags>((ref) async {
  try {
    final rows = await ref.watch(supabaseProvider).from('driver_rating_tags').select().eq('active', true);
    final tags = DriverRatingTags.fromRows([for (final r in rows) Map<String, dynamic>.from(r)]);
    return tags.high.isEmpty && tags.low.isEmpty ? DriverRatingTags.fallback : tags;
  } catch (_) {
    return DriverRatingTags.fallback;
  }
});

/// The driver's own totals per tag over the last [days] days (0297).
final myDriverTagTotalsProvider = FutureProvider.autoDispose.family<DriverTagTotals, int>((ref, days) async {
  final res = await ref.watch(supabaseProvider).rpc('my_driver_rating_tags', params: {'p_days': days});
  return DriverTagTotals.fromJson(res);
});

/// The passenger's rating of a ride (row-level security shows it to that
/// passenger only since 0297); null when there is none.
final myRideRatingProvider = FutureProvider.autoDispose.family<RideRating?, ({String requestId, String riderId})>(
  (ref, key) => ref.watch(rideRatingRepositoryProvider).mine(key.requestId, key.riderId),
);

// ---- Admin (0297) ------------------------------------------------------------

/// The admin's side of rating tags: the lists, the flag rule, one driver's
/// totals and flags, and the flags on the Partners list.
class DriverRatingAdminRepository {
  DriverRatingAdminRepository(this._db);
  final SupabaseClient _db;

  Future<DriverRatingTags> tags() async {
    final rows = await _db.from('driver_rating_tags').select().eq('active', true);
    return DriverRatingTags.fromRows([for (final r in rows) Map<String, dynamic>.from(r)]);
  }

  Future<void> setTags(DriverRatingTags t) =>
      _db.rpc('driver_rating_tags_set', params: {'p_high': t.high, 'p_low': t.low});

  Future<DriverFlagRule> rule() async =>
      DriverFlagRule.fromRow(await _db.from('driver_rating_flag_rule').select().maybeSingle());

  Future<void> setRule(DriverFlagRule r) =>
      _db.rpc('driver_rating_flag_rule_set', params: {'p_times': r.times, 'p_days': r.days});

  /// [partnerUserId]: the partner's sign-in id (partners.auth_user_id).
  Future<AdminDriverTags> driver(String partnerUserId) async =>
      AdminDriverTags.fromJson(await _db.rpc('admin_driver_rating_tags', params: {'p_partner': partnerUserId}));

  Future<Map<String, List<String>>> flags() async {
    final rows = await _db.rpc('admin_rating_flags');
    return driverFlagsByPartner([if (rows is List) for (final r in rows) if (r is Map) Map<String, dynamic>.from(r)]);
  }

  Future<void> markReviewed(String partnerUserId, String tag) =>
      _db.rpc('admin_rating_flag_review', params: {'p_partner': partnerUserId, 'p_tag': tag});
}

final driverRatingAdminRepositoryProvider = Provider((ref) => DriverRatingAdminRepository(ref.watch(supabaseProvider)));

final adminDriverRatingTagsProvider = FutureProvider.autoDispose<DriverRatingTags>(
  (ref) => ref.watch(driverRatingAdminRepositoryProvider).tags(),
);

final adminDriverFlagRuleProvider = FutureProvider.autoDispose<DriverFlagRule>(
  (ref) => ref.watch(driverRatingAdminRepositoryProvider).rule(),
);

final adminDriverTagsProvider = FutureProvider.autoDispose.family<AdminDriverTags, String>(
  (ref, partnerUserId) => ref.watch(driverRatingAdminRepositoryProvider).driver(partnerUserId),
);

/// Flagged drivers for the Partners list; none on a database before 0297.
final adminRatingFlagsProvider = FutureProvider.autoDispose<Map<String, List<String>>>((ref) async {
  try {
    return await ref.watch(driverRatingAdminRepositoryProvider).flags();
  } catch (_) {
    return const {};
  }
});
