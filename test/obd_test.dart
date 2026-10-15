import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/obd.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/data/obd/obd_client.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/data/obd/obd_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_elm.dart';

void main() {
  group('ELM327 replies', () {
    final speed = obdPids['speed']!;
    final rpm = obdPids['rpm']!;

    test('a reply is found in echo, headers and spacing', () {
      expect(decodePid('41 0D 3C\r\r>', speed), 60);
      expect(decodePid('010D\r41 0D 3C\r>', speed), 60);
      expect(decodePid('7E8 03 41 0D 3C\r>', speed), 60);
      expect(decodePid('41 0C 1A F8\r>', rpm), 1726);
    });

    test('errors and short answers are no reading', () {
      expect(decodePid('NO DATA\r>', speed), isNull);
      expect(decodePid('CAN ERROR\r>', speed), isNull);
      expect(decodePid('?\r>', speed), isNull);
      expect(decodePid('41 0C 1A\r>', rpm), isNull);
      expect(decodePid('41 0D ZZ\r>', speed), isNull);
    });

    test('SEARCHING is the adapter still working', () {
      expect(isElmSearching('SEARCHING...\r'), isTrue);
      expect(isElmSearching('41 0D 00'), isFalse);
    });

    test('the odometer is four bytes of tenths of a km', () {
      expect(decodePid('41 A6 00 13 99 9A\r>', odometerPid), 128450.6);
    });

    test('protocols by number, found by auto search or not', () {
      expect(describeProtocol('A6'), (name: 'ISO 15765-4 CAN (11-bit, 500 kbps)', bitrateKbps: 500));
      expect(describeProtocol('3').bitrateKbps, isNull);
      expect(describeProtocol(null).name, 'Unknown');
      expect(describeProtocol('X').name, 'Protocol X');
    });

    test('values are formatted with their unit', () {
      expect(formatTelemetryValue('speed', 60.4), '60 km/h');
      expect(formatTelemetryValue('moduleVoltage', 13.94), '13.9 V');
    });
  });

  group('saved readers', () {
    test('a blank Wi-Fi form means the usual soft-AP address', () {
      final r = normalizeWifiAdapter(id: 'a', createdAt: 't');
      expect(r.error, isNull);
      expect(r.value!.host, wifiAdapterHost);
      expect(r.value!.port, wifiAdapterPort);
      expect(r.value!.name, 'Wi-Fi OBD-II reader');
      expect(describeAdapter(r.value!), 'Wi-Fi · 192.168.0.10:35000');
    });

    test('bad hosts, ports and names are refused', () {
      expect(normalizeWifiAdapter(id: 'a', createdAt: 't', host: 'http://x').error, isNotNull);
      expect(normalizeWifiAdapter(id: 'a', createdAt: 't', port: '70000').error, isNotNull);
      expect(normalizeWifiAdapter(id: 'a', createdAt: 't', port: 'abc').error, isNotNull);
      expect(normalizeWifiAdapter(id: 'a', createdAt: 't', name: 'x' * 61).error, isNotNull);
    });

    test('the same host and port replaces the saved reader and keeps its id', () {
      final a = normalizeWifiAdapter(id: 'a', createdAt: 't1', name: 'Old').value!;
      final b = normalizeWifiAdapter(id: 'b', createdAt: 't2', name: 'New').value!;
      final list = upsertAdapter([a], b);
      expect(list.single.id, 'a');
      expect(list.single.name, 'New');
      final other = normalizeWifiAdapter(id: 'c', createdAt: 't', host: '192.168.4.1').value!;
      expect(upsertAdapter(list, other), hasLength(2));
      expect(removeAdapter(upsertAdapter(list, other), 'a').single.id, 'c');
    });

    test('the default is the selected one, else the last connected, else the first', () {
      final a = normalizeWifiAdapter(id: 'a', createdAt: 't').value!;
      final b = normalizeWifiAdapter(id: 'b', createdAt: 't', host: '10.0.0.2').value!.copyWith(lastConnectedAt: 5);
      expect(pickDefaultAdapter([a, b], 'a')!.id, 'a');
      expect(pickDefaultAdapter([a, b], 'gone')!.id, 'b');
      expect(pickDefaultAdapter([a], null)!.id, 'a');
      expect(pickDefaultAdapter([], null), isNull);
    });

    test('a saved reader survives storage', () {
      final a = normalizeWifiAdapter(id: 'a', createdAt: 't').value!.copyWith(lastConnectedAt: 7);
      expect(SavedObdAdapter.fromJson(a.toJson())!.toJson(), a.toJson());
      expect(SavedObdAdapter.fromJson({'id': 1}), isNull);
    });
  });

  group('the session client', () {
    test('initialises the adapter, names the protocol and sweeps the PIDs', () async {
      final elm = FakeElm(speed: 60);
      String? protocol;
      final readings = <Telemetry>[];
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        onProtocol: (name, _) => protocol = name,
        onTelemetry: (t, _) => readings.add(t),
      );
      await client.start();
      await pumpEventQueue();
      expect(elm.written.take(8), ['', ...elmInitCommands, elmDescribeProtocol], reason: 'woken, then reset');
      expect(protocol, 'ISO 15765-4 CAN (11-bit, 500 kbps)');
      expect(readings.single['speed'], 60);
      expect(readings.single['rpm'], 1726);
      expect(readings.single.containsKey('fuelLevel'), isFalse, reason: 'NO DATA is no reading');
      await client.stop();
      expect(elm.connected, isFalse);
    });

    test('a reader that misses the reset is tried the link\'s other way', () async {
      final elm = _DeafUntilRetuned();
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        wakeTimeout: const Duration(milliseconds: 10),
        resetTimeout: const Duration(milliseconds: 20),
      );
      await client.start();
      expect(elm.retunes, 1);
      expect(elm.written.where((c) => c == 'ATZ'), hasLength(2));
      await client.stop();
    });

    test('a reader that never answers fails the handshake once every way is tried', () async {
      final elm = _DeafUntilRetuned(ways: 1)..deaf = true;
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        wakeTimeout: const Duration(milliseconds: 10),
        resetTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        client.start(),
        throwsA(isA<TimeoutException>().having((e) => e.message, 'message', contains('did not answer'))),
      );
      await client.stop();
    });

    test('a late reply is not taken for the reset\'s answer', () {
      expect(isStaleResetReply('?\r\r>'), isTrue);
      expect(isStaleResetReply('41 0D 00\r\r>'), isTrue);
      expect(isStaleResetReply('>'), isTrue);
      expect(isStaleResetReply('ATZ\r\r\rELM327 v1.5\r\r>'), isFalse);
      expect(isStaleResetReply('OBDII v1.5\r>'), isFalse);
    });

    test('a reader still searching for the vehicle is given time, not reported lost', () async {
      final elm = FakeElm(speed: 50)..searching = const Duration(milliseconds: 60);
      var lost = 0;
      final readings = <Telemetry>[];
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        commandTimeout: const Duration(milliseconds: 20),
        searchTimeout: const Duration(milliseconds: 500),
        onLinkLost: () => lost++,
        onTelemetry: (t, _) => readings.add(t),
      );
      await client.start();
      // Every vehicle question takes three times the command timeout.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(lost, 0);
      expect(readings.single['speed'], 50);
      await client.stop();
    });

    test('an electric car: connected and silent, asked lightly, never "reconnecting"', () async {
      final elm = FakeElm()
        ..electric = true
        ..searching = const Duration(milliseconds: 30);
      var lost = 0;
      final silent = <bool>[];
      var now = 0;
      final client = ObdClient(
        elm,
        pollInterval: const Duration(milliseconds: 10),
        commandTimeout: const Duration(milliseconds: 20),
        searchTimeout: const Duration(milliseconds: 500),
        silentProbeInterval: const Duration(seconds: 10),
        onLinkLost: () => lost++,
        onVehicleSilent: silent.add,
        now: () => now,
      );
      await client.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lost, 0);
      expect(silent, [true]);
      expect(client.vehicleSilent, isTrue);
      // "UNABLE TO CONNECT" ends the sweep at its first question; then quiet.
      final asked = elm.written.where((c) => !c.startsWith('AT') && c.isNotEmpty).length;
      expect(asked, 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(elm.written.where((c) => !c.startsWith('AT') && c.isNotEmpty).length, asked);

      // Ten seconds on, one probe; the car now answers and the sweep resumes.
      elm
        ..electric = false
        ..searching = null;
      now += 10000;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(elm.written, contains(obdProbeCommand));
      expect(silent, [true, false]);
      expect(lost, 0);
      await client.stop();
    });

    test('replies that mean the car, not the reader, is quiet', () {
      expect(isVehicleSilentReply('SEARCHING...\rUNABLE TO CONNECT\r\r>'), isTrue);
      expect(isVehicleSilentReply('NO DATA\r\r>'), isTrue);
      expect(isVehicleSilentReply('BUS INIT: ...ERROR\r>'), isTrue);
      expect(isVehicleSilentReply('CAN ERROR\r>'), isTrue);
      expect(isVehicleSilentReply('41 0D 32\r\r>'), isFalse);
      expect(isNoProtocolReply('SEARCHING...\rUNABLE TO CONNECT\r>'), isTrue);
      expect(isNoProtocolReply('NO DATA\r>'), isFalse);
    });

    test('a reply missed while the sweep is held does not count towards a lost link', () async {
      final elm = FakeElm();
      var lost = 0;
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        commandTimeout: const Duration(milliseconds: 20),
        onLinkLost: () => lost++,
      );
      await client.start();
      await pumpEventQueue();
      elm.silent = true;
      client.setPollingPaused(true);
      for (var i = 0; i < 3; i++) {
        await expectLater(client.request('010D'), throwsA(isA<TimeoutException>()));
      }
      expect(lost, 0, reason: 'a print job had the radio');
      client.setPollingPaused(false);
      for (var i = 0; i < 3; i++) {
        await expectLater(client.request('010D'), throwsA(isA<TimeoutException>()));
      }
      expect(lost, 1);
      await client.stop();
    });

    test('a scan holding the sweep still notices a reader that went away', () async {
      final elm = FakeElm();
      var lost = 0;
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        commandTimeout: const Duration(milliseconds: 20),
        onLinkLost: () => lost++,
      );
      await client.start();
      await pumpEventQueue();
      elm.silent = true;
      client.setPollingPaused(true, ignoreFailures: false);
      for (var i = 0; i < 3; i++) {
        await expectLater(client.request('0902'), throwsA(isA<TimeoutException>()));
      }
      expect(lost, 1, reason: 'three misses mid-scan are a lost reader, not a busy radio');
      await client.stop();
    });

    test('commands are answered one at a time, in order', () async {
      final elm = FakeElm();
      final client = ObdClient(elm, pollInterval: const Duration(hours: 1));
      await client.start();
      client.setPollingPaused(true);
      final replies = await Future.wait([client.request('01A6'), client.request('010D')]);
      expect(decodePid(replies[0], odometerPid), 128450.6);
      expect(decodePid(replies[1], obdPids['speed']!), 42);
      await client.stop();
    });

    test('three unanswered commands on a live link report it lost', () async {
      final elm = FakeElm();
      var lost = 0;
      final client = ObdClient(
        elm,
        pollInterval: const Duration(hours: 1),
        commandTimeout: const Duration(milliseconds: 20),
        onLinkLost: () => lost++,
      );
      await client.start();
      await pumpEventQueue();
      elm.silent = true;
      for (var i = 0; i < 3; i++) {
        await expectLater(client.request('010D'), throwsA(isA<TimeoutException>()));
      }
      expect(lost, 1);
      await expectLater(client.request('010D'), throwsA(isA<TimeoutException>()));
      expect(lost, 1, reason: 'reported once');
      await client.stop();
    });
  });

  group('the shared session', () {
    late FakeElm elm;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      elm = FakeElm(speed: 35);
      container = ProviderContainer(overrides: [obdTransportFactoryProvider.overrideWithValue((_) => elm)]);
      await container.read(obdAdapterStoreProvider).save([normalizeWifiAdapter(id: 'a', createdAt: 't').value!]);
    });

    tearDown(() => container.dispose());

    test('connects to the saved reader and reports fresh speed', () async {
      final session = container.read(obdSessionProvider.notifier);
      await session.ensureConnected();
      await pumpEventQueue();
      final s = container.read(obdSessionProvider);
      expect(s.phase, ObdPhase.online);
      expect(s.device, '192.168.0.10:35000');
      expect(s.telemetry['speed'], 35);
      expect(s.freshSpeed(s.lastUpdate!), 35);
      expect(s.freshSpeed(s.lastUpdate! + 10000), isNull, reason: 'stale readings are not billed on');
      expect((await container.read(obdAdapterStoreProvider).load()).single.lastConnectedAt, isNotNull);
      await session.disconnect();
      expect(container.read(obdSessionProvider).phase, ObdPhase.idle);
    });

    test('a link that drops shows as reconnecting and comes back by itself', () async {
      final session = container.read(obdSessionProvider.notifier);
      await session.ensureConnected();
      await pumpEventQueue();
      expect(container.read(obdSessionProvider).phase, ObdPhase.online);
      elm.silent = true;
      // Three unanswered sweeps (4 s each) report the link lost.
      await Future<void>.delayed(const Duration(seconds: 14));
      var s = container.read(obdSessionProvider);
      expect(s.phase, isNot(ObdPhase.error));
      expect(s.error, obdReconnectingMessage);
      elm.silent = false;
      await Future<void>.delayed(const Duration(seconds: 6));
      s = container.read(obdSessionProvider);
      expect(s.phase, ObdPhase.online);
      expect(s.error, isNull);
      await session.disconnect();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a reader that cannot be reached is an error, not a crash', () async {
      elm.refuseConnect = true;
      final session = container.read(obdSessionProvider.notifier);
      await session.ensureConnected();
      final s = container.read(obdSessionProvider);
      expect(s.phase, ObdPhase.error);
      expect(s.error, contains('Connection refused'));
      expect(s.freshSpeed(0), isNull);
      await session.disconnect();
    });

    test('with no saved reader nothing is attempted', () async {
      await container.read(obdAdapterStoreProvider).save(const []);
      await container.read(obdSessionProvider.notifier).ensureConnected();
      expect(container.read(obdSessionProvider).phase, ObdPhase.idle);
    });
  });
}

/// A Bluetooth reader that only answers once the link is retuned (the
/// first characteristic pair / write mode reaches nothing).
class _DeafUntilRetuned extends FakeElm implements ObdRetunable {
  _DeafUntilRetuned({this.ways = 2}) {
    deaf = true;
  }
  final int ways;
  bool deaf = false;
  int retunes = 0;

  @override
  Future<void> write(String command) async {
    if (deaf) {
      written.add(command);
      return;
    }
    await super.write(command);
  }

  @override
  Future<bool> retune() async {
    if (retunes + 1 >= ways) return false;
    retunes++;
    deaf = false;
    return true;
  }
}
