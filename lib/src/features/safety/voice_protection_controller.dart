import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/voice_protection.dart';
import '../../data/voice_protection_repository.dart';
import '../../providers.dart';

class VoiceProtectionState {
  const VoiceProtectionState({this.enabled = false, this.loaded = false, this.recording = false, this.error});

  final bool enabled;
  final bool loaded;

  /// A trip is being recorded right now (drives the on-trip indicator).
  final bool recording;

  /// Why the last recording could not start (shown on the trip screen).
  final String? error;

  VoiceProtectionState copyWith({bool? enabled, bool? loaded, bool? recording, String? error}) => VoiceProtectionState(
    enabled: enabled ?? this.enabled,
    loaded: loaded ?? this.loaded,
    recording: recording ?? this.recording,
    error: error,
  );
}

/// VoiceProtection on this phone (Expo `VoiceProtectionContext`): the
/// per-profile toggle, the trip recorder, the 24-hour purge and the uploads
/// an agent asks for. Recordings are never played back here; the only way
/// out for the audio is an agent's request.
class VoiceProtectionController extends Notifier<VoiceProtectionState> {
  String? _profileId;
  String? _recordingId;
  String? _path;
  DateTime? _startedAt;
  ({String? rideId, String? label})? _ride;
  bool _uploading = false;

  @override
  VoiceProtectionState build() {
    final uid = ref.watch(currentUserIdProvider);
    _profileId = uid;
    if (uid != null) unawaited(_load(uid));
    return VoiceProtectionState(loaded: uid == null);
  }

  Future<void> _load(String uid) async {
    final on = await ref.read(voiceDeviceStoreProvider).enabled(uid);
    if (_profileId == uid) state = state.copyWith(enabled: on, loaded: true);
  }

  Future<void> setEnabled(bool value) async {
    final uid = _profileId;
    if (uid == null) return;
    state = state.copyWith(enabled: value);
    await ref.read(voiceDeviceStoreProvider).setEnabled(uid, value);
  }

  /// Starts recording a trip, when the driver has VoiceProtection on and this
  /// is a phone. Asking again while recording is a no-op.
  Future<void> startTrip({String? rideId, String? label}) async {
    final uid = _profileId;
    if (!state.enabled || uid == null || _recordingId != null || !voiceRecordingSupported) return;
    final recorder = ref.read(tripAudioRecorderProvider);
    final id = const Uuid().v4();
    _recordingId = id; // claimed before the first await, so a second call is a no-op
    try {
      if (!await recorder.hasPermission()) {
        _recordingId = null;
        state = state.copyWith(error: 'Microphone access is off, so this trip is not being recorded.');
        return;
      }
      final path = await ref.read(voiceDeviceStoreProvider).newRecordingPath(id);
      await recorder.start(path);
      _path = path;
      _startedAt = DateTime.now();
      _ride = (rideId: rideId, label: label);
      state = state.copyWith(recording: true);
    } catch (_) {
      _recordingId = null;
      state = state.copyWith(recording: false, error: 'Trip recording could not start.');
    }
  }

  /// Stops the recording (if any), files it and writes its metadata row.
  Future<void> stopTrip() async {
    final id = _recordingId;
    final uid = _profileId;
    final startedAt = _startedAt;
    final ride = _ride;
    _recordingId = null;
    _startedAt = null;
    _ride = null;
    if (id == null || uid == null || startedAt == null) {
      state = state.copyWith(recording: false);
      return;
    }
    state = state.copyWith(recording: false);
    final device = ref.read(voiceDeviceStoreProvider);
    String? file;
    try {
      file = await ref.read(tripAudioRecorderProvider).stop() ?? _path;
    } catch (_) {
      file = _path;
    }
    _path = null;
    final saved = file != null && device.exists(file);
    if (saved) {
      final m = await device.manifest();
      m[id] = file;
      await device.saveManifest(m);
    }
    try {
      await ref
          .read(voiceProtectionRepositoryProvider)
          .insert(
            newRecordingRow(
              id: id,
              profileId: uid,
              recordedAt: startedAt,
              duration: DateTime.now().difference(startedAt),
              savedOnDevice: saved,
              rideId: ride?.rideId,
              rideLabel: ride?.label,
            ),
          );
    } catch (_) {
      // Without its row no agent can ask for it; the purge still deletes it.
    }
  }

  /// Deletes recordings past the 24-hour window and tells agents they are gone.
  Future<void> purgeExpired() async {
    final uid = _profileId;
    if (uid == null || !voiceRecordingSupported) return;
    final device = ref.read(voiceDeviceStoreProvider);
    final repo = ref.read(voiceProtectionRepositoryProvider);
    final manifest = await device.manifest();
    var expired = <String>{};
    try {
      expired = await repo.expiredIds(uid, DateTime.now());
    } catch (_) {}
    final drop = expiredLocalRecordings(
      manifest: manifest,
      expiredIds: expired,
      now: DateTime.now(),
      exists: device.exists,
      modified: device.modified,
    );
    for (final id in drop) {
      await device.delete(manifest[id]!);
      manifest.remove(id);
    }
    if (drop.isNotEmpty) await device.saveManifest(manifest);
    try {
      await repo.markUnavailable(expired);
    } catch (_) {}
  }

  /// Answers every upload an agent has asked this account for.
  Future<void> runPendingUploads() async {
    final uid = _profileId;
    if (uid == null || !voiceRecordingSupported || _uploading) return;
    _uploading = true;
    try {
      final repo = ref.read(voiceProtectionRepositoryProvider);
      final device = ref.read(voiceDeviceStoreProvider);
      final manifest = await device.manifest();
      for (final rec in await repo.pendingUploads(uid)) {
        final local = manifest[rec.id];
        switch (uploadActionFor(localPath: local, fileExists: local != null && device.exists(local))) {
          case UploadAction.upload:
            await repo.upload(rec, await device.read(local!), local);
          case UploadAction.markUnavailable:
            await repo.markUnavailable([rec.id]);
            manifest.remove(rec.id);
            await device.saveManifest(manifest);
          case UploadAction.ignore:
            break;
        }
      }
    } catch (_) {
      // Retried on the next request, launch or sign-in.
    } finally {
      _uploading = false;
    }
  }
}

final voiceProtectionProvider = NotifierProvider<VoiceProtectionController, VoiceProtectionState>(
  VoiceProtectionController.new,
);

/// Keeps VoiceProtection's background duties running for the signed-in
/// account: the purge on sign-in, and uploads the moment an agent asks
/// (realtime) or on launch. Phones only.
class VoiceProtectionHost extends ConsumerStatefulWidget {
  const VoiceProtectionHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<VoiceProtectionHost> createState() => _VoiceProtectionHostState();
}

class _VoiceProtectionHostState extends ConsumerState<VoiceProtectionHost> {
  String? _uid;
  Future<void> Function()? _unwatch;

  void _attach(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    final stop = _unwatch;
    _unwatch = null;
    if (stop != null) unawaited(stop());
    if (uid == null || !voiceRecordingSupported) return;
    final voice = ref.read(voiceProtectionProvider.notifier);
    unawaited(voice.purgeExpired().then((_) => voice.runPendingUploads()));
    _unwatch = ref.read(voiceProtectionRepositoryProvider).watch(uid, () => unawaited(voice.runPendingUploads()));
  }

  @override
  void dispose() {
    final stop = _unwatch;
    if (stop != null) unawaited(stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(voiceProtectionProvider); // keeps the controller alive
    _attach(ref.watch(currentUserIdProvider));
    return widget.child;
  }
}
