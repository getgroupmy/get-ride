// The phones find each other at the kerb (reliability Phase D2):
// lib/src/core/ble_handshake.dart, lib/src/data/ble_handshake.dart and the
// badge (lib/src/widgets/ble_handshake_badge.dart).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ble_handshake.dart';
import 'package:get_ride/src/core/reliability_settings.dart';
import 'package:get_ride/src/data/ble.dart';
import 'package:get_ride/src/data/ble_chat.dart';
import 'package:get_ride/src/data/ble_handshake.dart';
import 'package:get_ride/src/data/reliability_repository.dart';
import 'package:get_ride/src/widgets/ble_handshake_badge.dart';
import 'package:latlong2/latlong.dart';
import 'package:universal_ble/universal_ble.dart';

const _mine = '0123456789abcdef';
const _peer = 'fedcba9876543210';

class _Radio implements BleRadio {
  _Radio({this.refuse});
  final String? refuse;
  final _out = StreamController<BleAdvert>.broadcast();
  final started = <String>[];
  int stops = 0;

  void see(String token, int rssi) => _out.add((uuid: tokenServiceUuid(token)!, rssi: rssi, deviceId: 'dev-$token'));

  @override
  Stream<BleAdvert> get adverts => _out.stream;

  @override
  Future<String?> start(String uuid) async {
    if (refuse != null) return refuse;
    started.add(uuid);
    return null;
  }

  @override
  Future<void> stop() async => stops++;
}

class _Proof {
  _Proof(this.token, this.rssi, this.seenFor);
  final String token;
  final int rssi;
  final Duration seenFor;
}

BleTicket _ticket({String side = 'rider', String status = 'arrived', BleSettings? settings, bool enabled = true}) =>
    BleTicket(
      enabled: enabled,
      status: status,
      side: side,
      token: _mine,
      peerToken: _peer,
      expiresAt: DateTime.utc(2026, 10, 12, 9, 5),
      settings: settings ?? const BleSettings(enabled: true),
    );

/// A clock the test moves along with the fake timers.
class _Clock {
  final t0 = DateTime.utc(2026, 10, 12, 9);
  Duration elapsed = Duration.zero;
  DateTime now() => t0.add(elapsed);

  Future<void> advance(WidgetTester tester, Duration d) async {
    for (var i = 0; i < d.inSeconds; i++) {
      elapsed += const Duration(seconds: 1);
      await tester.pump(const Duration(seconds: 1));
    }
  }
}

/// A chat link that only records what the engine asks of it.
class _ChatLink implements BleChatTransport {
  final _linked = ValueNotifier(false);
  final connects = <String>[];
  bool served = false;
  bool stopped = false;

  @override
  Stream<Uint8List> get incoming => const Stream.empty();

  @override
  ValueListenable<bool> get linked => _linked;

  @override
  Future<bool> serve() async => served = true;

  @override
  Future<bool> connect(String deviceId) async {
    connects.add(deviceId);
    _linked.value = true;
    return true;
  }

  @override
  Future<bool> send(Uint8List frame) async => true;

  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  group('settings', () {
    test('off unless turned on; Android and iPhone on unless turned off; numbers clamped', () {
      expect(BleSettings.fromValues(null), const BleSettings());
      expect(const BleSettings().enabled, isFalse);
      final s = BleSettings.fromValues({
        'ble_enabled': 'true',
        'ble_ios': false,
        'ble_rssi_threshold_dbm': -200,
        'ble_match_timeout_s': '999',
      });
      expect(s.enabled, isTrue);
      expect(s.android, isTrue);
      expect(s.ios, isFalse);
      expect(s.rssiThresholdDbm, BleSettings.minRssi);
      expect(s.matchTimeoutS, BleSettings.maxTimeout);
      expect(BleSettings.fromValues(s.toValues()), s);
      expect(s.runsOn(isAndroid: true, isIos: false), isTrue);
      expect(s.runsOn(isAndroid: false, isIos: true), isFalse);
      expect(s.runsOn(isAndroid: false, isIos: false), isFalse, reason: 'the web and desktops never take part');
    });

    test('the switches ride in the reliability row without disturbing the others', () {
      final r = const ReliabilitySettings(rideCache: false)
          .withBle(const BleSettings(enabled: true, matchTimeoutS: 30));
      expect(r.rideCache, isFalse);
      expect(r.ble.enabled, isTrue);
      expect(ReliabilitySettings.fromValues(r.toValues()), r);
      expect(r.withSwitch('chat_outbox', false).ble, r.ble, reason: 'flipping another switch keeps Bluetooth\'s');
    });
  });

