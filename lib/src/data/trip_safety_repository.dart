// Trip safety signals (lib/src/core/trip_safety.dart; migration 0154): the
// passenger's "I'm OK", lost item reports and the driver's answers.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/trip_safety.dart';
import '../providers.dart';
import 'live_tables.dart';

class TripSafetyRepository {
  TripSafetyRepository(this._db);
  final SupabaseClient _db;

  /// The passenger answers the start check or the separation question.
  Future<void> ok(String requestId) => _db.rpc('trip_safety_ok', params: {'p_request': requestId});

  Future<void> reportLostItem(String requestId, String description) =>
      _db.rpc('report_lost_item', params: {'p_request': requestId, 'p_description': description});

  Future<void> respondLostItem(String itemId, LostItemStatus status, {String? note}) =>
      _db.rpc('respond_lost_item', params: {'p_item': itemId, 'p_status': status.db, 'p_note': note});

  /// This trip's reports, newest first; none on a database without them.
  Future<List<LostItem>> forRide(String requestId) => _list((q) => q.eq('request_id', requestId));

  /// Reports for the signed-in driver from the last week, newest first.
  Future<List<LostItem>> forDriver(String driverId) => _list(
    (q) => q
        .eq('partner_id', driverId)
        .gte('created_at', DateTime.now().toUtc().subtract(lostItemWindow).toIso8601String()),
  );

  Future<List<LostItem>> _list(
    PostgrestFilterBuilder<List<Map<String, dynamic>>> Function(PostgrestFilterBuilder<List<Map<String, dynamic>>>)
    where,
  ) async {
    try {
      final rows = await where(_db.from('ride_lost_items').select()).order('created_at', ascending: false);
      return [for (final r in rows) LostItem.fromRow(r)];
    } on PostgrestException catch (e) {
      if (e.code == '42P01' || e.code == 'PGRST205') return const [];
      rethrow;
    }
  }
}

final tripSafetyRepositoryProvider = Provider((ref) => TripSafetyRepository(ref.watch(supabaseProvider)));

final rideLostItemsProvider = FutureProvider.autoDispose.family<List<LostItem>, String>((ref, requestId) {
  ref.watchLive('ride_lost_items');
  return ref.watch(tripSafetyRepositoryProvider).forRide(requestId);
});

final driverLostItemsProvider = FutureProvider.autoDispose<List<LostItem>>((ref) async {
  ref.watchLive('ride_lost_items');
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  return ref.watch(tripSafetyRepositoryProvider).forDriver(uid);
});
