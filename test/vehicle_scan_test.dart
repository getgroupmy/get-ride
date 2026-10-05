import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/obd_pid_catalog.dart';
import 'package:get_ride/src/core/vehicle_info.dart';
import 'package:get_ride/src/core/vehicle_scan.dart';

/// A stub ELM327: answers the commands it has been given a reply for, and
/// "NO DATA" for everything else, exactly how a real vehicle behaves when it is
/// asked for a PID it does not implement.
({SendCommand send, List<String> sent}) fakeAdapter(Map<String, String> replies) {
  final sent = <String>[];
  Future<String> send(String command) async {
    sent.add(command);
    final reply = replies[command];
    if (reply == null) return 'NO DATA\r>';
    if (reply == 'THROW') throw StateError('link dropped');
    return reply;
  }

  return (send: send, sent: sent);
}

void main() {
  group('decodeReading', () {
    test('decodes a known PID with its label and unit', () {
      final reading = decodeReading('0C', '410C1AF8\r>');
      expect(reading?.pid, '0C');
      expect(reading?.label, 'Engine speed');
      expect(reading?.value, '1726 rpm');
      expect(reading?.group, PidGroup.engine);
      expect(reading?.known, isTrue);
      expect(reading?.numeric, 1726);
    });

    test('falls back to raw bytes for a PID the catalog does not know', () {
      final reading = decodeReading('C3', '41C3ABCD\r>');
      expect(reading?.pid, 'C3');
      expect(reading?.label, 'PID 01C3');
      expect(reading?.value, 'AB CD');
      expect(reading?.group, PidGroup.other);
      expect(reading?.known, isFalse);
      expect(reading?.numeric, isNull);
    });

    test('falls back to raw bytes when a known PID answers short', () {
      // The catalogue wants two bytes for 0C; this ECU sent one.
      final reading = decodeReading('0C', '410C1A\r>');
      expect(reading?.known, isFalse);
      expect(reading?.value, '1A');
    });

    test('returns null when the PID did not answer', () {
      expect(decodeReading('0C', 'NO DATA\r>'), isNull);
    });
  });

  group('groupReadings', () {
    test('orders sections and drops empty ones', () {
      const readings = [
        VehicleReading(pid: '0D', label: 'Vehicle speed', value: '0 km/h', group: PidGroup.vehicle, known: true),
        VehicleReading(pid: '0C', label: 'Engine speed', value: '800 rpm', group: PidGroup.engine, known: true),
      ];
      expect(groupReadings(readings, pidGroupOrder).map((s) => s.group), [PidGroup.engine, PidGroup.vehicle]);
    });
  });

  group('scanVehicle', () {
    const baseReplies = <String, String>{
      'ATI': 'ELM327 v1.5\r>',
      'ATRV': '12.5V\r>',
      // Supports PIDs 01, 05, 0C, 0D and 20 (so the next range is probed too).
      '0100': '4100 88 18 00 01\r>',
      // Second range: nothing supported, and no third range.
      '0120': '4120 00 00 00 00\r>',
      '0101': '4101 83 07 21 01\r>',
      '0105': '41057B\r>',
      '010C': '410C1AF8\r>',
      '010D': '410D00\r>',
      '0900': '490054000000\r>',
      '0902': '014\r0:49020131443447\r1:5030305235354231\r2:3233343536\r>',
      '0904': '4904 41 42 43\r>',
      '0906': '4906 01 02 03 04\r>',
      '03': '4302013304 20\r>',
      '07': '4700\r>',
      '0A': '4A00\r>',
    };

    test('reads the adapter, the supported PIDs, the identity and the codes', () async {
      final adapter = fakeAdapter(baseReplies);
      final report = await scanVehicle(adapter.send);

      expect(report.adapter.map((v) => (v.key, v.label, v.value)), [
        ('firmware', 'Adapter firmware', 'ELM327 v1.5'),
        ('batteryVoltage', 'Battery voltage (adapter)', '12.5V'),
      ]);
      expect(report.supportedPids, ['01', '05', '0C', '0D', '20']);
      expect(report.monitor?.dtcCount, 3);
      expect(report.vin, '1D4GP00R55B123456');
      expect(report.dtcs, {
        DtcStoreKey.stored: ['P0133', 'P0420'],
        DtcStoreKey.pending: <String>[],
        DtcStoreKey.permanent: <String>[],
      });
    });

    test('decodes each supported parameter and skips the structural PIDs', () async {
      final adapter = fakeAdapter(baseReplies);
      final report = await scanVehicle(adapter.send);

      expect(report.readings.map((r) => r.pid), ['05', '0C', '0D']);
      expect(report.readings.map((r) => r.value), ['83 °C', '1726 rpm', '0 km/h']);
      // 01 is the monitor frame and 20 is the next support mask: neither is a
      // reading, so neither is requested as one.
      expect(adapter.sent, isNot(contains('0101 ')));
      expect(adapter.sent.where((c) => c == '0120'), hasLength(1));
    });

    test('follows the support chain only while the mask says to', () async {
      final adapter = fakeAdapter(baseReplies);
      await scanVehicle(adapter.send);
      expect(adapter.sent, contains('0100'));
      expect(adapter.sent, contains('0120'));
      expect(adapter.sent, isNot(contains('0140')));
    });

    test('records a supported PID that refuses to answer instead of dropping it', () async {
      final adapter = fakeAdapter({...baseReplies, '010C': 'NO DATA\r>'});
      final report = await scanVehicle(adapter.send);
      expect(report.unreadablePids, ['0C']);
      expect(report.readings.map((r) => r.pid), ['05', '0D']);
    });

    test('survives a command that throws', () async {
      final adapter = fakeAdapter({...baseReplies, '010D': 'THROW'});
      final report = await scanVehicle(adapter.send);
      expect(report.unreadablePids, ['0D']);
      expect(report.readings.map((r) => r.pid), ['05', '0C']);
    });

    test('asks for the VIN anyway when the mode-09 support probe fails', () async {
      final replies = {...baseReplies}..remove('0900');
      final adapter = fakeAdapter(replies);
      final report = await scanVehicle(adapter.send);
      expect(adapter.sent, contains('0902'));
      expect(report.vin, '1D4GP00R55B123456');
    });

    test('skips a mode-09 item the vehicle says it does not implement', () async {
      // 0x80000000 → mode 09 PID 01 only.
      final adapter = fakeAdapter({...baseReplies, '0900': '490080000000\r>'});
      await scanVehicle(adapter.send);
      expect(adapter.sent, isNot(contains('0902')));
    });

    test('reports monotonic progress that never exceeds the total', () async {
      final adapter = fakeAdapter(baseReplies);
      final seen = <ScanProgress>[];
      await scanVehicle(adapter.send, options: ScanOptions(onProgress: seen.add));
      expect(seen, isNotEmpty);
      var last = 0;
      for (final p in seen) {
        expect(p.done, greaterThanOrEqualTo(last));
        expect(p.done, lessThanOrEqualTo(p.total));
        last = p.done;
      }
    });

    test('abandons the scan when the caller says to stop', () async {
      final adapter = fakeAdapter(baseReplies);
      var calls = 0;
      final report = await scanVehicle(
        adapter.send,
        shouldContinue: () {
          calls += 1;
          return calls <= 3;
        },
      );
      expect(adapter.sent.length, lessThan(5));
      expect(report.readings, isEmpty);
    });

    test('starts from a clean report every time', () async {
      final adapter = fakeAdapter(baseReplies);
      final first = await scanVehicle(adapter.send);
      final second = await scanVehicle(adapter.send);
      expect(second.adapter.map((v) => v.value), first.adapter.map((v) => v.value));
      expect(second.readings, hasLength(first.readings.length));
    });
  });
}
