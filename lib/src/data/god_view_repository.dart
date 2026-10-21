// Admin → God View (migrations 0270, 0272): the snapshot the page polls, a phone
// shown on request (logged by the server), suspend and a push to one
// person. Who may do what is the server's; this only asks.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/admin_repository.dart';
import '../core/god_view.dart';
import '../providers.dart';

class GodViewRepository {
  GodViewRepository(this._db);
  final SupabaseClient? _db;

  /// Everyone inside [box] (the map's visible area; null for everywhere),
  /// or everyone matching [query] wherever they are. [showOffline]: the
  /// page's "Last known" toggle, also everyone else at their last known
  /// position, up to 7 days old (migration 0272).
  Future<GodViewSnapshot> snapshot({
    ({double minLat, double minLng, double maxLat, double maxLng})? box,
    bool showOffline = false,
    String query = '',
    int limit = 1500,
  }) async {
    final q = query.trim();
    final res = await _db!.rpc(
      'god_view_snapshot',
      params: {
        'p_min_lat': box?.minLat,
        'p_min_lng': box?.minLng,
        'p_max_lat': box?.maxLat,
        'p_max_lng': box?.maxLng,
        'p_show_offline': showOffline,
        'p_query': q.isEmpty ? null : q,
        'p_limit': limit,
      },
    );
    return GodViewSnapshot.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {}, query: q);
  }

  /// The person's phone; the server records that this admin looked.
  Future<String?> revealPhone(String profileId) async {
    final res = await _db!.rpc('god_view_reveal_phone', params: {'p_profile_id': profileId});
    return res is Map ? res['phone'] as String? : null;
  }

  /// Blocks a partner or user as the Partners / Users pages do. True when
  /// a partner was on a ride, which they may finish.
  Future<bool> suspend(String profileId, String reason, {String? note}) async {
    final res = await _db!.rpc(
      'god_view_suspend',
      params: {'p_profile_id': profileId, 'p_reason': reason, 'p_note': note},
    );
    return res is Map && res['on_trip'] == true;
  }

  /// A push to this one person, as Admin → Push Notification sends
  /// (send-push, kept in the push history as "direct").
  Future<void> sendPush(String profileId, String title, String body) =>
      AdminRepository(_db!).sendPush(title, body, 'all', profileId: profileId);
}

final godViewRepositoryProvider = Provider<GodViewRepository>(
  (ref) => GodViewRepository(ref.watch(supabaseProvider)),
);

/// How often the page asks while it is on screen; null in tests (no timer).
final godViewPollProvider = Provider<Duration?>((ref) => const Duration(seconds: 5));

/// The clock behind "updated N s ago" and the ages. A seam for tests.
final godViewClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
