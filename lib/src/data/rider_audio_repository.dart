import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/rider_audio.dart';
import '../providers.dart';
import 'voice_protection_repository.dart';

/// True where the rider's trip is recorded: the phone apps, as the driver's.
bool get riderAudioSupported => voiceRecordingSupported;

/// `rider_audio_rules`, `rider_audio_at` and `ride_set_rider_audio`
/// (migration 0315). The recordings themselves are rows of
/// `voice_protection_recordings` ([VoiceProtectionRepository]).
class RiderAudioRepository {
  RiderAudioRepository(this._db);
  final SupabaseClient _db;

  static const _table = 'rider_audio_rules';

  Future<RiderAudioRules> rules() async {
    final rows = await _db.from(_table).select().order('created_at', ascending: true);
    return RiderAudioRules([for (final r in rows) RiderAudioRule.fromRow(r)]);
  }

  /// Writes a place's rule: a new one, or the one with its id.
  Future<void> saveRule(RiderAudioRule r) async {
    final row = r.toRow();
    if (r.id == null) {
      await _db.from(_table).insert(row);
    } else {
      await _db.from(_table).update(row).eq('id', r.id!);
    }
  }

  Future<void> deleteRule(String id) => _db.from(_table).delete().eq('id', id);

  /// What holds at a pickup, read where the server will read it.
  Future<RiderAudioAt> at({required double lat, required double lng, String? country, String? state, String? city}) async {
    final res = await _db.rpc(
      'rider_audio_at',
      params: {'p_lat': lat, 'p_lng': lng, 'p_country': country, 'p_state': state, 'p_city': city},
    );
    return RiderAudioAt.fromJson(res);
  }

  /// Turns it on or off for the rider's ride under way; answers what the
  /// ride now says. The server refuses on where it isn't offered.
  Future<bool> setRideAudio(String rideId, bool on) async =>
      await _db.rpc('ride_set_rider_audio', params: {'p_ride': rideId, 'p_on': on}) == true;
}

// Off the UI thread: an hour of speech is about 15 MB.
void _sealFile(({String raw, String out, Uint8List key, Uint8List nonce}) a) =>
    File(a.out).writeAsBytesSync(riderAudioCipher(a.key, a.nonce, File(a.raw).readAsBytesSync()), flush: true);

Uint8List _openFile(({String path, Uint8List key, Uint8List nonce}) a) =>
    riderAudioCipher(a.key, a.nonce, File(a.path).readAsBytesSync());

/// The phone-local half: the rider's switch, the folder the encrypted
/// recordings live in and the manifest of which is which (with its key).
class RiderAudioDeviceStore {
  Future<bool> enabled(String profileId) async =>
      (await SharedPreferences.getInstance()).getBool(riderAudioEnabledKey(profileId)) ?? false;

  Future<void> setEnabled(String profileId, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(riderAudioEnabledKey(profileId), value);

  Future<Map<String, RiderAudioLocal>> manifest() async =>
      decodeRiderManifest((await SharedPreferences.getInstance()).getString(riderAudioManifestKey));

  Future<void> saveManifest(Map<String, RiderAudioLocal> m) async =>
      (await SharedPreferences.getInstance()).setString(riderAudioManifestKey, encodeRiderManifest(m));

  Future<Directory> _dir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/rider-audio');
    await dir.create(recursive: true);
    return dir;
  }

  /// Where the microphone writes while the trip is under way (the app's
  /// private folder, never the user's documents).
  Future<String> newRecordingPath(String id) async => '${(await _dir()).path}/$id.m4a';

  /// Encrypts the finished recording at [rawPath] with a fresh key, keeps the
  /// encrypted file and deletes the plain one.
  Future<RiderAudioLocal> seal(String id, String rawPath, DateTime expiresAt) async {
    final key = riderAudioRandomBytes(32);
    final nonce = riderAudioRandomBytes(16);
    final out = '${(await _dir()).path}/$id.enc';
    await compute(_sealFile, (raw: rawPath, out: out, key: key, nonce: nonce));
    await delete(rawPath);
    return RiderAudioLocal(path: out, key: key, nonce: nonce, expiresAt: expiresAt);
  }

  /// The recording, decrypted, for an upload an agent asked for.
  Future<Uint8List> open(RiderAudioLocal local) =>
      compute(_openFile, (path: local.path, key: local.key, nonce: local.nonce));

  bool exists(String path) => File(path).existsSync();

  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

final riderAudioRepositoryProvider = Provider((ref) => RiderAudioRepository(ref.watch(supabaseProvider)));
final riderAudioDeviceStoreProvider = Provider((_) => RiderAudioDeviceStore());
final riderAudioRecorderProvider = Provider<TripAudioRecorder>((_) => newMicRecorder());

/// What holds at a pickup; null until the server answers, or when it can't
/// (the switch is offered only where the server says it is).
final riderAudioAtProvider = FutureProvider.autoDispose.family<RiderAudioAt?, ({double lat, double lng})>((ref, p) async {
  try {
    return await ref.watch(riderAudioRepositoryProvider).at(lat: p.lat, lng: p.lng);
  } catch (_) {
    return null;
  }
});

/// Every place's rule (Admin → Rider audio protection).
final riderAudioRulesProvider = FutureProvider.autoDispose<RiderAudioRules>(
  (ref) => ref.watch(riderAudioRepositoryProvider).rules(),
);
