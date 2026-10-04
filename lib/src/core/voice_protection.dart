/// VoiceProtection — pure port of the decisions in Expo
/// `utils/voiceProtectionStore.ts` + `contexts/VoiceProtectionContext.tsx`.
///
/// When the driver has it on, trip audio is recorded with the phone's
/// microphone while a ride is under way. The file stays on the phone only,
/// is never played back to the user, and is deleted after 24 hours. A
/// metadata row in `voice_protection_recordings` lets a support agent
/// *request* the file (e.g. for a ride complaint); the phone that holds it
/// then uploads it to the private `voice-protection` bucket.
library;

const voiceProtectionBucket = 'voice-protection';

/// How long a recording is kept on the phone.
const voiceRetention = Duration(hours: 24);

String voiceEnabledKey(String profileId) => 'voice_protection_enabled_$profileId';

const voiceManifestKey = 'voice_protection_manifest_v1';

DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v');

/// A `voice_protection_recordings` row.
class VoiceRecording {
  const VoiceRecording({
    required this.id,
    required this.profileId,
    required this.recordedAt,
    required this.expiresAt,
    this.rideId,
    this.rideLabel,
    this.durationSec = 0,
    this.uploadRequested = false,
    this.uploadRequestedAt,
    this.uploaded = false,
    this.mediaUrl,
    this.unavailable = false,
  });

  factory VoiceRecording.fromRow(Map<String, dynamic> r) {
    final recorded = _time(r['recorded_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final d = r['duration_sec'];
    return VoiceRecording(
      id: '${r['id']}',
      profileId: '${r['profile_id'] ?? ''}',
      rideId: r['ride_id'] as String?,
      rideLabel: r['ride_label'] as String?,
      recordedAt: recorded,
      expiresAt: _time(r['expires_at']) ?? recorded.add(voiceRetention),
      durationSec: d is num ? d.round() : int.tryParse('${d ?? ''}') ?? 0,
      uploadRequested: r['upload_requested'] == true,
      uploadRequestedAt: _time(r['upload_requested_at']),
      uploaded: r['uploaded'] == true,
      mediaUrl: r['media_url'] as String?,
      unavailable: r['unavailable'] == true,
    );
  }

  final String id;
  final String profileId;
  final String? rideId;
  final String? rideLabel;
  final DateTime recordedAt;
  final DateTime expiresAt;
  final int durationSec;
  final bool uploadRequested;
  final DateTime? uploadRequestedAt;
  final bool uploaded;
  final String? mediaUrl;
  final bool unavailable;

  /// An upload the phone still owes: requested, not done, not given up on.
  bool get uploadPending => uploadRequested && !uploaded && !unavailable;
}

/// The metadata row written when a recording is saved.
Map<String, dynamic> newRecordingRow({
  required String id,
  required String profileId,
  required DateTime recordedAt,
  required Duration duration,
  required bool savedOnDevice,
  String? rideId,
  String? rideLabel,
}) => {
  'id': id,
  'profile_id': profileId,
  'ride_id': rideId,
  'ride_label': rideLabel,
  'recorded_at': recordedAt.toUtc().toIso8601String(),
  'duration_sec': duration.inSeconds < 0 ? 0 : (duration.inMilliseconds / 1000).round(),
  'expires_at': recordedAt.add(voiceRetention).toUtc().toIso8601String(),
  'unavailable': !savedOnDevice,
};

/// Which manifest entries to delete: the ones whose row has expired, any
/// whose file is gone, and (belt and braces) any file older than the
/// retention window by its own timestamp.
Set<String> expiredLocalRecordings({
  required Map<String, String> manifest,
  required Set<String> expiredIds,
  required DateTime now,
  required bool Function(String path) exists,
  required DateTime? Function(String path) modified,
}) => {
  for (final e in manifest.entries)
    if (expiredIds.contains(e.key) ||
        !exists(e.value) ||
        (modified(e.value) != null && now.difference(modified(e.value)!) > voiceRetention))
      e.key,
};

/// What the phone does with an upload request for [recordingId].
enum UploadAction {
  /// This phone holds the file: upload it.
  upload,

  /// This phone recorded it but the file is gone: tell the agent it can't come.
  markUnavailable,

  /// Not recorded on this phone (another device, or a browser): leave it to
  /// the phone that has it. The purge flags it once it expires.
  ignore,
}

UploadAction uploadActionFor({required String? localPath, required bool fileExists}) {
  if (localPath == null) return UploadAction.ignore;
  return fileExists ? UploadAction.upload : UploadAction.markUnavailable;
}

String _ext(String path) {
  final m = RegExp(r'\.([a-z0-9]{2,5})$').firstMatch(path.toLowerCase().split('?').first);
  return m?.group(1) ?? 'm4a';
}

/// Where an upload goes in the private bucket (the owner's folder, which the
/// storage policy scopes to them and admins).
String voiceStoragePath(String profileId, String recordingId, String localPath) =>
    '$profileId/$recordingId.${_ext(localPath)}';

String voiceContentType(String path) => switch (_ext(path)) {
  'mp3' => 'audio/mpeg',
  'wav' => 'audio/wav',
  _ => 'audio/mp4',
};

/// "m:ss".
String formatRecordingDuration(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// What the support agent sees for a recording.
enum RecordingState { uploaded, waitingForDevice, unavailable, expired, onDevice }

RecordingState recordingState(VoiceRecording r, DateTime now) {
  if (r.uploaded && r.mediaUrl != null) return RecordingState.uploaded;
  if (r.unavailable) return RecordingState.unavailable;
  if (now.isAfter(r.expiresAt)) return RecordingState.expired;
  if (r.uploadRequested) return RecordingState.waitingForDevice;
  return RecordingState.onDevice;
}

String recordingStateLabel(RecordingState s) => switch (s) {
  RecordingState.uploaded => 'Uploaded',
  RecordingState.waitingForDevice => "Requested · waiting for the user's phone",
  RecordingState.unavailable => 'Not available',
  RecordingState.expired => 'Deleted from the phone',
  RecordingState.onDevice => "On the user's phone",
};
