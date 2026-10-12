// The phones find each other at the kerb (reliability Phase D2):
// lib/src/core/ble_handshake.dart, lib/src/data/ble_handshake.dart and the
// badge (lib/src/widgets/ble_handshake_badge.dart).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ble_handshake.dart';
import 'package:get_ride/src/core/reliability_settings.dart';
import 'package:get_ride/src/data/ble_handshake.dart';
import 'package:get_ride/src/data/reliability_repository.dart';
import 'package:get_ride/src/widgets/ble_handshake_badge.dart';
import 'package:latlong2/latlong.dart';

const _mine = '0123456789abcdef';
const _peer = 'fedcba9876543210';

class _Radio implements BleRadio {
  _Radio({this.refuse});
  final String? refuse;
  final _out = StreamController<BleAdvert>.broadcast();
  final started = <String>[];
  int stops = 0;

  void see(String token, int rssi) => _out.add((uuid: tokenServiceUuid(token)!, rssi: rssi));

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

    test('the driver counts down only where the report may start the trip', () {
      const auto = BleSettings(enabled: true, autostartNoPin: true);
      expect(bleNeedsCountdown(side: 'driver', status: 'arrived', settings: auto), isTrue);
      expect(bleNeedsCountdown(side: 'driver', status: 'accepted', settings: auto), isFalse);
      expect(bleNeedsCountdown(side: 'rider', status: 'arrived', settings: auto), isFalse);
      expect(bleNeedsCountdown(side: 'driver', status: 'arrived', settings: const BleSettings(enabled: true)), isFalse);
    });

    test('the admin\'s summary', () {
      expect(const BleStartStats().describe(7), contains('No trips'));
      final s = BleStartStats.fromRow([
        {'by_ble': 3, 'by_pin': 1, 'by_none': 0, 'by_unknown': 0},
      ]);
      expect(s.describe(7), 'Last 7 days: 3 by Bluetooth (75%) · 1 by code');
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
      expect(find.text('✓ Correct car'), findsOneWidget);
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
