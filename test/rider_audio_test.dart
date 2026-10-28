// Rider audio protection (migration 0315): the place rule (the twin of
// supabase/tests/rider_audio_0315.sql), the encrypted file, the controller
// (marking the ride, recording from Start trip to the end, the row, the
// purge and the uploads), the rider's and the driver's lines, the trip
// audio panel on a ride and the admin page, in light and dark.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/rider_audio/rider_audio_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/admin/widgets/trip_audio_panel.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/rider_audio.dart';
import 'package:get_ride/src/core/voice_protection.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/rider_audio_repository.dart';
import 'package:get_ride/src/data/voice_protection_repository.dart';
import 'package:get_ride/src/features/safety/rider_audio_controller.dart';
import 'package:get_ride/src/features/safety/rider_audio_widgets.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

const _me = '22222222-2222-2222-2222-222222222222';
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _land = 'Audioland';
const _country = RegionScope(country: _land);
const _hush = RegionScope(country: _land, state: 'Hushstate');
const _loud = RegionScope(country: _land, state: 'Hushstate', city: 'Loudtown');
const _open = RegionScope(country: _land, state: 'Openstate');

final _rules = RiderAudioRules(const [
  RiderAudioRule(id: 'd', enabled: true, keepHours: 24),
  RiderAudioRule(id: 'c', scope: _country, keepHours: 48),
  RiderAudioRule(id: 's', scope: _hush, enabled: false),
  RiderAudioRule(id: 't', scope: _loud, enabled: true, keepHours: 6),
]);

RideRequest _ride(
  String status, {
  String id = 'ride-1',
  bool audio = false,
  String? forName,
  String rider = _me,
  String? cargo,
}) => RideRequest({
  'id': id,
  'rider_id': rider,
  'status': status,
  'rider_audio': audio,
  'pickup_lat': 3.1,
  'pickup_lng': 101.6,
  'pickup_name': 'KLCC',
  'drop_name': 'KLIA',
  'booked_for_name': ?forName,
  'cargo_description': ?cargo,
});

class _Recorder implements TripAudioRecorder {
  _Recorder(this.device, {this.permission = true});
  final _Device device;
  final bool permission;
  String? to;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start(String path) async => to = path;

  @override
  Future<String?> stop() async {
    final p = to;
    if (p != null) device.files.add(p);
    to = null;
    return p;
  }
}

class _Device implements RiderAudioDeviceStore {
  final prefs = <String, bool>{};
  Map<String, RiderAudioLocal> stored = {};
  final files = <String>{};
  final deleted = <String>[];

  @override
  Future<bool> enabled(String profileId) async => prefs[profileId] ?? false;

  @override
  Future<void> setEnabled(String profileId, bool value) async => prefs[profileId] = value;

  @override
  Future<Map<String, RiderAudioLocal>> manifest() async => {...stored};

  @override
  Future<void> saveManifest(Map<String, RiderAudioLocal> m) async => stored = {...m};

  @override
  Future<String> newRecordingPath(String id) async => '/private/rider-audio/$id.m4a';

  @override
  Future<RiderAudioLocal> seal(String id, String rawPath, DateTime expiresAt) async {
    files.remove(rawPath);
    final out = '/private/rider-audio/$id.enc';
    files.add(out);
    return RiderAudioLocal(path: out, key: Uint8List(32), nonce: Uint8List(16), expiresAt: expiresAt);
  }

  @override
  Future<Uint8List> open(RiderAudioLocal local) async => Uint8List.fromList([1, 2, 3]);

  @override
  bool exists(String path) => files.contains(path);

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    deleted.add(path);
  }
}

class _AudioRepo extends RiderAudioRepository {
  _AudioRepo() : super(_db);

  RiderAudioAt here = const RiderAudioAt(keepHours: 6);
  RiderAudioRules stored = _rules;
  final marked = <(String, bool)>[];
  final saved = <RiderAudioRule>[];
  final deleted = <String>[];
  bool refuse = false;

  @override
  Future<RiderAudioAt> at({required double lat, required double lng, String? country, String? state, String? city}) async =>
      here;

  @override
  Future<bool> setRideAudio(String rideId, bool on) async {
    if (refuse && on) throw Exception('RIDER_AUDIO_OFF_HERE');
    marked.add((rideId, on));
    return on;
  }

  @override
  Future<RiderAudioRules> rules() async => stored;

