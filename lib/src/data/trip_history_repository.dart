// Reads a person's requests for one side of them (core/trip_history.dart),
// newest first, a page at a time.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/trip_history.dart';
import '../providers.dart';
import 'models.dart';

class TripHistoryRepository {
  TripHistoryRepository(this._db);
  final SupabaseClient _db;

  /// Up to [limit] requests where the signed-in person is [role], newest
  /// first, older than [before] when given (the next page).
  Future<List<RideRequest>> page(
    TripHistoryRole role, {
    TripHistoryFilter filter = TripHistoryFilter.all,
    DateTime? before,
    int limit = tripHistoryPageSize,
  }) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    var q = _db.from('ride_requests').select().eq(role.column, uid);
    final statuses = filter.statuses;
    if (statuses != null) q = q.inFilter('status', statuses);
    if (before != null) q = q.lt('created_at', before.toUtc().toIso8601String());
    final rows = await q.order('created_at', ascending: false).limit(limit);
    return rows.map(RideRequest.new).toList();
  }
}

final tripHistoryRepositoryProvider = Provider((ref) => TripHistoryRepository(ref.watch(supabaseProvider)));
