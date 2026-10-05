import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/voice_protection.dart';
import '../providers.dart';

/// True where trip audio is recorded: the phone apps. A browser or a desktop
/// build never records, and never answers an upload request either (it
/// cannot hold the file).
bool get voiceRecordingSupported =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// The microphone, behind a seam so tests can stand in for it.
abstract class TripAudioRecorder {
  Future<bool> hasPermission();
  Future<void> start(String path);

  /// Stops and answers the file written, or null when nothing was captured.
  Future<String?> stop();
}

class _MicRecorder implements TripAudioRecorder {
  AudioRecorder? _rec;

  @override
  Future<bool> hasPermission() => (_rec ??= AudioRecorder()).hasPermission();

  @override
  Future<void> start(String path) => (_rec ??= AudioRecorder()).start(
    // Speech only: mono AAC at a low bit rate keeps an hour near 15 MB.
    const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 22050, numChannels: 1),
    path: path,
  );

  @override
  Future<String?> stop() async {
    final rec = _rec;
    if (rec == null) return null;
    final path = await rec.stop();
    await rec.dispose();
    _rec = null;
    return path;
  }
}

/// The phone-local half: the per-profile toggle, the folder the recordings
/// live in and the manifest of which recording is which file.
class VoiceDeviceStore {
  Future<bool> enabled(String profileId) async =>
      (await SharedPreferences.getInstance()).getBool(voiceEnabledKey(profileId)) ?? false;

  Future<void> setEnabled(String profileId, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(voiceEnabledKey(profileId), value);

  Future<Map<String, String>> manifest() async {
    final raw = (await SharedPreferences.getInstance()).getString(voiceManifestKey);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> saveManifest(Map<String, String> m) async =>
      (await SharedPreferences.getInstance()).setString(voiceManifestKey, jsonEncode(m));

  /// A new file path in the app's private folder (not the user's documents).
  Future<String> newRecordingPath(String id) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/voice-protection');
    await dir.create(recursive: true);
    return '${dir.path}/$id.m4a';
  }

  bool exists(String path) => File(path).existsSync();

  DateTime? modified(String path) {
    try {
      return File(path).lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> read(String path) => File(path).readAsBytes();

  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

/// `voice_protection_recordings` and the private `voice-protection` bucket.
class VoiceProtectionRepository {
  VoiceProtectionRepository(this._db);
  final SupabaseClient _db;

  static const _table = 'voice_protection_recordings';

  Future<void> insert(Map<String, dynamic> row) => _db.from(_table).insert(row);

  /// Rows of [profileId] past their retention window.
  Future<Set<String>> expiredIds(String profileId, DateTime now) async {
    final rows = await _db
        .from(_table)
        .select('id')
        .eq('profile_id', profileId)
        .lt('expires_at', now.toUtc().toIso8601String());
    return {for (final r in rows) '${r['id']}'};
  }

  Future<void> markUnavailable(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await _db.from(_table).update({'unavailable': true}).inFilter('id', ids.toList()).eq('uploaded', false);
  }

  /// Uploads an agent asked for that are not done yet.
  Future<List<VoiceRecording>> pendingUploads(String profileId) async {
    final rows = await _db
        .from(_table)
        .select()
        .eq('profile_id', profileId)
        .eq('upload_requested', true)
        .eq('uploaded', false)
        .eq('unavailable', false);
    return rows.map(VoiceRecording.fromRow).toList();
  }

  Future<void> upload(VoiceRecording rec, Uint8List bytes, String localPath) async {
    final path = voiceStoragePath(rec.profileId, rec.id, localPath);
    await _db.storage
        .from(voiceProtectionBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(upsert: true, contentType: voiceContentType(localPath)));
    // The bucket is private: keep the storage path; a signed URL is made on read.
    await _db
        .from(_table)
        .update({
          'uploaded': true,
          'uploaded_at': DateTime.now().toUtc().toIso8601String(),
          'media_url': path,
          'unavailable': false,
        })
        .eq('id', rec.id);
  }

  /// Calls [onChange] whenever one of [profileId]'s rows changes (an
  /// agent's request, or the phone answering it). Answers the unsubscribe.
  Future<void> Function() watch(String profileId, void Function() onChange) {
    final channel = _db
        .channel('voice_protection_${profileId}_${DateTime.now().microsecondsSinceEpoch}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: _table,
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'profile_id', value: profileId),
          callback: (_) => onChange(),
        )
        .subscribe();
    return () => _db.removeChannel(channel);
  }

  // ---- Support agent -------------------------------------------------------

  Future<List<VoiceRecording>> forProfile(String profileId) async {
    final rows = await _db.from(_table).select().eq('profile_id', profileId).order('recorded_at', ascending: false);
    return rows.map(VoiceRecording.fromRow).toList();
  }

  Future<void> requestUpload(String recordingId, {required String? adminId, String? ticketId}) => _db
      .from(_table)
      .update({
        'upload_requested': true,
        'upload_requested_by': adminId,
        'upload_requested_at': DateTime.now().toUtc().toIso8601String(),
        'ticket_id': ticketId,
      })
      .eq('id', recordingId);

  /// A one-hour link to an uploaded recording.
  Future<String> signedUrl(String mediaPath) async {
    if (mediaPath.startsWith('http')) return mediaPath;
    return _db.storage.from(voiceProtectionBucket).createSignedUrl(mediaPath, 3600);
  }
}

final voiceProtectionRepositoryProvider = Provider((ref) => VoiceProtectionRepository(ref.watch(supabaseProvider)));
final voiceDeviceStoreProvider = Provider((_) => VoiceDeviceStore());
final tripAudioRecorderProvider = Provider<TripAudioRecorder>((_) => _MicRecorder());
