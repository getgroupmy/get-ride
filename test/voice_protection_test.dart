import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/widgets/trip_audio_panel.dart';
import 'package:get_ride/src/core/voice_protection.dart';
import 'package:get_ride/src/data/voice_protection_repository.dart';
import 'package:get_ride/src/features/safety/voice_protection_card.dart';
import 'package:get_ride/src/features/safety/voice_protection_controller.dart';
import 'package:get_ride/src/providers.dart';

const _me = '11111111-1111-1111-1111-111111111111';

class _FakeRecorder implements TripAudioRecorder {
  _FakeRecorder(this.device, {this.permission = true});
  final _FakeDevice device;
  final bool permission;
  String? recordingTo;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start(String path) async => recordingTo = path;

  @override
  Future<String?> stop() async {
    final p = recordingTo;
    if (p != null) device.files[p] = DateTime.now();
    recordingTo = null;
    return p;
  }
}

class _FakeDevice implements VoiceDeviceStore {
  final prefs = <String, bool>{};
  Map<String, String> stored = {};
  final files = <String, DateTime>{};
  final deleted = <String>[];

  @override
  Future<bool> enabled(String profileId) async => prefs[profileId] ?? false;

  @override
  Future<void> setEnabled(String profileId, bool value) async => prefs[profileId] = value;

  @override
  Future<Map<String, String>> manifest() async => {...stored};

  @override
  Future<void> saveManifest(Map<String, String> m) async => stored = {...m};

  @override
  Future<String> newRecordingPath(String id) async => '/private/voice-protection/$id.m4a';

  @override
  bool exists(String path) => files.containsKey(path);

  @override
  DateTime? modified(String path) => files[path];

  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList([1, 2, 3]);

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    deleted.add(path);
  }
}

class _FakeRepo implements VoiceProtectionRepository {
  final inserted = <Map<String, dynamic>>[];
  final unavailable = <String>[];
  final uploaded = <String>[];
  final requested = <(String, String?)>[];
  List<VoiceRecording> pending = [];
  List<VoiceRecording> recordings = [];
  Set<String> expired = {};
  void Function()? onChange;

  @override
  Future<void> insert(Map<String, dynamic> row) async => inserted.add(row);

  @override
  Future<Set<String>> expiredIds(String profileId, DateTime now) async => expired;

  @override
  Future<void> markUnavailable(Iterable<String> ids) async => unavailable.addAll(ids);

  @override
  Future<List<VoiceRecording>> pendingUploads(String profileId) async => pending;

  @override
  Future<void> upload(VoiceRecording rec, Uint8List bytes, String localPath) async => uploaded.add(rec.id);

  @override
  Future<void> Function() watch(String profileId, void Function() onChange) {
    this.onChange = onChange;
    return () async => this.onChange = null;
  }

  @override
  Future<List<VoiceRecording>> forProfile(String profileId) async => recordings;

  @override
  Future<void> requestUpload(String recordingId, {required String? adminId, String? ticketId}) async =>
      requested.add((recordingId, ticketId));

  @override
  Future<String> signedUrl(String mediaPath) async => 'https://example.test/$mediaPath';
}

VoiceRecording _rec(
  String id, {
  bool requested = false,
  bool uploaded = false,
  bool unavailable = false,
  Duration age = const Duration(hours: 1),
}) {
  final at = DateTime.now().subtract(age);
  return VoiceRecording(
    id: id,
    profileId: _me,
    rideLabel: 'KLCC → KLIA',
    recordedAt: at,
    expiresAt: at.add(voiceRetention),
    durationSec: 754,
    uploadRequested: requested,
    uploaded: uploaded,
    mediaUrl: uploaded ? '$_me/$id.m4a' : null,
    unavailable: unavailable,
  );
}

