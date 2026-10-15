// EV profiles (migration 0202): the models, reading ELM327 replies (single
// frame, multi-frame, headers on, refusals, NO DATA), detecting and reading
// a profile, and the generic capture script.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ev_profile.dart';

/// A scripted car behind an ELM327: answers by header and request.
class _Car {
  _Car(this.answers);

  /// "header|request" → reply (without the prompt).
  final Map<String, String> answers;
  String header = '';
  String protocol = '0';
  final sent = <String>[];
  bool gone = false;

  Future<String> send(String c) async {
    if (gone) throw StateError('The OBD-II reader is not connected.');
    sent.add(c);
    if (c == 'ATD') {
      header = '';
      protocol = '0';
    } else if (c.startsWith('ATSH')) {
      header = c.substring(4);
    } else if (c.startsWith('ATSP')) {
      protocol = c.substring(4);
    }
    if (c.startsWith('AT')) return 'OK\r\r>';
    return '${answers['$header|$c'] ?? (protocol == '0' ? 'SEARCHING...\rUNABLE TO CONNECT' : 'NO DATA')}\r\r>';
  }
}

const _soc = EvSignal(key: 'soc', header: '7E4', request: '220105', start: 2, length: 1, scale: 0.5);
const _odo = EvSignal(key: 'odometer_km', header: '7E4', request: '220105', start: 3, length: 3, scale: 0.1);

final _profile = EvProfile(
  id: 'p1',
  make: 'Testmake',
  model: 'Alpha',
  years: '2024-2025',
  active: true,
  init: const ['ATSP6'],
  detect: const EvDetect(request: '22F190', header: '7E4'),
  signals: const [
    _soc,
    _odo,
    EvSignal(key: 'range_km', header: '7E4', request: '220105', start: 0, length: 2, scale: 0.5),
    EvSignal(key: 'aux_voltage', header: '7E0', request: '220101', start: 0, length: 1, scale: 0.1),
  ],
);

const _multi = '00A\r0:62010501F4A0\r1:00112233445566';