  @override
  Future<void> saveRule(RiderAudioRule r) async => saved.add(r);

  @override
  Future<void> deleteRule(String id) async => deleted.add(id);
}

class _VoiceRepo implements VoiceProtectionRepository {
  final inserted = <Map<String, dynamic>>[];
  final unavailable = <String>[];
  final uploaded = <(String, String)>[];
  final requested = <String>[];
  List<VoiceRecording> pending = [];
  List<VoiceRecording> recordings = [];
  Set<String> expired = {};

  @override
  Future<void> insert(Map<String, dynamic> row) async => inserted.add(row);

  @override
  Future<Set<String>> expiredIds(String profileId, DateTime now) async => expired;

  @override
  Future<void> markUnavailable(Iterable<String> ids) async => unavailable.addAll(ids);

  @override
  Future<List<VoiceRecording>> pendingUploads(String profileId) async => pending;

  @override
  Future<void> upload(VoiceRecording rec, Uint8List bytes, String localPath) async =>
      uploaded.add((rec.id, voiceStoragePath(rec.profileId, rec.id, localPath)));

  @override
  Future<void> Function() watch(String profileId, void Function() onChange) => () async {};

  @override
  Future<void> Function() watchRide(String rideId, void Function() onChange) => () async {};

  @override
  Future<List<VoiceRecording>> forProfile(String profileId) async => recordings;

  @override
  Future<List<VoiceRecording>> forRide(String rideId) async => recordings;

  @override
  Future<void> requestUpload(String recordingId, {required String? adminId, String? ticketId}) async =>
      requested.add(recordingId);

  @override
  Future<String> signedUrl(String mediaPath) async => 'https://example.test/$mediaPath';
}

VoiceRecording _rec(String id, {String by = 'rider', bool requested = false, bool uploaded = false}) {
  final at = DateTime.now().subtract(const Duration(hours: 1));
  return VoiceRecording(
    id: id,
    profileId: _me,
    rideId: 'ride-1',
    rideLabel: 'KLCC to KLIA',
    recordedAt: at,
    expiresAt: at.add(const Duration(hours: 6)),
    durationSec: 90,
    uploadRequested: requested,
    uploaded: uploaded,
    mediaUrl: uploaded ? '$_me/$id.m4a' : null,
    recordedBy: by,
  );
}

