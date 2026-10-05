import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../admin/screens/people/people_logic.dart';
import '../core/partner_onboarding.dart';
import '../providers.dart';

/// What the onboarding wizard works on: the signed-in user's profile and
/// partner rows.
class OnboardingState {
  const OnboardingState({required this.profile, required this.partner});
  final Map<String, dynamic>? profile;
  final Map<String, dynamic> partner;

  String get partnerId => partner['id'] as String;
  OnboardingStep get step => firstIncompleteStep(profile, partner);

  OnboardingState copyWith({Map<String, dynamic>? profile, Map<String, dynamic>? partner}) =>
      OnboardingState(profile: profile ?? this.profile, partner: partner ?? this.partner);
}

/// Reads and writes for partner onboarding (Expo `partnerOnboardingStore`).
/// Every write runs as the signed-in user, under the partner/profile guards
/// of migrations 0087/0088: a partner can fill in their own details but never
/// approve themselves.
class PartnerOnboardingRepository {
  PartnerOnboardingRepository(this._db);
  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  Future<Map<String, dynamic>?> _profile() => _db
      .from('profiles')
      .select('id, name, phone, email, ic, address, avatar_url, profile_image, id_image, nationality')
      .eq('id', _uid)
      .maybeSingle();

  /// Loads the profile and the partner row, creating the partner row on the
  /// first visit: an admin-added row for this phone is claimed first
  /// (`claim_partner_by_phone`), and only then is a fresh stub inserted.
  Future<OnboardingState> load() async {
    final profile = await _profile();
    final mine = await _db
        .from('partners')
        .select()
        .eq('auth_user_id', _uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (mine != null) return OnboardingState(profile: profile, partner: mine);

    final claimed = await _db.rpc('claim_partner_by_phone');
    if (claimed is List && claimed.isNotEmpty) {
      return OnboardingState(profile: profile, partner: Map<String, dynamic>.from(claimed.first as Map));
    }

    final stub = newPartnerStub(
      id: const Uuid().v4(),
      displayId: newDisplayId('PR'),
      userId: _uid,
      profile: profile,
      joinedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final created = await _db.from('partners').insert(stub).select().single();
    return OnboardingState(profile: profile, partner: created);
  }

  /// Updates the partner row and records the step the wizard moves on to.
  Future<Map<String, dynamic>> patchPartner(OnboardingState s, Map<String, dynamic> patch) async {
    final next = {...s.partner, ...patch};
    final step = firstIncompleteStep(s.profile, next);
    return _db
        .from('partners')
        .update({...patch, 'onboarding_step': step.key})
        .eq('id', s.partnerId)
        .select()
        .single();
  }

  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> patch) async {
    await _db.from('profiles').update(patch).eq('id', _uid);
    return (await _profile()) ?? patch;
  }

  /// Uploads the profile photo to `avatars` and returns its public URL.
  Future<String> uploadAvatar(OnboardingState s, Uint8List bytes, String fileName) {
    final ext = guessExt(fileName);
    return _upload(
      'avatars',
      avatarPath(
        country: uploadCountry(s.partner, s.profile),
        phone: '${s.profile?['phone'] ?? s.partner['phone'] ?? _uid}',
        name: '${s.profile?['name'] ?? s.partner['name'] ?? ''}',
        ext: ext,
        owner: _uid,
      ),
      bytes,
      ext,
    );
  }

  /// Uploads a photo of the ID document to `ID_Image` and returns its URL.
  Future<String> uploadIdImage(OnboardingState s, String idNumber, Uint8List bytes, String fileName) {
    final ext = guessExt(fileName);
    return _upload(
      'ID_Image',
      idImagePath(
        country: uploadCountry(s.partner, s.profile),
        phone: '${s.profile?['phone'] ?? s.partner['phone'] ?? _uid}',
        idNumber: idNumber.isEmpty ? 'id' : idNumber,
        ext: ext,
        owner: _uid,
      ),
      bytes,
      ext,
    );
  }

  Future<String> _upload(String bucket, String path, Uint8List bytes, String ext) async {
    await _db.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: contentTypeFor(ext)),
        );
    return _db.storage.from(bucket).getPublicUrl(path);
  }
}

final partnerOnboardingRepositoryProvider =
    Provider((ref) => PartnerOnboardingRepository(ref.watch(supabaseProvider)));
