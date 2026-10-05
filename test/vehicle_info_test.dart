import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/obd_pid_catalog.dart';
import 'package:get_ride/src/core/vehicle_info.dart';

void main() {
  group('elmPayloads', () {
    test('returns one payload per single-frame line', () {
      expect(elmPayloads('41 00 BE 1F A8 13\r>'), ['4100BE1FA813']);
    });

    test('keeps one payload per responding ECU', () {
      expect(elmPayloads('410C1AF8\r410C1B00\r>'), ['410C1AF8', '410C1B00']);
    });

    test('re-joins an ISO-TP multi-frame block and drops its length header', () {
      const raw = '014\r0:490201314A\r1:4D3448\r>';
      expect(elmPayloads(raw), ['490201314A4D3448']);
    });

    test('drops SEARCHING and other non-hex noise', () {
      expect(elmPayloads('SEARCHING...\r410D3C\r>'), ['410D3C']);
    });
  });

  group('hexToBytes', () {
    test('parses whole bytes', () {
      expect(hexToBytes('1AF8'), [0x1a, 0xf8]);
    });

    test('rejects an odd number of digits and non-hex', () {
      expect(hexToBytes('1AF'), isNull);
      expect(hexToBytes('1AZZ'), isNull);
      expect(hexToBytes(''), isNull);
    });
  });

  group('extractFrameBytes', () {
    test('reads the bytes after a mode-01 header', () {
      expect(extractFrameBytes('410C1AF8\r>', '410C', 2), [0x1a, 0xf8]);
    });

    test('returns every remaining byte when no count is given', () {
      expect(extractFrameBytes('4902013144\r>', '4902'), [0x01, 0x31, 0x44]);
    });

    test('rejects a frame that is shorter than the requested byte count', () {
      expect(extractFrameBytes('410C1A\r>', '410C', 2), isNull);
    });

    test('returns null for an error reply', () {
      expect(extractFrameBytes('NO DATA\r>', '410C', 2), isNull);
    });
  });

  group('parseSupportedPids', () {
    // BE 1F A8 13 is the mask most petrol cars answer 0100 with.
    const raw = '41 00 BE 1F A8 13\r>';

    test('decodes the bitmask into PID numbers', () {
      final range = parseSupportedPids(raw, '00');
      expect(range?.base, '00');
      expect(range?.pids, [
        '01',
        '03',
        '04',
        '05',
        '06',
        '07',
        '0C',
        '0D',
        '0E',
        '0F',
        '10',
        '11',
        '13',
        '15',
        '1C',
        '1F',
        '20',
      ]);
    });

    test("reads the last bit as 'the next range is supported'", () {
      expect(parseSupportedPids(raw, '00')?.nextRangeSupported, isTrue);
      expect(parseSupportedPids('4100BE1FA812\r>', '00')?.nextRangeSupported, isFalse);
    });

    test("offsets PID numbers by the probe's base", () {
      // Only the very first bit set: base 0x20 + 1 = PID 21.
      expect(parseSupportedPids('412080000000\r>', '20')?.pids, ['21']);
    });

    test('reads a mode-09 support mask when told the response mode', () {
      expect(parseSupportedPids('4900540000 00\r>', '00', '49')?.pids, ['02', '04', '06']);
    });

    test('returns null when the frame is missing', () {
      expect(parseSupportedPids('NO DATA\r>', '00'), isNull);
    });
  });

  group('nextSupportRange', () {
    test('advances to the next probe when the mask says so', () {
      expect(nextSupportRange('00', const SupportedRange(base: '00', pids: [], nextRangeSupported: true)), '20');
    });

    test('stops when the mask says the next range is unsupported', () {
      expect(nextSupportRange('00', const SupportedRange(base: '00', pids: [], nextRangeSupported: false)), isNull);
    });

    test('stops at the end of the probe table', () {
      expect(nextSupportRange('E0', const SupportedRange(base: 'E0', pids: [], nextRangeSupported: true)), isNull);
    });

    test('stops on a failed probe', () {
      expect(nextSupportRange('00', null), isNull);
    });
  });

  group('mode 09 identity', () {
    // "1D4GP00R55B123456" across three ISO-TP frames, with the leading 0x01
    // message-count byte CAN vehicles prefix.
    const vinRaw = '014\r0:49020131443447\r1:5030305235354231\r2:3233343536\r>';

    test('decodes a multi-frame VIN', () {
      expect(parseMode09Ascii(vinRaw, '02'), '1D4GP00R55B123456');
    });

    test('decodes a single-frame ASCII reply without a count byte', () {
      expect(parseMode09Ascii('4904 41 42 43\r>', '04'), 'ABC');
    });

    test('strips NUL and 0xFF padding', () {
      expect(parseMode09Ascii('490A014142430000\r>', '0A'), 'ABC');
    });

    test('renders the CVN as hex rather than mangled text', () {
      expect(parseMode09Hex('4906 01 02 03 04\r>', '06'), '01 02 03 04');
    });

    test('returns null when nothing was answered', () {
      expect(parseMode09Ascii('NO DATA\r>', '02'), isNull);
    });

    test('lists the VIN first so the header can use it', () {
      expect(mode09Items[0].key, Mode09Key.vin);
    });
  });

  group('VIN validation and decoding', () {
    final now = DateTime.parse('2026-08-02T00:00:00Z');

    test('accepts a well-formed VIN and rejects the ambiguous letters', () {
      expect(isLikelyVin('1D4GP00R55B123456'), isTrue);
      expect(isLikelyVin('1D4GP00R55B12345I'), isFalse);
      expect(isLikelyVin('SHORT'), isFalse);
      expect(isLikelyVin(null), isFalse);
    });

    test('splits a VIN into its ISO 3779 fields', () {
      final details = decodeVin('1D4GP00R55B123456', now);
      expect(details?.wmi, '1D4');
      expect(details?.vds, 'GP00R5');
      expect(details?.plantCode, 'B');
      expect(details?.serial, '123456');
    });

    test('offers both candidate model years for a repeating year code', () {
      // Position 10 is "5" → 2005, and the code repeats 30 years later.
      expect(decodeVin('1D4GP00R55B123456', now)?.modelYears, [2005]);
      // "A" is 1980, 2010 and 2040: only the years up to next year are offered.
      expect(decodeVin('1D4GP00R5AB123456', now)?.modelYears, [1980, 2010]);
    });

    test('names the assembly region for a known manufacturer prefix', () {
      expect(decodeVin('PM2ABC1234D567890')?.region, 'Malaysia');
      expect(decodeVin('9XX1234567D567890')?.region, isNull);
    });

    test('refuses to decode a partial read', () {
      expect(decodeVin('1D4GP00R55B'), isNull);
      expect(decodeVin(null), isNull);
    });
  });

  group('diagnostic trouble codes', () {
    test('decodes the system letter and digits', () {
      expect(decodeDtc(0x01, 0x33), 'P0133');
      expect(decodeDtc(0x43, 0x21), 'C0321');
      expect(decodeDtc(0x84, 0x56), 'B0456');
      expect(decodeDtc(0xc1, 0x00), 'U0100');
    });

    test('treats a zero pair as padding, not a code', () {
      expect(decodeDtc(0x00, 0x00), isNull);
    });

    test('skips the CAN count byte', () {
      // 43 02 <P0133> <P0420>
      expect(parseDtcResponse('4302013304 20\r>', '43'), ['P0133', 'P0420']);
    });

    test('reads a non-CAN reply that has no count byte', () {
      expect(parseDtcResponse('43 01 33 00 00 00 00\r>', '43'), ['P0133']);
    });

    test('reports an empty list when the vehicle has no codes', () {
      expect(parseDtcResponse('4300\r>', '43'), isEmpty);
      expect(parseDtcResponse('NO DATA\r>', '43'), isEmpty);
    });

    test('de-duplicates codes reported by more than one ECU', () {
      expect(parseDtcResponse('43010133\r43010133\r>', '43'), ['P0133']);
    });

    test('reads the pending and permanent stores from their own headers', () {
      expect(parseDtcResponse('4701 0133\r>', '47'), ['P0133']);
      expect(parseDtcResponse('4A010133\r>', '4A'), ['P0133']);
      expect(dtcModes.map((m) => m.mode), ['03', '07', '0A']);
    });

    test('returns null when the reply could not be parsed at all', () {
      expect(parseDtcResponse('CAN ERROR\r>', '43'), isNull);
    });

    test('describes the family a code belongs to without inventing a diagnosis', () {
      expect(describeDtc('P0133'), contains('Powertrain'));
      expect(describeDtc('P0133'), contains('generic'));
      expect(describeDtc('P1133'), contains('manufacturer-specific'));
      expect(describeDtc('U0100'), contains('Network'));
    });
  });

  group('readiness monitors', () {
    // MIL on with 3 codes; misfire/fuel/components supported and complete;
    // catalyst + O2 sensor supported, catalyst incomplete.
    const bytes = [0x83, 0x07, 0x21, 0x01];

    ReadinessMonitor? find(MonitorStatus? status, String key) {
      for (final m in status?.monitors ?? const <ReadinessMonitor>[]) {
        if (m.key == key) return m;
      }
      return null;
    }

    test('reads the MIL flag and the stored-fault count', () {
      final status = parseMonitorStatus(bytes);
      expect(status?.milOn, isTrue);
      expect(status?.dtcCount, 3);
    });

    test('marks a continuous monitor complete when its incomplete bit is clear', () {
      final misfire = find(parseMonitorStatus(bytes), 'misfire');
      expect(misfire?.key, 'misfire');
      expect(misfire?.label, 'Misfire');
      expect(misfire?.supported, isTrue);
      expect(misfire?.complete, isTrue);
    });

    test('separates supported from complete for the non-continuous monitors', () {
      final status = parseMonitorStatus(bytes);
      final catalyst = find(status, 'catalyst');
      expect(catalyst?.supported, isTrue);
      expect(catalyst?.complete, isFalse);
      final oxygen = find(status, 'oxygenSensor');
      expect(oxygen?.supported, isTrue);
      expect(oxygen?.complete, isTrue);
    });

    test('switches to the diesel monitor set when the compression flag is set', () {
      final status = parseMonitorStatus([0x00, 0x0f, 0x03, 0x00]);
      expect(status?.compressionIgnition, isTrue);
      final keys = status?.monitors.map((m) => m.key).toList();
      expect(keys, contains('pmFilter'));
      expect(keys, isNot(contains('catalyst')));
    });

    test('rejects a truncated frame', () {
      expect(parseMonitorStatus([0x83, 0x07]), isNull);
    });

    test('reads the frame straight out of a raw reply', () {
      expect(parseMonitorStatusResponse('41 01 83 07 21 01\r>')?.dtcCount, 3);
      expect(parseMonitorStatusResponse('NO DATA\r>'), isNull);
    });
  });

  group('parseAtText', () {
    test("keeps the adapter's own spacing and case", () {
      expect(parseAtText('ELM327 v1.5\r\r>'), 'ELM327 v1.5');
      expect(parseAtText('12.5V\r>'), '12.5V');
    });

    test('ignores a bare OK acknowledgement', () {
      expect(parseAtText('OK\r>'), isNull);
    });

    test('does not pass an error token off as a device description', () {
      expect(parseAtText('NO DATA\r>'), isNull);
      expect(parseAtText('?\r>'), isNull);
    });
  });

  group('write availability', () {
    final clear = findWriteAction(VehicleWriteId.clearDtc)!;
    final reset = findWriteAction(VehicleWriteId.resetAdapter)!;

    test('refuses every write with no link', () {
      final result = evaluateWriteAvailability(clear, const WriteContext(online: false, simulated: false));
      expect(result.allowed, isFalse);
      expect(result.reason, 'Connect the OBD-II reader first.');
    });

    test('refuses every write in Demo Mode', () {
      final result = evaluateWriteAvailability(clear, const WriteContext(online: true, simulated: true));
      expect(result.allowed, isFalse);
      expect(result.reason, contains('Demo Mode'));
    });

    test('refuses an ECU write while the vehicle is moving', () {
      final result = evaluateWriteAvailability(clear, const WriteContext(online: true, simulated: false, speedKmh: 32));
      expect(result.allowed, isFalse);
      expect(result.reason, contains('Stop the vehicle'));
    });

    test('still allows an adapter-only write while moving', () {
      final result = evaluateWriteAvailability(reset, const WriteContext(online: true, simulated: false, speedKmh: 32));
      expect(result.allowed, isTrue);
      expect(result.reason, isNull);
    });

    test('allows a clear when the vehicle is stationary', () {
      final result = evaluateWriteAvailability(clear, const WriteContext(online: true, simulated: false, speedKmh: 0));
      expect(result.allowed, isTrue);
      expect(result.reason, isNull);
    });

    test('treats an un-probed mode 04 as available but a refused one as blocked', () {
      expect(evaluateWriteAvailability(clear, const WriteContext(online: true, simulated: false)).allowed, isTrue);
      expect(
        evaluateWriteAvailability(
          clear,
          const WriteContext(online: true, simulated: false, supportsClearDtc: false),
        ).allowed,
        isFalse,
      );
    });

    test('gives every action a warning to show before it runs', () {
      for (final action in vehicleWriteActions) {
        expect(action.warningTitle, isNotEmpty);
        expect(action.warningBody, isNotEmpty);
        expect(action.confirmLabel, isNotEmpty);
      }
    });
  });

  group('validateRawCommand', () {
    test('normalises spacing and case', () {
      final check = validateRawCommand(' 01 0c ');
      expect(check.ok, isTrue);
      expect(check.command, '010C');
      expect(check.target, WriteTarget.vehicle);
      expect(check.write, isFalse);
    });

    test('routes AT and ST commands to the adapter', () {
      final at = validateRawCommand('atrv');
      expect(at.ok, isTrue);
      expect(at.target, WriteTarget.adapter);
      final st = validateRawCommand('STDI');
      expect(st.ok, isTrue);
      expect(st.target, WriteTarget.adapter);
    });

    test('flags the OBD-II services that write to the vehicle', () {
      expect(validateRawCommand('04').write, isTrue);
      expect(validateRawCommand('2F1234').write, isTrue);
      expect(validateRawCommand('0100').write, isFalse);
    });

    test('rejects an empty, over-long or non-alphanumeric command', () {
      expect(validateRawCommand('').ok, isFalse);
      expect(validateRawCommand('0' * 25).ok, isFalse);
      expect(validateRawCommand('01;0C').ok, isFalse);
    });

    test('rejects a half-byte or non-hex vehicle request', () {
      expect(validateRawCommand('010').ok, isFalse);
      expect(validateRawCommand('ZZ01').ok, isFalse);
    });
  });

  group('isWriteAcknowledged', () {
    test('accepts OK and the expected positive response', () {
      expect(isWriteAcknowledged('OK\r>'), isTrue);
      expect(isWriteAcknowledged('44\r>', '44'), isTrue);
    });

    test('rejects an error reply or a mismatched header', () {
      expect(isWriteAcknowledged('NO DATA\r>'), isFalse);
      expect(isWriteAcknowledged('7F0412\r>', '44'), isFalse);
      expect(isWriteAcknowledged('\r>'), isFalse);
    });
  });

  group('PID catalog', () {
    test('decodes a numeric parameter with its unit and precision', () {
      expect(formatCatalogValue(pidCatalog['42']!, [0x36, 0x0a]), '13.834 V');
      expect(formatCatalogValue(pidCatalog['05']!, [0x7b]), '83 °C');
    });

    test('decodes a signed fuel trim either side of zero', () {
      expect(formatCatalogValue(pidCatalog['06']!, [128]), '0.0 %');
      expect(formatCatalogValue(pidCatalog['06']!, [0]), '-100.0 %');
    });

    test('renders an enumerated parameter as text, without a unit', () {
      expect(formatCatalogValue(pidCatalog['51']!, [4]), 'Diesel');
      expect(formatCatalogValue(pidCatalog['03']!, [2, 0]), contains('Closed loop'));
    });

    test('names an unknown enumeration rather than guessing', () {
      expect(formatCatalogValue(pidCatalog['51']!, [0xee]), 'Unknown (0xEE)');
    });

    test('decodes the four-byte odometer', () {
      expect(formatCatalogValue(pidCatalog['A6']!, [0x00, 0x01, 0x86, 0xa0]), '10000.0 km');
    });

    test('looks PIDs up case-insensitively', () {
      expect(catalogPid('a6'), same(pidCatalog['A6']));
      expect(catalogPid('FF'), isNull);
    });

    test('renders raw bytes for a PID it does not know', () {
      expect(formatRawBytes([0x1a, 0xf8, 0x00]), '1A F8 00');
    });

    test('keys every entry by its own PID', () {
      for (final MapEntry(:key, value: pid) in pidCatalog.entries) {
        expect(pid.pid, key);
        expect(pid.bytes, greaterThan(0));
        expect(pid.decode != null || pid.decodeText != null, isTrue);
      }
    });
  });
}
