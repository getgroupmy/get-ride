import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/rider_audio.dart';
import '../../core/trip_audio_cipher.dart' show TripAudioCipherException;
import '../../data/models.dart';
import '../../data/rider_audio_repository.dart';
import '../../data/voice_protection_repository.dart';
import '../../providers.dart';
import '../ride/ride_tracking_screen.dart' show rideStreamProvider;

class RiderAudioState {
  const RiderAudioState({this.enabled = false, this.loaded = false, this.recordingRideId, this.error});

  /// The rider's switch (off until they turn it on; remembered per account).
  final bool enabled;
  final bool loaded;

  /// The ride being recorded right now (drives the on-trip line).
  final String? recordingRideId;

  /// Why the last recording could not start (shown on the ride screen).
  final String? error;

  bool get recording => recordingRideId != null;

  RiderAudioState copyWith({bool? enabled, bool? loaded, String? Function()? recordingRideId, String? error}) =>
      RiderAudioState(
        enabled: enabled ?? this.enabled,
        loaded: loaded ?? this.loaded,
        recordingRideId: recordingRideId == null ? this.recordingRideId : recordingRideId(),
        error: error,
      );
}

/// Rider audio protection on this phone (migration 0315): the rider's
/// switch, telling the server (so the driver is told), the trip recorder,
/// the purge after the admin's hours, and the uploads an agent asks for.
/// Recordings are never played back here; the only way out for the audio
/// is an agent's request.
class RiderAudioController extends Notifier<RiderAudioState> {
  String? _profileId;
  String? _path;
  String? _recordingId;
  DateTime? _startedAt;
  ({String rideId, String? label, int keepHours})? _ride;
  bool _uploading = false;

  /// Rides already asked to say "on" (once each, so a refusal isn't retried
  /// on every update of the ride).
  final _marked = <String>{};

  /// The last ride under way seen here, to turn off when the switch goes off.
  String? _lastRideId;

  @override
  RiderAudioState build() {
    // Signed out, or no backend yet (a screen built before it is set up).
    String? uid;
    try {
      uid = ref.watch(currentUserIdProvider);
    } catch (_) {}
    _profileId = uid;
    if (uid != null) unawaited(_load(uid));
    return RiderAudioState(loaded: uid == null);
  }

  Future<void> _load(String uid) async {
    var on = false;
    try {
      on = await ref.read(riderAudioDeviceStoreProvider).enabled(uid);
    } catch (_) {}
    if (_profileId == uid && ref.mounted) state = state.copyWith(enabled: on, loaded: true);
  }

  Future<void> setEnabled(bool value) async {
    final uid = _profileId;
    if (uid == null) return;
    state = state.copyWith(enabled: value);
    await ref.read(riderAudioDeviceStoreProvider).setEnabled(uid, value);
    if (!value) {
      await stopRide();
      final ride = _lastRideId;
      if (ride != null) {
        _marked.remove(ride);
        try {
          await ref.read(riderAudioRepositoryProvider).setRideAudio(ride, false);
        } catch (_) {}
      }
    }
  }

  /// The rider's ride as it is now (the ride screen calls this on every
  /// update): tells the server the switch is on, and records from Start trip
  /// to the end. A ride booked for someone else, Freight and Courier are not
  /// recorded: the phone's owner isn't in the car.
  Future<void> onRide(RideRequest r) async {
    if (!ref.mounted || r.id.startsWith('demo') || r.riderId == null || r.riderId != _profileId) return;
    final mine = r.bookedForName == null && !r.isFreight;
    if (r.status.isOngoing) _lastRideId = r.id;
    if (state.recordingRideId == r.id && (r.status.isFinished || !r.riderAudio || !state.enabled)) {
      await stopRide();
      return;
    }
    if (!mine) return;
    if (riderShouldMarkRide(
      switchOn: state.enabled && riderAudioSupported,
      rideSaysOn: r.riderAudio,
      rideUnderWay: r.status.isOngoing,
      offered: !_marked.contains(r.id),
    )) {
      _marked.add(r.id);
      try {
        await ref.read(riderAudioRepositoryProvider).setRideAudio(r.id, true);
      } catch (_) {
        // Not offered at this pickup: the ride stays off and nothing records.
      }
      return; // the ride's own update brings the change
    }
    if (riderShouldRecord(
      switchOn: state.enabled,
      rideSaysOn: r.riderAudio,
      onTrip: r.status == RideStatus.onTrip,
      supported: riderAudioSupported,
    )) {
      await startRide(r);
    }
  }

  /// Starts recording [r]. Asking again while recording is a no-op.
  Future<void> startRide(RideRequest r) async {
    final uid = _profileId;
    if (!state.enabled || uid == null || _recordingId != null || !riderAudioSupported) return;
    final id = const Uuid().v4();
    _recordingId = id; // claimed before the first await, so a second call is a no-op
    final recorder = ref.read(riderAudioRecorderProvider);
    try {
      if (!await recorder.hasPermission()) {
        _recordingId = null;
        if (ref.mounted) state = state.copyWith(error: 'Microphone access is off, so this trip is not being recorded.');
        return;
      }
      var keep = riderAudioDefaultHours;
      final lat = r.pickupLat, lng = r.pickupLng;
      if (lat != null && lng != null) {
        try {
          final at = await ref.read(riderAudioRepositoryProvider).at(
            lat: lat,
            lng: lng,
            country: r.raw['country'] as String?,
            state: r.raw['state'] as String?,
            city: r.raw['city'] as String?,
          );
          keep = at.keepHours;
        } catch (_) {}
      }
      final path = await ref.read(riderAudioDeviceStoreProvider).newRecordingPath(id);
      await recorder.start(path);
      _path = path;
      _startedAt = DateTime.now();
      _ride = (rideId: r.id, label: '${r.pickupLabel} to ${r.dropLabel}', keepHours: keep);
      if (ref.mounted) state = state.copyWith(recordingRideId: () => r.id);
    } catch (_) {
      _recordingId = null;
      if (ref.mounted) state = state.copyWith(recordingRideId: () => null, error: 'Trip recording could not start.');
    }
  }