void main() {
  group('the rule by place', () {
    test('the smallest place that sets a part decides it (as the SQL test)', () {
      expect(_rules.at(const RegionScope(country: 'Nowhere')), const RiderAudioAt());
      expect(_rules.at(_open), const RiderAudioAt(keepHours: 48));
      expect(_rules.at(_hush), const RiderAudioAt(enabled: false, keepHours: 48));
      expect(_rules.at(_loud), const RiderAudioAt(keepHours: 6));
      expect(_rules.at(const RegionScope(country: ' audioland ', state: 'HUSHSTATE')).enabled, isFalse);
      final from = _rules.from(_hush);
      expect(from.enabledFrom, _hush);
      expect(from.hoursFrom, _country);
      expect(const RiderAudioRules([]).at(_loud), const RiderAudioAt());
    });

    test('rows, the server answer and the wording', () {
      final r = RiderAudioRule.fromRow({
        'id': 'x',
        'level': 'city',
        'country': _land,
        'state': 'Hushstate',
        'city': 'Loudtown',
        'enabled': null,
        'keep_hours': 500,
      });
      expect(r.scope, _loud);
      expect(r.enabled, isNull);
      expect(r.keepHours, riderAudioMaxHours);
      expect(r.toRow(), {
        'level': 'city',
        'country': _land,
        'state': 'Hushstate',
        'city': 'Loudtown',
        'suburb': null,
        'enabled': null,
        'keep_hours': 168,
      });
      expect(RiderAudioRule.fromRow({'level': 'default', 'enabled': true, 'keep_hours': 24}).isDefault, isTrue);
      expect(RiderAudioAt.fromJson({'enabled': false, 'keepHours': 0}), const RiderAudioAt(enabled: false, keepHours: 1));
      expect(RiderAudioAt.fromJson(null), RiderAudioAt.fallback);
      expect(keepHoursLabel(24), '24 h');
      expect(keepHoursLabel(72), '3 days');
      expect(keepHoursLabel(30), '30 h');
      expect(riderAudioSummary(const RiderAudioAt()), contains('kept 24 h, never played in the app'));
      expect(riderAudioSummary(const RiderAudioAt(enabled: false)), 'Not offered here');
      expect(riderAudioConsent(const RiderAudioAt(keepHours: 48)), contains('2 days'));
      expect(riderAudioConsent(const RiderAudioAt()), contains('Your driver sees'));
      expect(stepKeepHours(24, up: true), 30);
      expect(stepKeepHours(24, up: false), 23);
      expect(stepKeepHours(30, up: false), 24);
      expect(stepKeepHours(1, up: false), 1);
      expect(stepKeepHours(168, up: true), 168);
    });

    test('when the phone marks a ride and when it records', () {
      expect(riderShouldMarkRide(switchOn: true, rideSaysOn: false, rideUnderWay: true, offered: true), isTrue);
      expect(riderShouldMarkRide(switchOn: true, rideSaysOn: true, rideUnderWay: true, offered: true), isFalse);
      expect(riderShouldMarkRide(switchOn: false, rideSaysOn: false, rideUnderWay: true, offered: true), isFalse);
      expect(riderShouldMarkRide(switchOn: true, rideSaysOn: false, rideUnderWay: false, offered: true), isFalse);
      expect(riderShouldRecord(switchOn: true, rideSaysOn: true, onTrip: true, supported: true), isTrue);
      expect(riderShouldRecord(switchOn: true, rideSaysOn: false, onTrip: true, supported: true), isFalse,
          reason: 'the driver has not been told');
      expect(riderShouldRecord(switchOn: true, rideSaysOn: true, onTrip: false, supported: true), isFalse);
      expect(riderShouldRecord(switchOn: true, rideSaysOn: true, onTrip: true, supported: false), isFalse);
    });

    test('the recording row', () {
      final row = newRiderRecordingRow(
        id: 'a',
        profileId: _me,
        rideId: 'ride-1',
        recordedAt: DateTime.utc(2026, 10, 1, 10),
        duration: const Duration(seconds: 90, milliseconds: 600),
        savedOnDevice: true,
        keepHours: 6,
        rideLabel: 'KLCC to KLIA',
      );
      expect(row['recorded_by'], 'rider');
      expect(row['duration_sec'], 91);
      expect(row['expires_at'], '2026-10-01T16:00:00.000Z');
      expect(row['unavailable'], isFalse);
      expect(VoiceRecording.fromRow({'id': 'a', 'recorded_by': 'rider'}).byRider, isTrue);
      expect(VoiceRecording.fromRow({'id': 'a'}).byRider, isFalse);
    });
  });

  group('on the phone', () {
    test('the file is encrypted, and only its key opens it', () {
      final key = riderAudioRandomBytes(32);
      final nonce = riderAudioRandomBytes(16);
      final plain = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
      final sealed = riderAudioCipher(key, nonce, plain);
      expect(sealed, isNot(plain));
      expect(sealed.length, plain.length);
      expect(riderAudioCipher(key, nonce, sealed), plain);
      expect(riderAudioCipher(riderAudioRandomBytes(32), nonce, sealed), isNot(plain));
      expect(riderAudioCipher(key, riderAudioRandomBytes(16), sealed), isNot(plain));
      expect(riderAudioCipher(key, nonce, Uint8List(0)), isEmpty);
    });

    test('the manifest keeps each file, key and time', () {
      final l = RiderAudioLocal(
        path: '/p/a.enc',
        key: Uint8List.fromList([1, 2]),
        nonce: Uint8List.fromList([3]),
        expiresAt: DateTime.utc(2026, 10, 2),
      );
      final back = decodeRiderManifest(encodeRiderManifest({'a': l}));
      expect(back['a']!.path, '/p/a.enc');
      expect(back['a']!.key, [1, 2]);
      expect(back['a']!.expiresAt, DateTime.utc(2026, 10, 2));
      expect(decodeRiderManifest('not json'), isEmpty);
      expect(decodeRiderManifest('{"a": {"path": 1}}'), isEmpty);
    });

    test('which recordings the purge deletes', () {
      final now = DateTime.utc(2026, 10, 2, 12);
      RiderAudioLocal at(String p, DateTime e) => RiderAudioLocal(path: p, key: Uint8List(1), nonce: Uint8List(1), expiresAt: e);
      final drop = expiredRiderRecordings(
        manifest: {
          'a': at('/a', DateTime.utc(2026, 10, 3)), // row expired on the server
          'b': at('/b', DateTime.utc(2026, 10, 3)), // keep
          'c': at('/c', DateTime.utc(2026, 10, 2, 11)), // its own time is up
          'd': at('/gone', DateTime.utc(2026, 10, 3)), // file gone
        },
        expiredIds: {'a'},
        now: now,
        exists: (p) => p != '/gone',
      );
      expect(drop, {'a', 'c', 'd'});
    });
  });

  group('controller', () {
    late _Device device;
    late _AudioRepo audio;
    late _VoiceRepo voice;
    late _Recorder recorder;

    ProviderContainer make({bool enabled = true, bool permission = true}) {
      device = _Device()..prefs[_me] = enabled;
      audio = _AudioRepo();
      voice = _VoiceRepo();
      recorder = _Recorder(device, permission: permission);
      final c = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue(_me),
          riderAudioDeviceStoreProvider.overrideWithValue(device),
          riderAudioRepositoryProvider.overrideWithValue(audio),
          voiceProtectionRepositoryProvider.overrideWithValue(voice),
          riderAudioRecorderProvider.overrideWithValue(recorder),
        ],
      );
      addTearDown(c.dispose);
      c.listen(riderAudioProvider, (_, _) {});
      return c;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('marks the ride, records from Start trip to the end and files it encrypted', () async {
      final c = make();
      await settle();
      final ctl = c.read(riderAudioProvider.notifier);
      expect(c.read(riderAudioProvider).enabled, isTrue);

      await ctl.onRide(_ride('accepted'));
      expect(audio.marked, [('ride-1', true)], reason: 'the driver is told');
      await ctl.onRide(_ride('accepted'));
      expect(audio.marked, hasLength(1), reason: 'once a ride');
      expect(recorder.to, isNull, reason: 'not before the trip starts');

      await ctl.onRide(_ride('on_trip', audio: true));
      await ctl.onRide(_ride('on_trip', audio: true)); // a second update is a no-op
      expect(c.read(riderAudioProvider).recordingRideId, 'ride-1');
      expect(recorder.to, startsWith('/private/rider-audio/'));

      await ctl.onRide(_ride('completed', audio: true));
      expect(c.read(riderAudioProvider).recording, isFalse);
      final row = voice.inserted.single;
      expect(row['recorded_by'], 'rider');
      expect(row['ride_id'], 'ride-1');
      expect(row['ride_label'], 'KLCC to KLIA');
      expect(row['unavailable'], isFalse);
      expect(device.stored[row['id']]!.path, endsWith('.enc'));
      expect(device.files.where((f) => f.endsWith('.m4a')), isEmpty, reason: 'the plain file is gone');
      final recordedAt = DateTime.parse(row['recorded_at'] as String);
      expect(DateTime.parse(row['expires_at'] as String).difference(recordedAt), const Duration(hours: 6));
    });

    test('off, someone else riding, a parcel, or a refusal: nothing records', () async {
      final off = make(enabled: false);
      await settle();
      await off.read(riderAudioProvider.notifier).onRide(_ride('on_trip', audio: true));
      expect(recorder.to, isNull);
      expect(audio.marked, isEmpty);

      final c = make();
      await settle();
      final ctl = c.read(riderAudioProvider.notifier);
      await ctl.onRide(_ride('on_trip', audio: true, forName: 'Mum'));
      await ctl.onRide(_ride('on_trip', id: 'parcel', audio: true, cargo: 'Box'));
      await ctl.onRide(_ride('on_trip', id: 'theirs', audio: true, rider: 'someone-else'));
      expect(recorder.to, isNull);

      audio.refuse = true;
      await ctl.onRide(_ride('accepted', id: 'ride-2'));
      await ctl.onRide(_ride('on_trip', id: 'ride-2'));
      expect(recorder.to, isNull, reason: 'the ride still says off');
    });

    test('no microphone says why; turning it off stops and tells the server', () async {
      final noMic = make(permission: false);
      await settle();
      await noMic.read(riderAudioProvider.notifier).onRide(_ride('on_trip', audio: true));
      expect(noMic.read(riderAudioProvider).error, contains('Microphone'));

      final c = make();
      await settle();
      final ctl = c.read(riderAudioProvider.notifier);
      await ctl.onRide(_ride('on_trip', audio: true));
      expect(c.read(riderAudioProvider).recording, isTrue);
      await ctl.setEnabled(false);
      expect(c.read(riderAudioProvider).recording, isFalse);
      expect(voice.inserted, hasLength(1));
      expect(audio.marked.last, ('ride-1', false));
      expect(device.prefs[_me], isFalse);
    });

    test('answers requests for the rider recordings this phone holds', () async {
      final c = make();
      await settle();
      RiderAudioLocal l(String p) => RiderAudioLocal(path: p, key: Uint8List(1), nonce: Uint8List(1), expiresAt: DateTime(2100));
      device.stored = {'held': l('/p/held.enc'), 'lost': l('/p/lost.enc')};
      device.files.add('/p/held.enc');
      voice.pending = [
        _rec('held', requested: true),
        _rec('lost', requested: true),
        _rec('other', requested: true),
        _rec('drv', by: 'driver', requested: true),
      ];
      await c.read(riderAudioProvider.notifier).runPendingUploads();
      expect(voice.uploaded, [('held', '$_me/held.m4a')]);
      expect(voice.unavailable, ['lost']);
      expect(device.stored.keys, ['held']);
    });

    test('the purge deletes what is past its hours', () async {
      final c = make();
      await settle();
      RiderAudioLocal l(String p, DateTime e) => RiderAudioLocal(path: p, key: Uint8List(1), nonce: Uint8List(1), expiresAt: e);
      device.stored = {
        'old': l('/p/old.enc', DateTime.now().subtract(const Duration(minutes: 1))),
        'new': l('/p/new.enc', DateTime.now().add(const Duration(hours: 1))),
        'srv': l('/p/srv.enc', DateTime.now().add(const Duration(hours: 1))),
      };
      device.files.addAll(['/p/old.enc', '/p/new.enc', '/p/srv.enc']);
      voice.expired = {'srv'};
      await c.read(riderAudioProvider.notifier).purgeExpired();
      expect(device.deleted, unorderedEquals(['/p/old.enc', '/p/srv.enc']));
      expect(device.stored.keys, ['new']);
      expect(voice.unavailable, ['srv']);
    });
  });

  group('screens', () {
    Future<(_Device, _AudioRepo, _VoiceRepo)> pump(
      WidgetTester tester,
      Widget child, {
      Brightness b = Brightness.light,
      bool canEdit = true,
      bool enabled = false,
      RiderAudioAt here = const RiderAudioAt(),
      List<VoiceRecording> recordings = const [],
    }) async {
      final device = _Device()..prefs[_me] = enabled;
      final audio = _AudioRepo()..here = here;
      final voice = _VoiceRepo()..recordings = recordings;
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            ...quietLiveOverrides,
            currentUserIdProvider.overrideWithValue(_me),
            pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
            riderAudioDeviceStoreProvider.overrideWithValue(device),
            riderAudioRepositoryProvider.overrideWithValue(audio),
            voiceProtectionRepositoryProvider.overrideWithValue(voice),
            riderAudioRecorderProvider.overrideWithValue(_Recorder(device)),
          ],
          child: MaterialApp(theme: appTheme(b), home: Scaffold(body: SingleChildScrollView(child: child))),
        ),
      );
      await tester.pumpAndSettle();
      return (device, audio, voice);
    }

    for (final b in Brightness.values) {
      testWidgets('booking row: consent, then on and remembered (${b.name})', (tester) async {
        final (device, _, _) = await pump(tester, const RiderAudioConfirmRow(lat: 3.1, lng: 101.6), b: b);
        expect(find.text('Audio protection'), findsOneWidget);
        expect(find.textContaining('kept 24 h, never played in the app'), findsOneWidget);
        final sw = find.byKey(const ValueKey('rider-audio-switch'));
        expect(tester.widget<Switch>(find.descendant(of: sw, matching: find.byType(Switch))).value, isFalse);

        await tester.tap(find.descendant(of: sw, matching: find.byType(Switch)));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('rider-audio-consent')), findsOneWidget);
        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();
        expect(device.prefs[_me], isFalse);

        await tester.tap(find.descendant(of: sw, matching: find.byType(Switch)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('rider-audio-consent-on')));
        await tester.pumpAndSettle();
        expect(device.prefs[_me], isTrue);
        expect(tester.widget<Switch>(find.descendant(of: sw, matching: find.byType(Switch))).value, isTrue);
      });
    }

    testWidgets('booking row: none where it is not offered', (tester) async {
      await pump(tester, const RiderAudioConfirmRow(lat: 3.1, lng: 101.6), here: const RiderAudioAt(enabled: false));
      expect(find.byKey(const ValueKey('rider-audio-row')), findsNothing);
    });

    testWidgets('the Safety card says what it means', (tester) async {
      await pump(tester, const RiderAudioCard(), b: Brightness.dark, enabled: true);
      expect(find.text('Audio protection'), findsOneWidget);
      expect(find.textContaining('never playable in the app'), findsOneWidget);
      expect(find.textContaining('Your driver sees'), findsOneWidget);
      expect(find.byKey(const ValueKey('rider-audio-privacy-link')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rider-audio-safety-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rider-audio-consent')), findsNothing, reason: 'turning off asks nothing');
    });

    for (final b in Brightness.values) {
      testWidgets('the driver sees "Audio protection on (rider)" (${b.name})', (tester) async {
        await pump(tester, Column(children: [
          RiderAudioDriverLine(ride: _ride('on_trip', audio: true)),
          RiderAudioDriverLine(ride: _ride('on_trip', id: 'quiet')),
        ]), b: b);
        expect(find.text('Audio protection on (rider)'), findsOneWidget);
      });
    }

    testWidgets("a ride's trip audio: whose phone, request and play", (tester) async {
      final (_, _, voice) = await pump(
        tester,
        const TripAudioPanel.forRide(rideId: 'ride-1', canEdit: true),
        recordings: [_rec('r1'), _rec('d1', by: 'driver', uploaded: true)],
      );
      expect(find.text('2 recordings'), findsOneWidget);
      await tester.tap(find.text('Trip audio'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Rider's phone"), findsOneWidget);
      expect(find.textContaining("Driver's phone"), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      await tester.tap(find.text('Request'));
      await tester.pumpAndSettle();
      await closeAnyNotice(tester);
      expect(voice.requested, ['r1']);
    });

    test('the admin page is listed and grantable', () {
      final e = allAdminEntries.firstWhere((e) => e.path == riderAudioPath);
      expect(e.section, 'Services & catalogue');
      expect(e.pages, [riderAudioPage]);
      expect(grantablePages[riderAudioPage], 'Settings · Rider audio protection');
    });

    for (final b in Brightness.values) {
      testWidgets('admin: Default and region rules, edited and saved (${b.name})', (tester) async {
        final (_, audio, _) = await pump(tester, const SizedBox(height: 2400, child: RiderAudioScreen()), b: b);
        expect(find.text('Default (everywhere)'), findsOneWidget);
        expect(find.text('Hushstate, Audioland'), findsOneWidget);
        expect(find.text('Loudtown, Hushstate, Audioland'), findsOneWidget);
        // The state leaves the hours to the country: 2 days shown, as the place above.
        final hush = find.byKey(ValueKey('rider-audio-rule-${_hush.key}'));
        expect(find.descendant(of: hush, matching: find.text('2 days')), findsOneWidget);
        expect(find.descendant(of: hush, matching: find.text('As the place above')), findsOneWidget);

        // Raise the Default's hours and remove the city rule.
        final def = find.byKey(const ValueKey('rider-audio-rule-'));
        await tester.tap(find.descendant(of: def, matching: find.byTooltip('Raise Kept on the phone for')));
        await tester.pumpAndSettle();
        expect(find.descendant(of: def, matching: find.text('30 h')), findsOneWidget);
        await tester.tap(find.byTooltip('Remove the rule for Loudtown, Hushstate, Audioland'));
        await tester.pumpAndSettle();
        expect(find.text('Not saved yet.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rider-audio-save')));
        await tester.pumpAndSettle();
        await closeAnyNotice(tester);
        expect(audio.deleted, ['t']);
        expect(audio.saved.single.isDefault, isTrue);
        expect(audio.saved.single.keepHours, 30);
      });
    }

    testWidgets('admin: read-only without the edit grant', (tester) async {
      await pump(tester, const SizedBox(height: 2400, child: RiderAudioScreen()), canEdit: false);
      expect(find.byKey(const ValueKey('rider-audio-save')), findsNothing);
      expect(find.byKey(const ValueKey('rider-audio-add')), findsNothing);
      final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('rider-audio-on')).first);
      expect(sw.onChanged, isNull);
    });
  });
}
