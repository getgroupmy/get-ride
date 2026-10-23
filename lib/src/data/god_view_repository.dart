// Admin → God View (migrations 0270, 0272, 0275, 0276): the snapshot the
// page polls, the people with no location, a phone shown on request (logged
// by the server), suspend, a push to one person, "Ping now" and the God
// View settings. Who may do what is the server's; this only asks.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/admin_repository.dart';
import '../core/god_view.dart';
import '../core/god_view_trail.dart';
import '../providers.dart';

class GodViewRepository {
  GodViewRepository(this._db);
  final SupabaseClient? _db;

  /// Everyone inside [box] (the map's visible area; null for everywhere),
  /// or everyone matching [query] wherever they are. [showOffline]: the
  /// page's "Last known" toggle (on by default), also everyone else at
  /// their last known position, up to 7 days old (migration 0272).
  Future<GodViewSnapshot> snapshot({
    ({double minLat, double minLng, double maxLat, double maxLng})? box,
    bool showOffline = true,
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

  /// Everyone God View cannot put on the map, with why (migration 0275),
  /// by name; a sub-admin gets only those the server can place in their
  /// region. Never a phone number.
  Future<List<GodViewUnlocated>> unlocated({String query = '', int limit = 500}) async {
    final q = query.trim();
    final rows = await _db!
        .rpc('god_view_unlocated', params: {'p_query': q.isEmpty ? null : q, 'p_limit': limit})
        .order('name', ascending: true)
        .limit(limit);
    return [
      for (final r in rows as List)
        if (r is Map) GodViewUnlocated.fromJson(Map<String, dynamic>.from(r)),
    ];
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

  /// "Ping now" (migration 0276): a silent "Still there?" push to this
  /// person's Always on phones, each at most once in 2 minutes; the server
  /// checks God View access and logs it.
  Future<GodViewPingResult> ping(String profileId) async {
    final res = await _db!.rpc('god_view_ping', params: {'p_profile_id': profileId});
    return GodViewPingResult.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {});
  }

  /// Whether one of the person's phones reported since [since] (the ping's
  /// sent_at), and when its last report was.
  Future<({bool answered, DateTime? at})> pingAnswer(String profileId, DateTime since) async {
    final res = await _db!.rpc(
      'god_view_ping_answer',
      params: {'p_profile_id': profileId, 'p_since': since.toUtc().toIso8601String()},
    );
    final m = res is Map ? res : const {};
    return (answered: m['answered'] == true, at: DateTime.tryParse('${m['located_at'] ?? ''}'));
  }

  /// Where [profileId] went between [from] and [to] (migration 0278, at
  /// most 48 hours; the server checks God View access and logs it).
  Future<GodViewTrail> trail(String profileId, DateTime from, DateTime to) async {
    final res = await _db!.rpc('god_view_trail', params: {
      'p_profile_id': profileId,
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return GodViewTrail.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {});
  }

  /// Admin → God View → Settings; full admins only. The settings as saved.
  Future<GodViewSettings> saveSettings(GodViewSettings s) async {
    final res = await _db!.rpc(
      'god_view_save_settings',
      params: {'p_pings': s.pings, 'p_ping_minutes': s.pingMinutes, 'p_always_on_hours': s.alwaysOnHours},
    );
    final saved = GodViewSettings.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {});
    return GodViewSettings(
      pings: saved.pings,
      pingMinutes: saved.pingMinutes,
      alwaysOnHours: saved.alwaysOnHours,
      editable: s.editable,
    );
  }
}

final godViewRepositoryProvider = Provider<GodViewRepository>(
  (ref) => GodViewRepository(ref.watch(supabaseProvider)),
);

/// How often the page asks while it is on screen; null in tests (no timer).
final godViewPollProvider = Provider<Duration?>((ref) => const Duration(seconds: 5));

/// How often the page asks whether a pinged phone answered. A seam for tests.
final godViewPingPollProvider = Provider<Duration>((ref) => const Duration(seconds: 4));

/// The clock behind "updated N s ago" and the ages. A seam for tests.
final godViewClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