  /// Stops the recording (if any), encrypts and files it and writes its row.
  Future<void> stopRide() async {
    if (!ref.mounted) return;
    final id = _recordingId;
    final uid = _profileId;
    final startedAt = _startedAt;
    final ride = _ride;
    _recordingId = null;
    _startedAt = null;
    _ride = null;
    state = state.copyWith(recordingRideId: () => null);
    if (id == null || uid == null || startedAt == null || ride == null) return;
    final device = ref.read(riderAudioDeviceStoreProvider);
    String? file;
    try {
      file = await ref.read(riderAudioRecorderProvider).stop() ?? _path;
    } catch (_) {
      file = _path;
    }
    _path = null;
    var saved = false;
    if (file != null && device.exists(file)) {
      try {
        final local = await device.seal(id, file, startedAt.add(Duration(hours: ride.keepHours)));
        final m = await device.manifest();
        m[id] = local;
        await device.saveManifest(m);
        saved = true;
      } catch (_) {
        await device.delete(file);
      }
    }
    try {
      await ref
          .read(voiceProtectionRepositoryProvider)
          .insert(
            newRiderRecordingRow(
              id: id,
              profileId: uid,
              rideId: ride.rideId,
              recordedAt: startedAt,
              duration: DateTime.now().difference(startedAt),
              savedOnDevice: saved,
              keepHours: ride.keepHours,
              rideLabel: ride.label,
            ),
          );
    } catch (_) {
      // Without its row no agent can ask for it; the purge still deletes it.
    }
  }

  /// Deletes recordings past their hours and tells agents they are gone.
  Future<void> purgeExpired() async {
    final uid = _profileId;
    if (uid == null || !riderAudioSupported) return;
    final device = ref.read(riderAudioDeviceStoreProvider);
    final repo = ref.read(voiceProtectionRepositoryProvider);
    try {
      await device.migrateKeys();
      final manifest = await device.manifest();
      var expired = <String>{};
      try {
        expired = await repo.expiredIds(uid, DateTime.now());
      } catch (_) {}
      final drop = expiredRiderRecordings(
        manifest: manifest,
        expiredIds: expired,
        now: DateTime.now(),
        exists: device.exists,
      );
      for (final id in drop) {
        await device.delete(manifest[id]!.path, id: id);
        manifest.remove(id);
      }
      if (drop.isNotEmpty) await device.saveManifest(manifest);
      await repo.markUnavailable(drop.intersection(expired));
    } catch (_) {
      // Tried again on the next launch or sign-in.
    }
  }

  /// Answers every upload an agent has asked of this rider's recordings.
  Future<void> runPendingUploads() async {
    final uid = _profileId;
    if (uid == null || !riderAudioSupported || _uploading) return;
    _uploading = true;
    try {
      final repo = ref.read(voiceProtectionRepositoryProvider);
      final device = ref.read(riderAudioDeviceStoreProvider);
      final manifest = await device.manifest();
      for (final rec in await repo.pendingUploads(uid)) {
        if (!rec.byRider) continue;
        final local = manifest[rec.id];
        if (local == null) continue; // recorded on another phone
        Uint8List? bytes;
        if (device.exists(local.path)) {
          try {
            bytes = await device.open(rec.id, local);
          } on TripAudioCipherException {
            // Its key is gone or the file was changed: it can't be sent.
          }
        }
        if (bytes == null) {
          await repo.markUnavailable([rec.id]);
          await device.delete(local.path, id: rec.id);
          manifest.remove(rec.id);
          await device.saveManifest(manifest);
          continue;
        }
        await repo.upload(rec, bytes, riderUploadName(rec.id));
      }
    } catch (_) {
      // Retried on the next request, launch or sign-in.
    } finally {
      _uploading = false;
    }
  }
}

/// The name an upload goes under in the bucket: always AAC in an .m4a.
String riderUploadName(String id) => '$id.m4a';

final riderAudioProvider = NotifierProvider<RiderAudioController, RiderAudioState>(RiderAudioController.new);

/// Keeps a rider's recording going until its ride ends, wherever the app is
/// (the ride screen may be closed): stops it when the ride finishes or says
/// audio protection is off.
class RiderAudioHost extends ConsumerWidget {
  const RiderAudioHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(riderAudioProvider.select((s) => s.recordingRideId));
    if (id != null) {
      ref.listen(rideStreamProvider(id), (_, next) {
        final r = next.value;
        if (r != null) unawaited(ref.read(riderAudioProvider.notifier).onRide(r));
      });
    }
    return child;
  }
}
