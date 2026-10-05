import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/session_telemetry.dart';
import 'package:get_ride/src/data/session_tracker.dart';

class _Sink implements SessionSink {
  final sessions = <Map<String, dynamic>>[];
  final locations = <Map<String, dynamic>>[];
  bool ipFails = false;

  @override
  Future<IpInfo?> lookupIp() async {
    if (ipFails) throw Exception('not deployed');
    return const IpInfo(publicIp: '1.2.3.4', ispProvider: 'TM Net', country: 'Malaysia');
  }

  @override
  Future<void> insertSession(Map<String, dynamic> row) async => sessions.add(row);

  @override
  Future<void> insertLocation(Map<String, dynamic> row) async => locations.add(row);
}

class _Location implements TelemetryLocation {
  bool granted = true;
  final asks = <bool>[];
  final stream = StreamController<TelemetryFix>.broadcast();
  TelemetryFix? fix = const TelemetryFix(latitude: 3.139, longitude: 101.6869, accuracy: 5);

  @override
  Future<bool> ensurePermission({required bool mayAsk}) async {
    asks.add(mayAsk);
    return granted;
  }

  @override
  Future<TelemetryFix?> current() async => fix;

  @override
  Stream<TelemetryFix> watch() => stream.stream;
}

const _device = DeviceSnapshot(osName: 'android', osVersion: '14', deviceType: 'phone', appVersion: '1.4.3');

void main() {
  group('locationRowDue', () {
    final t0 = DateTime(2026, 1, 1, 12);
    test('first row is always due', () => expect(locationRowDue(now: t0), isTrue));
    test('heartbeat after 30 s', () {
      expect(locationRowDue(lastWrite: t0, now: t0.add(const Duration(seconds: 29))), isFalse);
      expect(locationRowDue(lastWrite: t0, now: t0.add(const Duration(seconds: 30))), isTrue);
    });
    test('movement of 10 m after 5 s', () {
      final at = t0.add(const Duration(seconds: 6));
      expect(locationRowDue(lastWrite: t0, now: at, movedMeters: 12), isTrue);
      expect(locationRowDue(lastWrite: t0, now: at, movedMeters: 8), isFalse);
      expect(locationRowDue(lastWrite: t0, now: t0.add(const Duration(seconds: 3)), movedMeters: 50), isFalse);
    });
  });

  test('IpInfo.fromResponse reads ip-lookup and ignores empties', () {
    final ip = IpInfo.fromResponse({'public_ip': ' 1.2.3.4 ', 'isp_provider': 'Maxis', 'ip_city': ''});
    expect(ip!.publicIp, '1.2.3.4');
    expect(ip.ispProvider, 'Maxis');
    expect(ip.city, isNull);
    expect(IpInfo.fromResponse({'error': 'x'}), isNull);
    expect(IpInfo.fromResponse('nope'), isNull);
  });

  test('missingColumn names the column PostgREST rejected', () {
    expect(
      missingColumn("Could not find the 'isp_org' column of 'user_sessions' in the schema cache"),
      'isp_org',
    );
    expect(missingColumn('permission denied'), isNull);
  });

  test('sessionRow carries device, account and IP', () {
    final row = sessionRow(
      id: 's1',
      event: SessionEvent.login,
      deviceId: 'd1',
      device: _device,
      userId: 'u1',
      phone: '+60123',
      ip: const IpInfo(publicIp: '1.2.3.4'),
    );
    expect(row['event_type'], 'login');
    expect(row['user_id'], 'u1');
    expect(row['os_name'], 'android');
    expect(row['public_ip'], '1.2.3.4');
    expect(row['app_id'], 'com.taxxee.teksi');
    expect((row['raw'] as Map)['client'], 'flutter');
  });

  group('SessionTracker', () {
    late _Sink sink;
    late _Location location;
    late DateTime clock;
    late SessionTracker tracker;
    var ids = 0;

    setUp(() {
      sink = _Sink();
      location = _Location();
      clock = DateTime(2026, 1, 1, 12);
      ids = 0;
      tracker = SessionTracker(
        sink: sink,
        location: location,
        deviceId: () async => 'device-1',
        device: _device,
        now: () => clock,
        newId: () => 'sid-${++ids}',
      );
    });

    tearDown(() => tracker.dispose());

    test('logs the launch once, a login per new account and each resume', () async {
      await tracker.launched();
      await tracker.launched();
      await tracker.userChanged('u1', phone: '+601');
      await tracker.userChanged('u1', phone: '+601');
      await tracker.resumed();
      expect(sink.sessions.map((r) => r['event_type']), ['app_launch', 'login', 'app_relaunch']);
      expect(sink.sessions.first['user_id'], isNull);
      expect(sink.sessions[1]['user_id'], 'u1');
      expect(sink.sessions[1]['public_ip'], '1.2.3.4');
    });

    test('a resume before the launch is not logged', () async {
      await tracker.resumed();
      expect(sink.sessions, isEmpty);
    });

    test('an unreachable ip-lookup still logs the session', () async {
      sink.ipFails = true;
      await tracker.launched();
      expect(sink.sessions.single['public_ip'], isNull);
    });

    test('signing in writes a first fix tied to the login session', () async {
      await tracker.userChanged('u1', phone: '+601');
      expect(sink.locations, hasLength(1));
      expect(sink.locations.single['session_id'], 'sid-1');
      expect(sink.locations.single['device_id'], 'device-1');
      expect(sink.locations.single['latitude'], 3.139);
    });

    test('movement is throttled; a stationary phone waits for the heartbeat', () async {
      await tracker.userChanged('u1');
      expect(sink.locations, hasLength(1));
      // 2 s later, 1 km away: too soon.
      clock = clock.add(const Duration(seconds: 2));
      location.stream.add(const TelemetryFix(latitude: 3.148, longitude: 101.6869));
      await pumpEventQueue();
      expect(sink.locations, hasLength(1));
      // 6 s later, still 1 km away: written.
      clock = clock.add(const Duration(seconds: 4));
      location.stream.add(const TelemetryFix(latitude: 3.148, longitude: 101.6869));
      await pumpEventQueue();
      expect(sink.locations, hasLength(2));
      // 10 s later, 1 m away: not moved enough.
      clock = clock.add(const Duration(seconds: 10));
      location.stream.add(const TelemetryFix(latitude: 3.14801, longitude: 101.6869));
      await pumpEventQueue();
      expect(sink.locations, hasLength(2));
    });

    test('signing out stops tracking; permission is asked only once', () async {
      location.granted = false;
      await tracker.userChanged('u1');
      expect(sink.locations, isEmpty);
      await tracker.userChanged(null);
      location.granted = true;
      await tracker.userChanged('u2');
      expect(location.asks, [true, false]);
      expect(sink.locations, hasLength(1));
      await tracker.userChanged(null);
      clock = clock.add(const Duration(minutes: 1));
      location.stream.add(const TelemetryFix(latitude: 3.2, longitude: 101.7));
      await pumpEventQueue();
      expect(sink.locations, hasLength(1));
      expect(sink.sessions.map((r) => r['event_type']), ['login', 'login']);
    });
  });
}