  group('tokens on the air', () {
    test('a token travels in a service UUID and comes back out', () {
      final uuid = tokenServiceUuid(_mine)!;
      expect(uuid, '6765742e-7269-6465-0123-456789abcdef');
      expect(tokenFromServiceUuid(uuid.toUpperCase()), _mine);
      expect(tokenServiceUuid('xyz'), isNull);
      expect(tokenFromServiceUuid('0000180d-0000-1000-8000-00805f9b34fb'), isNull, reason: 'someone else\'s service');
    });

    test('the server\'s ticket and answers', () {
      final t = BleTicket.fromJson({
        'enabled': true,
        'status': 'arrived',
        'side': 'driver',
        'token': _mine,
        'peer_token': _peer,
        'expires_at': '2026-10-12T09:05:00+00:00',
        'settings': {'enabled': true, 'autostart_no_pin': true, 'rssi_threshold_dbm': -65},
      });
      expect(t.usable, isTrue);
      expect(t.settings.autostartNoPin, isTrue);
      expect(t.settings.rssiThresholdDbm, -65);
      expect(BleTicket.fromJson({'enabled': false}).usable, isFalse);
      expect(BleTicket.fromJson('nonsense').usable, isFalse);

      expect(bleProofResult('matched'), BleProofResult.matched);
      expect(bleProofResult('on_trip'), BleProofResult.started);
      expect(bleProofResult('rate_limited:12'), BleProofResult.rateLimited);
      expect(bleProofResult('wrong_status:completed'), BleProofResult.wrongStatus);
      expect(bleProofResult('no_match'), BleProofResult.noMatch);
    });

    test('a ticket carries the next windows, so a phone without signal keeps rotating in step', () {
      final t = BleTicket.fromJson({
        'enabled': true,
        'status': 'arrived',
        'side': 'rider',
        'token': _mine,
        'peer_token': _peer,
        'expires_at': '2026-10-12T09:05:00+00:00',
        'ahead': [
          {'token': '1111111111111111', 'peer_token': 'aaaaaaaaaaaaaaaa', 'expires_at': '2026-10-12T09:10:00+00:00'},
          {'token': 'nonsense', 'peer_token': 'bbbbbbbbbbbbbbbb', 'expires_at': '2026-10-12T09:15:00+00:00'},
          {'token': '2222222222222222', 'peer_token': 'cccccccccccccccc', 'expires_at': '2026-10-12T09:15:00+00:00'},
        ],
        'chat_key': 'k',
        'settings': {'enabled': true},
      });
      expect(t.ahead, hasLength(2), reason: 'a slot that can\'t be advertised is dropped');

      expect(t.at(DateTime.utc(2026, 10, 12, 9, 4))!.token, _mine);
      final next = t.at(DateTime.utc(2026, 10, 12, 9, 7))!;
      expect(next.token, '1111111111111111');
      expect(next.peerToken, 'aaaaaaaaaaaaaaaa');
      expect(next.expiresAt, DateTime.utc(2026, 10, 12, 9, 10));
      expect(next.chatKey, 'k', reason: 'the chat key is the ride\'s, not the window\'s');
      expect(next.ahead.single.token, '2222222222222222');
      expect(next.at(DateTime.utc(2026, 10, 12, 9, 12))!.token, '2222222222222222');
      expect(t.at(DateTime.utc(2026, 10, 12, 9, 16)), isNull, reason: 'past every window it knows');

      expect(t.peerTokensNear(DateTime.utc(2026, 10, 12, 9, 4)), {_peer, 'aaaaaaaaaaaaaaaa'});
      expect(t.peerTokensNear(DateTime.utc(2026, 10, 12, 9, 7)), {
        _peer,
        'aaaaaaaaaaaaaaaa',
        'cccccccccccccccc',
      }, reason: 'the other phone\'s clock may be a little either side');
      expect(_ticket().at(DateTime.utc(2026, 10, 12, 9, 6)), isNull, reason: 'an old server sends nothing ahead');
    });

    test('a sighting counts after 5 s unbroken at or above the threshold', () {
      final t0 = DateTime.utc(2026);
      var s = const PeerSighting();
      for (var i = 0; i <= 5; i++) {
        s = s.add(-60, t0.add(Duration(seconds: i)), thresholdDbm: -70);
      }
      expect(s.qualifies, isTrue);
      expect(s.averageRssi, -60);
      expect(s.add(-80, t0.add(const Duration(seconds: 6)), thresholdDbm: -70).count, 0, reason: 'too weak: over');
      final gap = s.add(-60, t0.add(const Duration(seconds: 10)), thresholdDbm: -70);
      expect(gap.qualifies, isFalse, reason: 'a gap starts the run again');
      expect(s.expire(t0.add(const Duration(seconds: 9))).count, 0);
    });

    test('a report goes only when it says something new', () {
      final t0 = DateTime.utc(2026, 10, 12, 9);
      DateTime at(int s) => t0.add(Duration(seconds: s));
      bool should({
        required bool close,
        bool? reported,
        int? last,
        required int now,
        String status = 'arrived',
        BleProofResult? answer,
      }) => bleShouldReport(
        close: close,
        reported: reported,
        lastReport: last == null ? null : at(last),
        now: at(now),
        status: status,
        answer: answer,
      );

      expect(should(close: false, now: 0), isFalse, reason: 'nothing seen close yet');
      expect(should(close: true, now: 0), isTrue, reason: 'first close sighting');
      expect(should(close: true, reported: true, last: 0, now: 4), isFalse, reason: 'nothing changed');
      expect(should(close: true, reported: true, last: 0, now: 24), isFalse);
      expect(should(close: true, reported: true, last: 0, now: 25), isTrue, reason: 'keep-alive');
      expect(should(close: false, reported: true, last: 0, now: 5), isTrue, reason: 'fell below the threshold');
      expect(should(close: true, reported: false, last: 0, now: 5), isTrue, reason: 'back above it');
      expect(should(close: false, reported: false, last: 0, now: 60), isFalse, reason: 'still not close: no keep-alive');
      expect(should(close: false, reported: true, last: 0, now: 3), isFalse, reason: 'never closer than 4 s');
      expect(should(close: true, last: 0, now: 4), isTrue, reason: 'one that didn\'t get through goes again');
      expect(should(close: true, reported: true, last: 0, now: 60, answer: BleProofResult.matched), isFalse,
          reason: 'matched: nothing more to say');
      expect(should(close: false, reported: true, last: 0, now: 60, answer: BleProofResult.matched), isFalse,
          reason: 'matched: not even a crossing');
      expect(should(close: true, reported: true, last: 0, now: 240, answer: BleProofResult.matched), isTrue,
          reason: 'matched: a slow keep-alive, for the start check');
      expect(should(close: true, reported: true, last: 0, now: 60, answer: BleProofResult.started), isFalse);
      expect(should(close: true, reported: true, last: 0, now: 60, answer: BleProofResult.waiting), isTrue);
      for (final status in ['on_trip', 'completed', 'cancelled', 'searching']) {
        expect(should(close: true, now: 0, status: status), isFalse, reason: '$status: past the pickup');
      }
      expect(should(close: true, now: 0, status: 'accepted'), isTrue);
    });

    test('the driver counts down only where the report may start the trip', () {
      const auto = BleSettings(enabled: true, autostartNoPin: true);
      expect(bleNeedsCountdown(side: 'driver', status: 'arrived', settings: auto), isTrue);
      expect(bleNeedsCountdown(side: 'driver', status: 'accepted', settings: auto), isFalse);
      expect(bleNeedsCountdown(side: 'rider', status: 'arrived', settings: auto), isFalse);
      expect(bleNeedsCountdown(side: 'driver', status: 'arrived', settings: const BleSettings(enabled: true)), isFalse);
    });

    test('how far away the other phone is: a rough hint from the signal', () {
      expect(bleDistanceM(bleTxPowerAt1m), closeTo(1, 0.001));
      expect(bleDistanceM(-84), closeTo(10, 0.01), reason: '25 dB weaker at n = 2.5 is ten times as far');
      expect(bleDistanceLabel(bleDistanceM(-55)), 'right next to you');
      expect(bleDistanceLabel(bleDistanceM(-75)), '~4 m');
      expect(bleDistanceLabel(13.2), '~15 m');
      expect(bleDistanceLabel(bleDistanceM(-100)), '30+ m away');
      expect(bleSmoothRssi(null, -70), -70);
      expect(bleSmoothRssi(-70, -50), -64, reason: 'one loud advert moves it only part of the way');
    });

    test('the admin\'s summary', () {
      expect(const BleStartStats().describe(7), contains('No trips'));
      final s = BleStartStats.fromRow([
        {'by_ble': 3, 'by_pin': 1, 'by_none': 0, 'by_unknown': 0},
      ]);
      expect(s.describe(7), 'Last 7 days: 3 by Bluetooth (75%) · 1 by code');
    });
  });

