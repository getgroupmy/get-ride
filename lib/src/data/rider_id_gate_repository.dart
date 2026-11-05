// Rider ID-verification gate (migrations 0342–0344): reads the admin rule and
// runs a rider's self-verification (upload the ID + a live selfie, score it
// server-side via the face-compare edge function, apply the auto-verify
// policy). The face score is computed on the server and never supplied here.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rider_id_gate.dart';
import '../providers.dart';
import '../widgets/live_selfie.dart' show LiveSelfie;
import 'identity_repository.dart' show identityRepositoryProvider;

/// The admin's per-country rules, read live-ish (re-fetched when invalidated).
final riderIdGateConfigProvider = FutureProvider<RiderIdGateConfig>((ref) async {
  try {
    return RiderIdGateConfig.fromJson(await ref.watch(supabaseProvider).rpc('rider_id_gate_config'));
  } catch (_) {
    return RiderIdGateConfig.empty;
  }
});

class RiderIdGateRepository {
  RiderIdGateRepository(this._ref);
  final Ref _ref;

  /// Uploads the rider's ID photo and live selfie, then asks the server to
  /// score the match and apply the auto-verify policy. [read] carries the
  /// fields read from the ID (name, ic, birth, nationality, gender, address,
  /// expiry); the server keeps them and fills the profile on a strong match.
  Future<({bool verified, bool pending})> riderVerify({
    required String docType,
    required Uint8List idFront,
    Uint8List? idBack,
    required LiveSelfie selfie,
    required Map<String, dynamic> read,
  }) async {
    final identity = _ref.read(identityRepositoryProvider);
    final idFrontUrl = await identity.uploadPhoto(idFront, 'id');
    final idBackUrl = idBack == null ? null : await identity.uploadPhoto(idBack, 'id_back');
    final selfieUrl = await identity.uploadPhoto(selfie.bytes, 'selfie');

    final res = await _ref.read(supabaseProvider).functions.invoke('face-compare', body: {
      'rider_verify': {
        'docType': docType,
        'idFrontUrl': idFrontUrl,
        'idBackUrl': ?idBackUrl,
        'selfieUrl': selfieUrl,
        'read': read,
      },
    });
    return parseRiderVerify(res.data);
  }
}

/// Reads the edge function's answer: verified / still pending. Anything
/// unexpected is treated as "not verified, pending" so a rider is never let
/// through on a malformed reply. Pure, for tests.
({bool verified, bool pending}) parseRiderVerify(Object? data) {
  if (data is Map) {
    final verified = data['verified'] == true;
    return (verified: verified, pending: verified ? false : data['pending'] != false);
  }
  return (verified: false, pending: true);
}

final riderIdGateRepositoryProvider = Provider((ref) => RiderIdGateRepository(ref));