void main() {
  group('voice protection logic', () {
    test('row parsing and the new-recording row', () {
      final r = VoiceRecording.fromRow({
        'id': 'a',
        'profile_id': _me,
        'recorded_at': '2026-10-01T10:00:00Z',
        'duration_sec': '61',
        'upload_requested': true,
      });
      expect(r.expiresAt, DateTime.utc(2026, 10, 2, 10));
      expect(r.durationSec, 61);
      expect(r.uploadPending, isTrue);

      final row = newRecordingRow(
        id: 'b',
        profileId: _me,
        recordedAt: DateTime.utc(2026, 10, 1, 10),
        duration: const Duration(seconds: 90, milliseconds: 600),
        savedOnDevice: false,
        rideId: 'ride-1',
      );
      expect(row['duration_sec'], 91);
      expect(row['expires_at'], '2026-10-02T10:00:00.000Z');
      expect(row['unavailable'], isTrue);
    });

    test('which local files the purge deletes', () {
      final now = DateTime.utc(2026, 10, 2, 12);
      final files = {
        '/a.m4a': DateTime.utc(2026, 10, 2, 9), // fresh, row expired → delete
        '/b.m4a': DateTime.utc(2026, 10, 2, 9), // fresh → keep
        '/c.m4a': DateTime.utc(2026, 10, 1, 9), // older than 24 h → delete
      };
      final drop = expiredLocalRecordings(
        manifest: {'a': '/a.m4a', 'b': '/b.m4a', 'c': '/c.m4a', 'd': '/gone.m4a'},
        expiredIds: {'a'},
        now: now,
        exists: files.containsKey,
        modified: (p) => files[p],
      );
      expect(drop, {'a', 'c', 'd'});
    });

    test('only the phone that holds a recording answers for it', () {
      expect(uploadActionFor(localPath: '/x.m4a', fileExists: true), UploadAction.upload);
      expect(uploadActionFor(localPath: '/x.m4a', fileExists: false), UploadAction.markUnavailable);
      expect(uploadActionFor(localPath: null, fileExists: false), UploadAction.ignore);
    });

    test('storage path, content type, duration and agent states', () {
      expect(voiceStoragePath(_me, 'r1', '/data/r1.M4A'), '$_me/r1.m4a');
      expect(voiceStoragePath(_me, 'r1', '/data/r1'), '$_me/r1.m4a');
      expect(voiceContentType('/x.mp3'), 'audio/mpeg');
      expect(voiceContentType('/x.m4a'), 'audio/mp4');
      expect(formatRecordingDuration(754), '12:34');
      expect(formatRecordingDuration(-3), '0:00');
      final now = DateTime.now();
      expect(recordingState(_rec('a', uploaded: true), now), RecordingState.uploaded);
      expect(recordingState(_rec('a', unavailable: true), now), RecordingState.unavailable);
      expect(recordingState(_rec('a', age: const Duration(hours: 25)), now), RecordingState.expired);
      expect(recordingState(_rec('a', requested: true), now), RecordingState.waitingForDevice);
      expect(recordingState(_rec('a'), now), RecordingState.onDevice);
    });
  });

  group('controller', () {
    late _FakeDevice device;
    late _FakeRepo repo;
    late _FakeRecorder recorder;

    ProviderContainer make({bool permission = true, bool enabled = true}) {
      device = _FakeDevice()..prefs[_me] = enabled;
      repo = _FakeRepo();
      recorder = _FakeRecorder(device, permission: permission);
      final c = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue(_me),
          voiceDeviceStoreProvider.overrideWithValue(device),
          voiceProtectionRepositoryProvider.overrideWithValue(repo),
          tripAudioRecorderProvider.overrideWithValue(recorder),
        ],
      );
      addTearDown(c.dispose);
      c.listen(voiceProtectionProvider, (_, _) {});
      return c;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('records a trip only when switched on, and files it on stop', () async {
      final c = make();
      await settle();
      final voice = c.read(voiceProtectionProvider.notifier);
      expect(c.read(voiceProtectionProvider).enabled, isTrue);

      await voice.startTrip(rideId: 'ride-1', label: 'A → B');
      await voice.startTrip(rideId: 'ride-1', label: 'A → B'); // second ask is a no-op
      expect(c.read(voiceProtectionProvider).recording, isTrue);
      expect(recorder.recordingTo, startsWith('/private/voice-protection/'));

      await voice.stopTrip();
      expect(c.read(voiceProtectionProvider).recording, isFalse);
      final row = repo.inserted.single;
      expect(row['ride_id'], 'ride-1');
      expect(row['ride_label'], 'A → B');
      expect(row['unavailable'], isFalse);
      expect(device.stored[row['id']], startsWith('/private/voice-protection/'));

      await voice.stopTrip(); // nothing left to file
      expect(repo.inserted, hasLength(1));
    });

    test('off means no recording; no microphone says why', () async {
      final off = make(enabled: false);
      await settle();
      await off.read(voiceProtectionProvider.notifier).startTrip(rideId: 'r');
      expect(recorder.recordingTo, isNull);

      final noMic = make(permission: false);
      await settle();
      await noMic.read(voiceProtectionProvider.notifier).startTrip(rideId: 'r');
      expect(noMic.read(voiceProtectionProvider).recording, isFalse);
      expect(noMic.read(voiceProtectionProvider).error, contains('Microphone'));
    });

    test('answers upload requests for the recordings this phone holds', () async {
      final c = make();
      await settle();
      device.stored = {'held': '/p/held.m4a', 'lost': '/p/lost.m4a'};
      device.files['/p/held.m4a'] = DateTime.now();
      repo.pending = [_rec('held', requested: true), _rec('lost', requested: true), _rec('other', requested: true)];

      await c.read(voiceProtectionProvider.notifier).runPendingUploads();
      expect(repo.uploaded, ['held']);
      expect(repo.unavailable, ['lost']);
      expect(device.stored.keys, ['held']);
    });

    test('purge deletes expired files and tells agents', () async {
      final c = make();
      await settle();
      device.stored = {'old': '/p/old.m4a', 'new': '/p/new.m4a'};
      device.files['/p/old.m4a'] = DateTime.now();
      device.files['/p/new.m4a'] = DateTime.now();
      repo.expired = {'old', 'elsewhere'};

      await c.read(voiceProtectionProvider.notifier).purgeExpired();
      expect(device.deleted, ['/p/old.m4a']);
      expect(device.stored.keys, ['new']);
      expect(repo.unavailable, unorderedEquals(['old', 'elsewhere']));
    });
  });

  group('screens', () {
    testWidgets('the settings switch is remembered per account', (tester) async {
      final device = _FakeDevice();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue(_me),
            voiceDeviceStoreProvider.overrideWithValue(device),
            voiceProtectionRepositoryProvider.overrideWithValue(_FakeRepo()),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: VoiceProtectionCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sw = find.byKey(const ValueKey('voice-protection-switch'));
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sw).value, isTrue);
      expect(device.prefs[_me], isTrue);
    });

    testWidgets('an agent requests a recording and sees each state', (tester) async {
      final repo = _FakeRepo()
        ..recordings = [
          _rec('a'),
          _rec('b', uploaded: true),
          _rec('c', requested: true),
          _rec('d', age: const Duration(hours: 30)),
        ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('admin-1'),
            voiceProtectionRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: TripAudioPanel(profileId: _me, ticketId: 't1', canEdit: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('4 recordings'), findsOneWidget);
      await tester.tap(find.text('Trip audio (VoiceProtection)'));
      await tester.pumpAndSettle();
      expect(find.textContaining("On the user's phone"), findsOneWidget);
      expect(find.textContaining('Uploaded'), findsOneWidget);
      expect(find.textContaining('waiting for the user'), findsOneWidget);
      expect(find.textContaining('Deleted from the phone'), findsOneWidget);
      expect(find.textContaining('12:34'), findsNWidgets(4));
      expect(find.text('Play'), findsOneWidget);

      await tester.tap(find.text('Request'));
      await tester.pumpAndSettle();
      expect(repo.requested, [('a', 't1')]);
    });

    testWidgets('read-only agents cannot request', (tester) async {
      final repo = _FakeRepo()..recordings = [_rec('a')];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [voiceProtectionRepositoryProvider.overrideWithValue(repo)],
          child: const MaterialApp(
            home: Scaffold(
              body: TripAudioPanel(profileId: _me, ticketId: 't1', canEdit: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trip audio (VoiceProtection)'));
      await tester.pumpAndSettle();
      expect(find.text('Request'), findsNothing);
    });
  });
}