  group('the phone\'s own advert', () {
    test('nothing is advertised before an iPhone\'s peripheral side has powered on', () {
      fakeAsync((async) {
        final states = [
          PeripheralReadinessState.unknown,
          PeripheralReadinessState.unknown,
          PeripheralReadinessState.ready,
        ];
        var asked = 0;
        String? why = 'pending';
        ensurePeripheralReady(state: () async => states[asked++]).then((w) => why = w);
        async.elapse(const Duration(seconds: 1));
        expect(why, isNull);
        expect(asked, 3, reason: 'it waited for ready');
      });
    });

    test('Bluetooth off says so; Android\'s permission is asked by the advert itself', () async {
      expect(await ensurePeripheralReady(state: () async => PeripheralReadinessState.bluetoothOff), 'Bluetooth is off');
      expect(await ensurePeripheralReady(state: () async => PeripheralReadinessState.unauthorized), isNull);
    });

    test('a peripheral side that never powers on gives up', () {
      fakeAsync((async) {
        String? why;
        ensurePeripheralReady(
          state: () async => PeripheralReadinessState.unknown,
          timeout: Duration.zero,
        ).then((w) => why = w);
        async.elapse(const Duration(seconds: 1));
        expect(why, 'Bluetooth isn\'t ready');
      });
    });

    test('an advert counts once the phone says it is on the air, not when it was asked for', () {
      fakeAsync((async) {
        final states = [PeripheralAdvertisingState.starting, PeripheralAdvertisingState.advertising];
        var i = 0;
        bool? on;
        confirmAdvertising(state: () async => states[i++]).then((v) => on = v);
        async.elapse(const Duration(seconds: 1));
        expect(on, isTrue);

        bool? refused;
        confirmAdvertising(state: () async => PeripheralAdvertisingState.error).then((v) => refused = v);
        async.flushMicrotasks();
        expect(refused, isFalse);
      });
    });
  });

