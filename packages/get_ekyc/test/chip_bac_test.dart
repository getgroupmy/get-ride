import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ekyc/src/chip/bac.dart';

Uint8List hx(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String xh(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

void main() {
  // ICAO 9303 part 11, appendix D.1-D.4 (worked example)
  test('key seed and keys', () {
    final seed = keySeed('L898902C', '690806', '940623');
    expect(xh(seed), '239AB9CB282DAF66231DC5A4DF6BFBAE');
    expect(xh(deriveKey(seed, 1)), 'AB94FDECF2674FDFB9B391F85D7F76F2');
    expect(xh(deriveKey(seed, 2)), '7962D9ECE03D1ACD4C76089DCE131543');
    expect(xh(keySeed('L898902C', '1969-08-06', '1994-06-23')), xh(seed));
  });

  test('mutual authentication and session keys', () {
    final seed = keySeed('L898902C', '690806', '940623');
    final step = BacStep(
      deriveKey(seed, 1),
      deriveKey(seed, 2),
      hx('4608F91988702212'),
      hx('781723860C06C226'),
      hx('0B795240CB7049B01C19B33E32804F0B'),
    );
    expect(
      xh(step.command()),
      '72C29C2371CC9BDB65B779B8E8D37B29ECC154AA56A8799FAE2F498F76ED92F2'
      '5F1448EEA8AD90A7',
    );
    final sm = step.finish(hx('46B9342A41396CD7386BF5803104D7CEDC122B9132139BAF2EEDC94EE178534F2F2D235D074D7449'));
    expect(xh(sm.kEnc), '979EC13B1CBFE9DCD01AB0FED307EAE5');
    expect(xh(sm.kMac), 'F1CB1F1FB5ADF208806B89DC579DC1F8');
    expect(xh(sm.ssc), '887022120C06C226');
    // select EF.COM, protected, and the chip's answer
    expect(
      xh(sm.wrap(0x00, 0xA4, 0x02, 0x0C, data: [0x01, 0x1E])),
      '0CA4020C158709016375432908C044F68E08BF8B92D635FF24F800',
    );
    expect(sm.unwrap(hx('990290008E08FA855A5D4C50A8ED9000')), isEmpty);
  });

  test('a simulated chip: BAC, then a file read in chunks', () async {
    final file = Uint8List.fromList([0x61, 0x82, 0x01, 0x2C, ...List.generate(300, (i) => i & 0xFF)]);
    final seed = keySeed('A1234567', '900514', '301231');
    final kEnc = deriveKey(seed, 1), kMac = deriveKey(seed, 2);
    final rndIc = Uint8List.fromList(List.generate(8, (i) => 0x10 + i)),
        kIc = Uint8List.fromList(List.generate(16, (i) => 0x40 + i));
    SecureMessaging? chipSm;
    var selected = false;
    Uint8List ok(List<int> d) => Uint8List.fromList([...d, 0x90, 0x00]);
    Future<Uint8List> chip(Uint8List apdu) async {
      if (apdu[0] == 0x00 && apdu[1] == 0xA4) return ok([]);
      if (apdu[1] == 0x84) return ok(rndIc);
      if (apdu[1] == 0x82) {
        final e = apdu.sublist(5, 37);
        expect(xh(retailMac(kMac, e)), xh(apdu.sublist(37, 45)));
        final s = decrypt3des(kEnc, e);
        final rndIfd = s.sublist(0, 8), kIfd = s.sublist(16, 32);
        final r = encrypt3des(kEnc, Uint8List.fromList([...rndIc, ...rndIfd, ...kIc]));
        final ks = Uint8List.fromList([for (var i = 0; i < 16; i++) kIfd[i] ^ kIc[i]]);
        chipSm = SecureMessaging(
          deriveKey(ks, 1),
          deriveKey(ks, 2),
          Uint8List.fromList([...rndIc.sublist(4), ...rndIfd.sublist(4)]),
        );
        return ok([...r, ...retailMac(kMac, r)]);
      }
      // protected commands: the chip's side of secure messaging, written out
      final sm = chipSm!;
      sm.ssc.setAll(0, _inc(sm.ssc));
      List<int> resp;
      if (apdu[1] == 0xA4) {
        selected = true;
        resp = [];
      } else {
        expect(selected, isTrue);
        final off = (apdu[2] << 8) | apdu[3];
        final le = apdu[apdu.length - 14];
        resp = file.sublist(off, min(off + le, file.length));
      }
      sm.ssc.setAll(0, _inc(sm.ssc));
      final do87 = resp.isEmpty
          ? <int>[]
          : () {
              final enc = [0x01, ...encrypt3des(sm.kEnc, pad(resp))];
              return [
                0x87,
                ...(enc.length < 0x80 ? [enc.length] : [0x81, enc.length]),
                ...enc,
              ];
            }();
      final do99 = [0x99, 0x02, 0x90, 0x00];
      final mac = retailMac(sm.kMac, [...sm.ssc, ...do87, ...do99]);
      return ok([...do87, ...do99, 0x8E, 0x08, ...mac]);
    }

    // the terminal's counter runs one ahead of the chip copy above; give the chip its own counter
    final session = ChipSession(chip, random: Random(1));
    await session.openWithBac('A1234567', '1990-05-14', '2030-12-31');
    expect(await session.readFile(EF.dg1), file);
  });

  test('wrong passport details: the chip says no', () async {
    Future<Uint8List> chip(Uint8List apdu) async => Uint8List.fromList(
      apdu[1] == 0x84
          ? [1, 2, 3, 4, 5, 6, 7, 8, 0x90, 0x00]
          : apdu[1] == 0x82
          ? [0x63, 0x00]
          : [0x90, 0x00],
    );
    expect(
      () => ChipSession(chip).openWithBac('X', '000101', '000101'),
      throwsA(isA<ChipException>().having((e) => e.message, 'message', contains('do not open'))),
    );
  });
}

Uint8List _inc(Uint8List s) {
  final o = Uint8List.fromList(s);
  for (var i = o.length - 1; i >= 0; i--) {
    o[i] = (o[i] + 1) & 0xFF;
    if (o[i] != 0) break;
  }
  return o;
}
