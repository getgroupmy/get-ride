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
  /// Then, as the admin's ID card reading order says (0283, 0320), Google
  /// Vision reads the front when it is next (the office NAS, when it is
  /// before Vision and online, has it first: the id-read function says so).
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
    var mismatch = [for (final m in (res['mismatch'] as List?) ?? const []) '$m'];
    final id = res['id'] as String?;
    if (id != null && visionReadNeededFor(await config(), read)) {
      final v = await readCardWithVision(id);
      if (v['mismatch'] is List) mismatch = [for (final m in v['mismatch'] as List) '$m'];
    }
    return mismatch;
  }

  /// The id-read function: Google Vision reads the ID's front and the check
  /// keeps it. {state: read | not_read | error, name?, ic?, passport?,
  /// expiry?, mismatch?, reason?, detail?}. Never throws: the ID is sent
  /// either way.
  Future<Map<String, dynamic>> readCardWithVision(String checkId) async {
    try {
      final res = await _db.functions.invoke('id-read', body: {'check_id': checkId});
      return _map(res.data);
    } on FunctionException catch (e) {
      return {'state': 'error', 'reason': '${_map(e.details)['error'] ?? e.status}'};
    } catch (_) {
      return const {'state': 'error'};
    }
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

  /// Whether the signed-in person has a live selfie on record (liveness
  /// passed): the gate before a document with their photo is sent (0288).
  /// True when it can't be asked (an older database): the server flags it.
  Future<bool> liveSelfieOk() async {
    try {
      return (await _db.rpc('my_live_selfie_ok')) == true;
    } catch (_) {
      return true;
    }
  }

  /// Keeps a live selfie taken for the document gate: uploaded to the
  /// person's own ID_Image folder and recorded with how it was taken. The
  /// documents that waited for one are then compared (0288).
  Future<void> recordLiveSelfie(LiveSelfie selfie) async {
    // A profile-purpose selfie lives in the person's avatars folder (0281).
    final path = '$_uid/selfie_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final files = _db.storage.from('avatars');
    await uploadStoredFile(files, path, selfie.bytes, contentType: 'image/jpeg');
    final url = files.getPublicUrl(path);
    await _db.rpc('identity_check_submit', params: {
      'p': {
        'kind': 'selfie',
        'purpose': 'profile',
        'file_url': url,
        'liveness': selfie.liveness,
        'liveness_detail': ?selfie.detail,
      },
    });
  }

  /// The id-read function's text of the person's own registration document
  /// [fileUrl] (0288), when the admin's ID card reading allows the server;
  /// null when it isn't allowed, set up or read.
  Future<String?> readRegistrationText(String fileUrl) async {
    try {
      final res = await _db.functions.invoke('id-read', body: {'file_url': fileUrl, 'purpose': 'registration'});
      final m = _map(res.data);
      final text = '${m['text'] ?? ''}'.trim();
      return m['state'] == 'read' && text.isNotEmpty ? text : null;
    } catch (_) {
      return null;
    }
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

  /// The face-compare function's answer: {state, score?, provider?, reason?}.
  Future<Map<String, dynamic>> compareFaces(String id) async {
    try {
      final res = await _db.functions.invoke('face-compare', body: {'check_id': id});
      return _map(res.data);
    } on FunctionException catch (e) {
      return {'state': 'error', 'reason': '${_map(e.details)['error'] ?? e.status}'};
    }
  }

  /// Compares one document with the person's photo against their live
  /// selfie again (0288; Admin › Documents › Check again).
  Future<Map<String, dynamic>> compareDocumentFace(String kind, String id) async {
    try {
      final res = await _db.functions.invoke('face-compare', body: {
        'document': {'kind': kind, 'id': id},
      });
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

  /// The renewal window, who compares the faces and who reads the card
  /// (with, for an admin, which keys are there). The defaults when it can't
  /// be read.
  Future<IdentityConfig> config() async {
    try {
      return IdentityConfig.fromJson(await _db.rpc('dispatch_verify_config'));
    } catch (_) {
      return const IdentityConfig();
    }
  }

  /// Null leaves a setting as it is.
  Future<IdentityConfig> setProviders({String? face, String? idRead}) async =>
      IdentityConfig.fromJson(await _db.rpc('identity_set_providers', params: {'p_face': face, 'p_id_read': idRead}));

  /// Saves the orders and the low score (0320); null leaves a part as it is.
  Future<IdentityConfig> setOrder({List<OrderSlot>? faceOrder, List<OrderSlot>? idReaders, int? faceLowScore}) async =>
      IdentityConfig.fromJson(
        await _db.rpc('identity_set_order', params: {
          'p': {
            if (faceOrder != null) 'faceOrder': [for (final x in faceOrder) x.toJson()],
            if (idReaders != null) 'idReaders': [for (final x in idReaders) x.toJson()],
            'faceLowScore': ?faceLowScore,
          },
        }),
      );

  /// The waiting selfie/ID pairs no server has scored, for the in-browser
  /// check (0320): {id, other_id, selfie_url, card_url}. Empty when it is
  /// off, or on a database before 0320.
  Future<List<Map<String, dynamic>>> browserQueue() async {
    try {
      return _list(await _db.rpc('identity_face_browser_queue'));
    } catch (_) {
      return const [];
    }
  }

  /// Keeps the in-browser check's score on the check and its pair (never
  /// over a server's score). Returns how many were kept.
  Future<int> saveBrowserScore(String id, String? otherId, String state, double? score) async =>
      ((await _db.rpc('identity_face_browser_save', params: {
                'p_id': id,
                'p_other': otherId,
                'p_state': state,
                'p_score': score,
              }))
              as num?)
          ?.toInt() ??
      0;

  /// Admin › Settings › Office NAS › ID and face (0320).
  Future<Map<String, dynamic>> nasIdFace() async => _map(await _db.rpc('admin_nas_id_face'));

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

/// Who compares the faces and who reads the card (0283), for the admin's
/// settings and the Sign-in checks queue.
final identityConfigProvider = FutureProvider.autoDispose<IdentityConfig>(
  (ref) => ref.watch(identityRepositoryProvider).config(),
);

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
