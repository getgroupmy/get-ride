// The partner selfie check when going online (migration 0290): the phone's
// side (is a check due, "Not now", the selfie, its result) and the admin's
// (settings, the checks, the watch list). Every rule is the server's; this
// only asks.
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/online_selfie.dart';
import '../providers.dart';
import '../widgets/live_selfie.dart' show LiveSelfie;
import 'identity_repository.dart';

class OnlineSelfieRepository {
  OnlineSelfieRepository(this._db, this._identity);
  final SupabaseClient _db;
  final IdentityRepository _identity;

  static Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

  static List<Map<String, dynamic>> _list(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  // ---- The phone ------------------------------------------------------------------------------

  /// The phone's make and model ("samsung SM-A546E"), or null.
  Future<String?> deviceModel() async {
    try {
      final info = DeviceInfoPlugin();
      if (kIsWeb) return null;
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await info.androidInfo;
          return '${a.manufacturer} ${a.model}'.trim();
        case TargetPlatform.iOS:
          final i = await info.iosInfo;
          return i.modelName.trim().isEmpty ? i.utsname.machine : i.modelName;
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Whether a check is due before going online on [platform].
  Future<OnlineSelfieDue> start({required String platform}) async {
    final phone = onlineSelfieOnPhone(platform);
    return OnlineSelfieDue.fromJson(
      await _db.rpc(
        'online_selfie_check_start',
        params: {
          'p_device': phone ? await _identity.deviceKey() : null,
          'p_platform': platform,
          'p_model': phone ? await deviceModel() : null,
        },
      ),
    );
  }

  /// "Not now" ('not_now') or the time ran out ('timeout'). Best effort.
  Future<void> skip(String id, String why) async {
    try {
      await _db.rpc('online_selfie_check_skip', params: {'p_id': id, 'p_why': why});
    } catch (_) {}
  }

  /// Sends the live selfie for check [id].
  Future<void> submit(String id, LiveSelfie selfie) async {
    final url = await _identity.uploadPhoto(selfie.bytes, 'online_selfie');
    await _db.rpc(
      'online_selfie_check_submit',
      params: {
        'p_id': id,
        'p': {
          'file_url': url,
          'liveness': selfie.liveness,
          'liveness_detail': ?selfie.detail,
          'model': ?await deviceModel(),
        },
      },
    );
  }

  /// The check as it stands now (the partner's own).
  Future<Map<String, dynamic>> result(String id) async => _map(
    await _db
        .from('partner_online_checks')
        .select('id, state, face_state, face_score, low_match')
        .eq('id', id)
        .maybeSingle(),
  );

  // ---- The admin -----------------------------------------------------------------------------

  Future<OnlineSelfieConfig> config() async => OnlineSelfieConfig.fromJson(await _db.rpc('online_selfie_config'));

  Future<OnlineSelfieConfig> setConfig(OnlineSelfieConfig c) async =>
      OnlineSelfieConfig.fromJson(await _db.rpc('online_selfie_set_config', params: {'p': c.toJson()}));

  /// [filter]: 'closer' (needs a closer look) or 'all'.
  Future<List<Map<String, dynamic>>> list(String filter) async =>
      _list(await _db.rpc('online_selfie_checks_list', params: {'p_filter': filter}));

  Future<int> closerCount() async {
    try {
      return ((await _db.rpc('online_selfie_closer_count')) as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// The alert's page; null when it is gone.
  Future<Map<String, dynamic>?> check(String id) async {
    final v = await _db.rpc('online_selfie_check_get', params: {'p_id': id});
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  Future<void> review(String id, {String? note}) => _db.rpc(
    'online_selfie_check_review',
    params: {'p_id': id, 'p_note': (note ?? '').trim().isEmpty ? null : note!.trim()},
  );

  /// Asks the face-compare function again: {state, score?, provider?, reason?}.
  Future<Map<String, dynamic>> compareAgain(String id) async {
    try {
      final res = await _db.functions.invoke(
        'face-compare',
        body: {
          'online_check': {'id': id},
        },
      );
      return _map(res.data);
    } on FunctionException catch (e) {
      return {'state': 'error', 'reason': '${_map(e.details)['error'] ?? e.status}'};
    }
  }

  /// Edit Partner: {checks, watch}.
  Future<Map<String, dynamic>> person(String userId) async =>
      _map(await _db.rpc('online_selfie_person', params: {'p_user': userId}));

  Future<List<Map<String, dynamic>>> watchList() async => _list(await _db.rpc('online_selfie_watch_list'));

  Future<void> watchSet(String userId, WatchEntry w, {String? fromCheck}) => _db.rpc(
    'online_selfie_watch_set',
    params: {
      'p_user': userId,
      'p_rule': w.rule.value,
      'p_pct': w.rule == WatchRule.percent ? w.pct : null,
      'p_cap': w.rule == WatchRule.percent ? w.cap : null,
      'p_hours': w.rule == WatchRule.hours ? w.hours : null,
      'p_until': w.until,
      'p_reason': w.reason.trim(),
      'p_check': fromCheck,
    },
  );

  Future<void> watchRemove(String userId) => _db.rpc('online_selfie_watch_remove', params: {'p_user': userId});

  /// Every admin and sub-admin, for the alert's "Selected admins".
  Future<List<({String id, String name})>> admins() async => [
    for (final r in _list(await _db.rpc('support_agents')))
      if (r['profile_id'] != null) (id: '${r['profile_id']}', name: '${r['name'] ?? 'Admin'}'),
  ];
}

final onlineSelfieRepositoryProvider = Provider(
  (ref) => OnlineSelfieRepository(ref.watch(supabaseProvider), ref.watch(identityRepositoryProvider)),
);

/// Where this app runs, for the check (overridden in tests).
final onlineSelfiePlatformProvider = Provider<String>((_) => onlineSelfiePlatform());