void main() {
  group('replies', () {
    test('a single frame, headers off', () {
      expect(
        decodeEvSignal(const EvSignal(key: 'soc', header: '7E4', request: '220105', length: 2), '620105AB12\r\r>'),
        0xAB12,
      );
      expect(
        decodeEvSignal(const EvSignal(key: 'speed_kmh', header: '7DF', request: '010D'), '41 0D 32 \r\r>'),
        50,
        reason: 'spaces on (ATS1) read the same',
      );
      expect(decodeEvSignal(_soc, '220105\r6201050000C8\r\r>'), 100, reason: 'an echo is skipped');
    });

    test('a multi-frame answer ("00A", "0:", "1:") is put back together and cut to its length', () {
      final r = parseElmReply('$_multi\r\r>', request: '220105');
      expect(r.messages.single.bytes.length, 10);
      expect(r.dataAfter('620105'), [0x01, 0xF4, 0xA0, 0x00, 0x11, 0x22, 0x33]);
      expect(decodeEvSignal(_soc, _multi), 80);
      expect(decodeEvSignal(_odo, _multi), closeTo(438.6, 1e-9));
      expect(
        decodeEvSignal(const EvSignal(key: 'soc', header: '7E4', request: '220105', start: 6, length: 2), _multi),
        isNull,
        reason: 'past the 10 bytes the count line gives',
      );
      final spaced = parseElmReply('00A \r0: 62 01 05 01 F4 A0 \r1: 00 11 22 33 44 55 66 \r\r>');
      expect(spaced.dataAfter('620105'), [0x01, 0xF4, 0xA0, 0x00, 0x11, 0x22, 0x33]);
    });

    test('headers on: ISO-TP frames by sender, 11-bit and 29-bit', () {
      const eleven = '7EC 10 0A 62 01 05 01 F4 A0\r7EC 21 00 11 22 33 AA AA AA\r\r>';
      final r = parseElmReply(eleven);
      expect(r.senders, ['7EC']);
      expect(r.dataAfter('620105'), [0x01, 0xF4, 0xA0, 0x00, 0x11, 0x22, 0x33]);
      expect(decodeEvSignal(_soc, eleven), 80);
      const single = '7E8 03 41 0D 32\r7E9 03 41 0D 33';
      expect(parseElmReply(single).senders, ['7E8', '7E9']);
      expect(parseElmReply(single).dataAfter('410D'), [0x32], reason: 'the first ECU that answered');
      const big = '18DAF1DB 10 0A 62 01 05 01 F4 A0\r18DAF1DB 21 00 11 22 33 AA AA AA';
      expect(parseElmReply(big).senders, ['18DAF1DB']);
      expect(decodeEvSignal(_odo, big), closeTo(438.6, 1e-9));
    });

    test('a refusal (7F), NO DATA, ?, CAN ERROR and STOPPED give no value', () {
      final refused = parseElmReply('7F2231\r\r>');
      expect(refused.negativeCode, 0x31);
      expect(decodeEvSignal(_soc, '7F2231\r\r>'), isNull);
      expect(parseElmReply('7EC 03 7F 22 31').negativeCode, 0x31);
      for (final (raw, problem) in [
        ('NO DATA\r\r>', 'NO DATA'),
        ('?\r\r>', '?'),
        ('CAN ERROR\r\r>', 'CAN ERROR'),
        ('STOPPED\r\r>', 'STOPPED'),
        ('SEARCHING...\rUNABLE TO CONNECT\r\r>', 'UNABLE TO CONNECT'),
        ('\r\r>', 'NO DATA'),
      ]) {
        final r = parseElmReply(raw);
        expect(r.messages, isEmpty, reason: raw);
        expect(r.problem, problem, reason: raw);
        expect(decodeEvSignal(_soc, raw), isNull, reason: raw);
      }
    });

    test('signed, scale, offset and one bit', () {
      const temp = EvSignal(key: 'battery_temp_c', header: '7E4', request: '220101', start: 0, signed: true);
      expect(decodeEvSignal(temp, '620101F4'), -12);
      expect(decodeEvSignal(temp.copyWith(signed: false), '620101F4'), 244);
      const current = EvSignal(
        key: 'hv_current',
        header: '7E4',
        request: '220101',
        length: 2,
        signed: true,
        scale: 0.1,
        offset: 5,
      );
      expect(decodeEvSignal(current, '620101FF9C'), closeTo(-10 + 5, 1e-9));
      const odo = EvSignal(key: 'odometer_km', header: '7E4', request: '22B002', length: 4);
      expect(decodeEvSignal(odo, '62B002FFFFFFFF'), 4294967295, reason: 'four unsigned bytes stay whole');
      expect(decodeEvSignal(odo.copyWith(signed: true), '62B002FFFFFFFF'), -1);
      const flag = EvSignal(key: 'charging', header: '7E4', request: '220101', start: 1, bit: 3);
      expect(decodeEvSignal(flag, '6201010008'), 1);
      expect(decodeEvSignal(flag, '62010100F7'), 0);
      const custom = EvSignal(key: 'soc', header: '7E4', request: '220101', reply: '620101AA', start: 0);
      expect(decodeEvSignal(custom, '620101AA50'), 80);
      expect(decodeEvSignal(custom, '620101BB50'), isNull, reason: 'the reply prefix given must match');
    });

    test('positive replies, headers and protocols', () {
      expect(positiveReplyPrefix('220105'), '620105');
      expect(positiveReplyPrefix('01 0d'), '410D');
      expect(positiveReplyPrefix('0902'), '4902');
      expect(evHeaderCommands('7e4'), ['ATSH7E4']);
      expect(evHeaderCommands('18DADBF1'), ['ATCP18', 'ATSHDADBF1']);
      expect(evProtocolFor('7DF'), 'ATSP6');
      expect(evProtocolFor('18DB33F1'), 'ATSP7');
    });

    test('values as the driver reads them', () {
      expect(formatEvValue('soc', 79.6), '80 %');
      expect(formatEvValue('range_km', 1312.4), '1,312 km');
      expect(formatEvValue('odometer_km', 12345.64), '12,345.6 km');
      expect(formatEvValue('odometer_km', 999.96), '1,000.0 km');
      expect(formatEvValue('charging', 1), 'Yes');
      expect(formatEvValue('aux_voltage', 12.46), '12.5 V');
      expect(
        evSummary(const EvSnapshot(values: {'soc': 80, 'odometer_km': 438.6, 'hv_voltage': 400})),
        'Battery 80 % · Odometer 438.6 km',
      );
    });
  });

  group('models', () {
    test('a profile goes to JSON and back, cleaned', () {
      expect(EvProfile.fromJson(_profile.toJson())!.toJson(), _profile.toJson());
      final odd = EvProfile.fromJson({
        'make': 'Testmake',
        'model': 'Beta',
        'init': ['atsp6', ' ', 'atsh 7e4', 7],
        'detect': {'request': '22 f1 90', 'header': '', 'expect': null},
        'signals': [
          {'key': 'soc', 'header': '7e4', 'request': '22 01 05', 'start': '4', 'length': 1, 'scale': '0.5'},
          'nonsense',
        ],
      })!;
      expect(odd.init, ['ATSP6', 'ATSH 7E4']);
      expect(odd.detect, const EvDetect(request: '22F190'));
      expect(odd.signals.single, const EvSignal(key: 'soc', header: '7E4', request: '220105', start: 4, scale: 0.5));
      expect(odd.title, 'Testmake Beta');
      expect(_profile.title, 'Testmake Alpha (2024-2025)');
      expect(EvProfile.fromJson({'make': 'x'}), isNull, reason: 'no model');
    });

    test('problems are said plainly, as the server checks them', () {
      expect(_profile.problems(), isEmpty);
      const blank = EvProfile(make: ' ', model: '', active: true, init: ['ATSP6; DROP']);
      expect(blank.problems(), [
        'Enter the make.',
        'Enter the model.',
        '"ATSP6; DROP" is not an AT command (e.g. ATSP6) or a hex request.',
        'An active profile needs a detect request.',
        'An active profile needs at least one signal.',
      ]);
      const bad = EvSignal(key: 'fuel', header: '7E', request: '22G1', start: 300, length: 6, bit: 9);
      expect(EvProfile(make: 'a', model: 'b', signals: const [bad]).problems(), [
        'Signal 1: Choose which value this is.',
        'Signal 1: The ECU header must be a CAN id such as 7E4 or 18DADBF1.',
        'Signal 1: The request must be hex, 1 to 8 bytes, e.g. 220105.',
        'Signal 1: The start byte must be from 0 to 255.',
        'Signal 1: The length must be 1 to 4 bytes.',
        'Signal 1: The bit must be from 0 to 7.',
      ]);
      expect(isEvInitCommand('ATSH7E4'), isTrue);
      expect(isEvInitCommand('1003'), isTrue);
      expect(isEvInitCommand('ATMA'), isTrue);
      expect(isEvInitCommand('ATSP6\rATZ'), isFalse);
    });

    test('a capture to JSON and back', () {
      const c = EvCapture(
        vehicle: 'Testmake Alpha 2024',
        batteryHint: '80%',
        reader: 'ELM327 v1.5',
        entries: [EvCaptureEntry(header: '7E4', request: '22F190', reply: '7EC 03 7F 22 31', ms: 80)],
      );
      final back = EvCapture.fromJson(c.toJson())!;
      expect(back.toJson(), c.toJson());
      expect(back.entries.single.refused, isTrue);
      expect(back.entries.single.answered, isFalse);
    });
  });

  group('talking to the car', () {
    Map<String, String> answers() => {'7E4|22F190': '62F1904C4A', '7E4|220105': _multi, '7E0|220101': '6201017C'};

    test('the profile whose detect request the car answers is found', () async {
      final car = _Car(answers());
      final other = _profile.copyWith(
        id: () => 'p2',
        detect: () => const EvDetect(request: '22F190', header: '7E0'),
      );
      final wrongExpect = _profile.copyWith(
        id: () => 'p3',
        detect: () => const EvDetect(request: '22F190', header: '7E4', expect: '62F19099'),
      );
      final found = await detectEvProfiles(EvBus(car.send), [other, _profile, wrongExpect]);
      expect([for (final p in found) p.id], ['p1']);
      expect(car.sent, containsAllInOrder(['ATSP6', 'ATSH7E4', '22F190']));
    });

    test('one pass reads every value, each request asked once, the header set only when it changes', () async {
      final car = _Car(answers());
      final bus = EvBus(car.send);
      await sendEvInit(bus, _profile);
      final snap = await readEvSnapshot(bus, _profile, at: 1000);
      expect(snap.soc, 80);
      expect(snap.odometerKm, closeTo(438.6, 1e-9));
      expect(snap.rangeKm, 250);
      expect(snap.auxVoltage, closeTo(12.4, 1e-9));
      expect(snap.at, 1000);
      expect(car.sent, ['ATSP6', 'ATSH7E4', '220105', 'ATSH7E0', '220101']);
      car.sent.clear();
      await readEvSnapshot(bus, _profile, at: 2000);
      expect(car.sent, ['ATSH7E4', '220105', 'ATSH7E0', '220101']);
    });

    test('a car that stopped answering gives an empty snapshot', () async {
      final car = _Car(const {})..protocol = '6';
      final snap = await readEvSnapshot(EvBus(car.send), _profile, at: 0);
      expect(snap.isEmpty, isTrue);
    });
  });

  group('capture for support', () {
    test('generic identifiers only, to the broadcast and standard ECU addresses', () {
      final script = evCaptureScript();
      expect(script.length, evCaptureHeaders.length * evCaptureRequests.length);
      expect({for (final s in script) s.request}, evCaptureRequests.toSet());
      expect({for (final s in script) s.header}, evCaptureHeaders.toSet());
      expect(evCaptureHeaders, containsAll(['7DF', '7E0', '7E7', '18DB33F1']));
      final withRange = evCaptureScript(range: const EvRangeScan(header: '7e4', from: 0x0100, to: 0x010F));
      expect(withRange.length, script.length + 16);
      expect(withRange.last.request, '22010F');
      expect(withRange.last.header, '7E4');
      expect(const EvRangeScan(header: '7E4', from: 0, to: 0x1000).problem, contains('At most'));
      expect(const EvRangeScan(header: 'X', from: 0, to: 1).problem, contains('CAN id'));
      expect(evCaptureScript(range: const EvRangeScan(header: '7E4', from: 2, to: 1)).length, script.length);
    });

    test('runs with headers on, sets each protocol, and gives the reader back its settings', () async {
      final car = _Car({'7E4|22F190': '7EC 05 62 F1 90 4C 4A', '7E0|22F190': '7E8 03 7F 22 31'})..protocol = '6';
      final progress = <int>[];
      final entries = await runEvCapture(car.send, evCaptureScript(), onProgress: (d, _, _) => progress.add(d));
      expect(entries.length, 60);
      expect(progress.first, 0);
      expect(progress.last, 60);
      expect(car.sent.first, 'ATH1');
      expect(car.sent.sublist(1, 4), ['ATSP6', 'ATSH7DF', '0100']);
      expect(car.sent, containsAllInOrder(['ATSP7', 'ATCP18', 'ATSHDB33F1', '0100']));
      expect(car.sent.sublist(car.sent.length - evRestoreCommands.length), evRestoreCommands);
      final s = summarizeEvCapture(entries);
      expect((s.answered, s.refused, s.silent), (1, 1, 58));
      expect(entries.firstWhere((e) => e.answered).header, '7E4');
    });

    test('cancelled part-way, and a reader that went away', () async {
      final car = _Car(const {});
      var asked = 0;
      final some = await runEvCapture(car.send, evCaptureScript(), shouldContinue: () => asked++ < 5);
      expect(some.length, 5);
      expect(car.sent.last, 'ATSP0', reason: 'restored even when cancelled');

      final gone = _Car(const {});
      var n = 0;
      Future<String> flaky(String c) {
        if (++n > 6) gone.gone = true;
        return gone.send(c);
      }

      await expectLater(runEvCapture(flaky, evCaptureScript()), throwsStateError);
    });
  });
}
