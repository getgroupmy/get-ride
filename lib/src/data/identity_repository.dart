// The sign-in checks of a dispatch ID (migration 0281): the phone's side —
// what is still needed, sending a selfie or an ID — and the admin's — the
// review queue, the decision, the face match, the switches on a grant. Every
// rule is the server's (dispatch_my_checks, identity_check_submit,
// identity_check_review, dispatch_set_verify); this only asks.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/push_logic.dart' show pushDeviceKey;
import '../core/signin_checks.dart';
import '../providers.dart';
import '../widgets/live_selfie.dart' show LiveSelfie;
import 'doc_photos.dart';
import 'push_service.dart';

/// Kept per install where there is no push device key (the web, desktops).
const signInDeviceIdKey = 'signin_device_id_v1';

class IdentityRepository {
  IdentityRepository(this._db);
  final SupabaseClient _db;

  static Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

  static List<Map<String, dynamic>> _list(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  /// This phone, as the server knows it: its push device key (the one in
  /// push_tokens and user_sessions), else an id this install made itself.
  Future<String?> deviceKey() async {
    try {
      final push = await PushService.instance?.deviceKey();
      if (push != null) return push;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(signInDeviceIdKey) ?? const Uuid().v4();
      await prefs.setString(signInDeviceIdKey, raw);
      return pushDeviceKey('signin:$raw');
    } catch (_) {
      return null;
    }
  }

  // ---- The phone ----------------------------------------------------------------------------

  /// What the signed-in person still has to do. Nothing (none) without a
  /// session, on a database before 0281, or when it can't be read: the
  /// server holds the role shut either way.
  Future<DispatchChecks> myChecks() async {
    if (_db.auth.currentUser == null) return DispatchChecks.none;
    try {
      return DispatchChecks.fromJson(await _db.rpc('dispatch_my_checks', params: {'p_device': await deviceKey()}));
    } catch (_) {
      return DispatchChecks.none;
    }
  }

  /// Uploads a selfie or an ID side to the person's own folder in ID_Image
  /// (private: they and the admins read it). Returns its URL.
  Future<String> uploadPhoto(Uint8List bytes, String kind) async {
    final path = '$_uid/signin/${kind}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final files = _db.storage.from('ID_Image');
    await uploadStoredFile(files, path, bytes, contentType: 'image/jpeg');
    return files.getPublicUrl(path);
  }

  /// Sends a selfie (taken for a grant, or again on a new phone).
  Future<void> sendSelfie(LiveSelfie selfie, {bool recheck = false}) async {
    final url = await uploadPhoto(selfie.bytes, 'selfie');
    await _db.rpc('identity_check_submit', params: {
      'p': {
        'kind': 'selfie',
        'purpose': recheck ? 'recheck' : 'first',
        'file_url': url,
        'liveness': selfie.liveness,
        'liveness_detail': ?selfie.detail,
        'device': await deviceKey(),
      },
    });
  }

  /// Sends MyKad or passport, front and back, with what the phone read.
  Future<List<String>> sendId({
    required String docType,
    required Uint8List front,
    required Uint8List back,
    String? expiry,
    CardRead? read,
  }) async {
    final f = await uploadPhoto(front, 'id_front');
    final b = await uploadPhoto(back, 'id_back');
    String? day(DateTime? d) => d?.toIso8601String().split('T').first;
    final res = _map(
      await _db.rpc('identity_check_submit', params: {
        'p': {
          'kind': 'id',
          'doc_type': docType,
          'file_url': f,
          'file_url_back': b,
          'expiry_date': ?(expiry == null || expiry.trim().isEmpty ? null : expiry.trim()),
          'read_name': ?read?.name,
          'read_ic': ?read?.ic,
          'read_expiry': ?day(read?.expiry),
        },
      }),
    );
    return [for (final m in (res['mismatch'] as List?) ?? const []) '$m'];
  }

  /// Keeps how a profile photo was taken (live or not), for the admin. Best
  /// effort: the photo is saved either way.
  Future<void> noteProfileSelfie(String avatarUrl, LiveSelfie selfie) async {
    try {
      await _db.rpc('identity_check_submit', params: {
        'p': {
          'kind': 'selfie',
          'purpose': 'profile',
          'file_url': avatarUrl,
          'liveness': selfie.liveness,
          'liveness_detail': ?selfie.detail,
        },
      });
    } catch (_) {}
  }

  // ---- The admin -----------------------------------------------------------------------------

  /// Admin → Documents → Sign-in checks; [filter] waiting, approved, rejected or all.
  Future<List<Map<String, dynamic>>> list(String filter) async =>
      _list(await _db.rpc('identity_checks_list', params: {'p_filter': filter}));

  Future<int> waitingCount() async {
    try {
      return ((await _db.rpc('identity_checks_waiting')) as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> review(String id, {required bool approve, String? reason, String? note}) => _db.rpc(
    'identity_check_review',
    params: {
      'p_id': id,
      'p_status': approve ? 'Approved' : 'Rejected',
      'p_reason': reason,
      'p_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
    },
  );

  /// Users → ID documents: the profile's ID photo verified, or rejected with a reason.
  Future<void> reviewProfileId(String userId, {required bool verified, String? reason, String? note}) => _db.rpc(
    'profile_id_review',
    params: {
      'p_user': userId,
      'p_status': verified ? 'Verified' : 'Failed',
      'p_reason': reason,
      'p_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
    },
  );

  /// The face-compare function's answer: {state, score?, reason?}.
  Future<Map<String, dynamic>> compareFaces(String id) async {
    try {
      final res = await _db.functions.invoke('face-compare', body: {'check_id': id});
      return _map(res.data);
    } on FunctionException catch (e) {
      return {'state': 'error', 'reason': '${_map(e.details)['error'] ?? e.status}'};
    }
  }

  /// Users → Edit User: the person's dispatch roles, checks and phones.
  Future<Map<String, dynamic>> person(String userId) async =>
      _map(await _db.rpc('identity_person', params: {'p_user': userId}));

  Future<void> setAsks(String userId, String kind, SignInAsks asks) => _db.rpc(
    'dispatch_set_verify',
    params: {'p_user': userId, 'p_kind': kind, 'p_selfie': asks.selfie, 'p_id': asks.id, 'p_days': asks.days},
  );

  Future<int> renewDays() async {
    try {
      return ((_map(await _db.rpc('dispatch_verify_config'))['renewDays']) as num?)?.toInt() ?? 30;
    } catch (_) {
      return 30;
    }
  }

  Future<void> setRenewDays(int days) => _db.rpc('dispatch_set_verify_config', params: {'p_renew_days': days});
}

final identityRepositoryProvider = Provider((ref) => IdentityRepository(ref.watch(supabaseProvider)));

/// After a profile photo is saved: how it was taken, for the admin. Never
/// in the way of the photo itself.
Future<void> recordProfileSelfie(WidgetRef ref, String avatarUrl, LiveSelfie selfie) async {
  try {
    await ref.read(identityRepositoryProvider).noteProfileSelfie(avatarUrl, selfie);
  } catch (_) {}
}

/// The signed-in person's sign-in checks (re-read on sign-in).
final dispatchChecksProvider = FutureProvider<DispatchChecks>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(identityRepositoryProvider).myChecks();
});