  group('the engine', () {
    late _Radio radio;
    late List<_Proof> proofs;
    late List<BleProofResult> answers;

    /// Runs [body] with fake time; the engine's clock follows it.
    void run(void Function(FakeAsync async, DateTime Function() now) body) => fakeAsync((async) {
      final t0 = DateTime.utc(2026, 10, 12, 9);
      body(async, () => t0.add(async.elapsed));
      async.flushTimers(flushPeriodicTimers: false);
    });

    BleHandshakeEngine engine(BleTicket ticket, DateTime Function() now, {String status = 'arrived'}) =>
        BleHandshakeEngine(
          radio: radio,
          server: BleHandshakeServer(
            ticket: () async => ticket,
            proof: (token, rssi, seenFor, at) async {
              proofs.add(_Proof(token, rssi, seenFor));
              return answers.isEmpty ? BleProofResult.waiting : answers.removeAt(0);
            },
          ),
          isAndroid: true,
          isIos: false,
          status: status,
          position: () async => const LatLng(3.1579, 101.7116),
          now: now,
        );

    /// The other phone, seen every second for [seconds].
    void seePeer(FakeAsync async, int seconds, {int rssi = -60, String token = _peer}) {
      for (var i = 0; i < seconds; i++) {
        radio.see(token, rssi);
        async.elapse(const Duration(seconds: 1));
      }
    }

    void finish(FakeAsync async, BleHandshakeEngine e) {
      e.dispose();
      async.elapse(const Duration(seconds: 1));
    }

    setUp(() {
      radio = _Radio();
      proofs = [];
      answers = [];
    });

    test('the rider\'s phone advertises, sees the driver for 5 s, reports, and shows the right car', () {
      run((async, now) {
        final e = engine(_ticket(), now);
        e.start();
        async.flushMicrotasks();
        expect(radio.started, [tokenServiceUuid(_mine)]);
        expect(e.phase.value, BleHandshakePhase.searching);

        seePeer(async, 3);
        expect(e.phase.value, BleHandshakePhase.nearby);
        expect(proofs, isEmpty, reason: 'not seen long enough yet');

        answers.add(BleProofResult.matched);
        seePeer(async, 4);
        expect(proofs, hasLength(1));
        expect(proofs.single.token, _peer);
        expect(proofs.single.seenFor, greaterThanOrEqualTo(bleSeenFor));
        expect(e.phase.value, BleHandshakePhase.matched);
        finish(async, e);
      });
    });

    test('the distance hint follows the other phone, however weak, and clears when it goes', () {
      run((async, now) {
        final e = engine(_ticket(), now);
        e.start();
        seePeer(async, 2, token: 'aaaaaaaaaaaaaaaa');
        expect(e.peerRssi.value, isNull, reason: 'a stranger\'s phone gives no distance');
        seePeer(async, 2, rssi: -90);
        expect(e.peerRssi.value, -90, reason: 'too weak to match, close enough to hint');
        async.elapse(const Duration(seconds: 5));
        expect(e.peerRssi.value, isNull);
        finish(async, e);
      });
    });

    test(
      'chat over Bluetooth: started only with a key, the rider links to the phone it saw, stopped with the rest',
      () {
        run((async, now) {
          final link = _ChatLink();
          const chatKey = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
          BleHandshakeEngine withChat(BleTicket t) => BleHandshakeEngine(
            radio: radio,
            server: BleHandshakeServer(ticket: () async => t, proof: (_, _, _, _) async => BleProofResult.waiting),
            isAndroid: true,
            isIos: false,
            status: 'arrived',
            position: () async => null,
            now: now,
            chatFactory: (ticket, key) => BleChatSession(
              transport: link,
              key: key,
              requestId: 'r1',
              driver: ticket.side == 'driver',
              pending: () => const [],
              now: now,
            ),
          );

          final noKey = withChat(_ticket(settings: const BleSettings(enabled: true, chat: true)));
          noKey.start();
          async.flushMicrotasks();
          expect(noKey.chat.value, isNull, reason: 'no key, no chat');
          finish(async, noKey);

          final t = BleTicket(
            enabled: true,
            status: 'arrived',
            side: 'rider',
            token: _mine,
            peerToken: _peer,
            expiresAt: DateTime.utc(2026, 10, 12, 9, 5),
            chatKey: chatKey,
            settings: const BleSettings(enabled: true, chat: true),
          );
          final e = withChat(t);
          e.start();
          async.flushMicrotasks();
          expect(e.chat.value, isNotNull);
          expect(link.served, isFalse, reason: 'the rider\'s phone connects, it doesn\'t serve');
          seePeer(async, 1);
          expect(link.connects, ['dev-$_peer']);
          e.updateStatus('on_trip');
          async.elapse(const Duration(seconds: 1));
          expect(link.stopped, isTrue);
          expect(e.chat.value, isNull);
          finish(async, e);
        });
      },
    );

    test('no signal: the phone keeps rotating tokens from the schedule, chat and all, until the server says stop', () {
      run((async, now) {
        final full = BleTicket(
          enabled: true,
          status: 'arrived',
          side: 'rider',
          token: _mine,
          peerToken: _peer,
          expiresAt: DateTime.utc(2026, 10, 12, 9, 5),
          settings: const BleSettings(enabled: true),
          ahead: [
            BleSlot(
              token: '1111111111111111',
              peerToken: 'aaaaaaaaaaaaaaaa',
              expiresAt: DateTime.utc(2026, 10, 12, 9, 10),
            ),
          ],
        );
        BleTicket? answer = full;
        final server = BleHandshakeServer(
          ticket: () async => answer ?? (throw StateError('no signal')),
          proof: (_, _, _, _) async => throw StateError('no signal'),
        );
        final e = BleHandshakeEngine(
          radio: radio,
          server: server,
          isAndroid: true,
          isIos: false,
          status: 'arrived',
          position: () async => null,
          now: now,
        );
        e.start();
        async.flushMicrotasks();
        expect(radio.started, [tokenServiceUuid(_mine)]);

        answer = null; // airplane mode
        async.elapse(const Duration(minutes: 4, seconds: 56));
        expect(radio.started.last, tokenServiceUuid('1111111111111111'), reason: 'the next window, from the schedule');
        expect(e.phase.value, BleHandshakePhase.searching, reason: 'still looking');

        seePeer(async, 2, rssi: -90);
        expect(e.peerRssi.value, isNotNull, reason: 'the other phone, a moment behind, is still found');
        seePeer(async, 2, rssi: -90, token: 'aaaaaaaaaaaaaaaa');
        expect(e.peerRssi.value, isNotNull, reason: 'and once it rotates too');

        async.elapse(const Duration(minutes: 6));
        expect(
          e.phase.value,
          isNot(BleHandshakePhase.idle),
          reason: 'out of schedule: the last token stays on the air',
        );
        expect(radio.stops, 0);

        answer = _ticket(enabled: false); // back online; the admin turned it off
        async.elapse(bleOfflineRetry);
        expect(e.phase.value, BleHandshakePhase.idle);
        finish(async, e);
      });
    });

    test('built again without signal, it carries on from the ride\'s last ticket', () {
      run((async, now) {
        final server = BleHandshakeServer(
          ticket: () async => throw StateError('no signal'),
          proof: (_, _, _, _) async => BleProofResult.waiting,
        );
        BleHandshakeEngine build() => BleHandshakeEngine(
          radio: radio,
          server: server,
          isAndroid: true,
          isIos: false,
          status: 'arrived',
          position: () async => null,
          now: now,
        );
        final first = build()..start();
        async.flushMicrotasks();
        expect(first.phase.value, BleHandshakePhase.idle, reason: 'never had a ticket: nothing to go on');
        finish(async, first);

        server.lastTicket = _ticket();
        final again = build()..start();
        async.flushMicrotasks();
        expect(radio.started.last, tokenServiceUuid(_mine));
        expect(again.phase.value, BleHandshakePhase.searching);
        finish(async, again);
      });
    });

    test('no signal: the other phone close by is "detected around you", never a match', () {
      run((async, now) {
        var online = false;
        final e = BleHandshakeEngine(
          radio: radio,
          server: BleHandshakeServer(
            ticket: () async => _ticket(),
            proof: (_, _, _, _) async => online ? BleProofResult.matched : throw StateError('no signal'),
          ),
          isAndroid: true,
          isIos: false,
          status: 'arrived',
          position: () async => null,
          now: now,
        );
        e.start();
        async.flushMicrotasks();

        seePeer(async, 3);
        expect(e.phase.value, BleHandshakePhase.nearby, reason: 'not seen long enough to say yet');
        seePeer(async, 4);
        expect(e.phase.value, BleHandshakePhase.detectedOffline);
        expect(bleHandshakeLabel(e.phase.value, driver: false), 'The provider is detected around you');
        expect(bleHandshakeLabel(e.phase.value, driver: true), 'The passenger is detected around you');

        async.elapse(const Duration(seconds: 6));
        expect(e.phase.value, BleHandshakePhase.searching, reason: 'gone: not claimed any more');

        online = true; // signal back while the other phone is still here
        seePeer(async, 7);
        expect(e.phase.value, BleHandshakePhase.matched);
        finish(async, e);
      });
    });

    test('another phone, or a weak signal, is never reported', () {
      run((async, now) {
        final e = engine(_ticket(), now);
        e.start();
        seePeer(async, 8, token: 'aaaaaaaaaaaaaaaa');
        seePeer(async, 8, rssi: -90);
        expect(proofs, isEmpty);
        expect(e.phase.value, BleHandshakePhase.searching);
        finish(async, e);
      });
    });

    test('at the pickup with autostart on, the driver counts down 3 s, then the trip starts', () {
      run((async, now) {
        final e = engine(
          _ticket(side: 'driver', settings: const BleSettings(enabled: true, autostartNoPin: true)),
          now,
        );
        e.start();
        seePeer(async, 7);
        expect(e.phase.value, BleHandshakePhase.countdown);
        expect(proofs, isEmpty, reason: 'nothing is sent while the driver can still cancel');

        answers.add(BleProofResult.started);
        seePeer(async, 3);
        expect(proofs, hasLength(1));
        expect(e.phase.value, BleHandshakePhase.started);
        async.elapse(const Duration(seconds: 1));
        expect(radio.stops, 1, reason: 'Bluetooth is let go once the trip starts');
        finish(async, e);
      });
    });

    test('the driver cancels the countdown: nothing is sent, and the code it is', () {
      run((async, now) {
        final e = engine(
          _ticket(side: 'driver', settings: const BleSettings(enabled: true, autostartNoPin: true)),
          now,
        );
        e.start();
        seePeer(async, 7);
        expect(e.phase.value, BleHandshakePhase.countdown);
        e.cancel();
        seePeer(async, 10);
        expect(proofs, isEmpty);
        expect(e.phase.value, BleHandshakePhase.cancelled);
        finish(async, e);
      });
    });

    test('switched off by the server, or not this platform: Bluetooth is never touched', () {
      run((async, now) {
        final off = engine(_ticket(enabled: false), now);
        off.start();
        final ios = engine(_ticket(settings: const BleSettings(enabled: true, android: false)), now);
        ios.start();
        async.flushMicrotasks();
        expect(radio.started, isEmpty);
        expect(off.phase.value, BleHandshakePhase.idle);
        expect(ios.phase.value, BleHandshakePhase.idle);
        finish(async, off);
        finish(async, ios);
      });
    });

    test('Bluetooth off: the badge says so, and the code is the way', () {
      run((async, now) {
        radio = _Radio(refuse: 'Bluetooth is off.');
        final e = engine(_ticket(), now);
        e.start();
        async.flushMicrotasks();
        expect(e.phase.value, BleHandshakePhase.unavailable);
        expect(e.unavailableReason, 'Bluetooth is off.');
        finish(async, e);
      });
    });

    test('reports only on change: first sighting, keep-alive, threshold crossings; none after a match', () {
      run((async, now) {
        final e = engine(_ticket(), now);
        e.start();
        async.flushMicrotasks();
        seePeer(async, 7);
        expect(proofs, hasLength(1), reason: 'the first close sighting');
        seePeer(async, 20);
        expect(proofs, hasLength(1), reason: 'nothing new: no report every 4 s');
        seePeer(async, 6);
        expect(proofs, hasLength(2), reason: 'the keep-alive');
        expect(proofs.last.seenFor, greaterThanOrEqualTo(bleSeenFor));

        seePeer(async, 2, rssi: -90);
        expect(proofs, hasLength(3), reason: 'fell below the threshold');
        expect(proofs.last.seenFor, Duration.zero);
        seePeer(async, 20, rssi: -90);
        expect(proofs, hasLength(3), reason: 'still weak: nothing more');

        answers.add(BleProofResult.matched);
        seePeer(async, 7);
        expect(proofs, hasLength(4), reason: 'back above it');
        expect(e.phase.value, BleHandshakePhase.matched);
        seePeer(async, 60);
        expect(proofs, hasLength(4), reason: 'matched: no more reports');
        seePeer(async, 180);
        expect(proofs, hasLength(5), reason: 'matched: a keep-alive every 4 minutes');
        expect(radio.stops, 0, reason: 'still on the air for the other phone');

        e.updateStatus('accepted');
        seePeer(async, 2);
        expect(proofs, hasLength(6), reason: 'a new status asks again');
        finish(async, e);
      });
    });

    test('the trip starting some other way stops it', () {
      run((async, now) {
        final e = engine(_ticket(), now);
        e.start();
        async.flushMicrotasks();
        e.updateStatus('on_trip');
        async.elapse(const Duration(seconds: 1));
        expect(e.phase.value, BleHandshakePhase.idle);
        expect(radio.stops, 1);
        seePeer(async, 8);
        expect(proofs, isEmpty);
        finish(async, e);
      });
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('the badge shows the right car (${brightness.name})', (tester) async {
      final radio = _Radio();
      final clock = _Clock();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reliabilityProvider.overrideWithValue(const ReliabilitySettings(ble: BleSettings(enabled: true))),
            blePlatformProvider.overrideWithValue((android: true, ios: false)),
            bleRadioProvider.overrideWithValue(radio),
            bleClockProvider.overrideWithValue(clock.now),
            blePositionProvider.overrideWithValue(() async => null),
            bleHandshakeServerProvider.overrideWith(
              (ref, id) => BleHandshakeServer(
                ticket: () async => _ticket(),
                proof: (_, _, _, _) async => BleProofResult.matched,
              ),
            ),
          ],
          child: MaterialApp(
            theme: appTheme(brightness),
            home: const Scaffold(
              body: BleHandshakeBadge(rideId: 'r1', status: 'arrived', driver: false),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Looking for your driver\'s phone…'), findsOneWidget);
      for (var i = 0; i < 7; i++) {
        radio.see(_peer, -60);
        await clock.advance(tester, const Duration(seconds: 1));
      }
      expect(find.text('✓ Correct car · right next to you'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('switched off: the badge shows nothing and Bluetooth is left alone', (tester) async {
    final radio = _Radio();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reliabilityProvider.overrideWithValue(const ReliabilitySettings()),
          blePlatformProvider.overrideWithValue((android: true, ios: false)),
          bleRadioProvider.overrideWithValue(radio),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: BleHandshakeBadge(rideId: 'r1', status: 'arrived', driver: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('ble-badge')), findsNothing);
    expect(radio.started, isEmpty);
  });
}
