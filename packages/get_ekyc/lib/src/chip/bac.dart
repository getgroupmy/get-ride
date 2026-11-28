// Basic Access Control and secure messaging for ePassport / eMRTD chips
// (ICAO 9303 part 11, sections 4.3 and 9.8). Pure Dart: the NFC link is the
// `Transceive` function given to [ChipSession], so this is tested without a
// phone against ICAO's own worked example.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Sends one command APDU to the chip and returns its whole response (data + SW1 SW2).
typedef Transceive = Future<Uint8List> Function(Uint8List apdu);

class ChipException implements Exception {
  ChipException(this.message, [this.sw]);
  final String message;
  final int? sw;
  @override
  String toString() => sw == null ? message : '$message (SW ${sw!.toRadixString(16).padLeft(4, '0')})';
}

Uint8List _b(List<int> x) => Uint8List.fromList(x);
Uint8List _cat(List<List<int>> parts) => _b([for (final p in parts) ...p]);

Uint8List _sha1(List<int> d) => SHA1Digest().process(_b(d));

/// The MRZ check digit (weights 7 3 1).
int checkDigit(String s) {
  const w = [7, 3, 1];
  var sum = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final v = c >= 48 && c <= 57 ? c - 48 : (c >= 65 && c <= 90 ? c - 55 : 0);
    sum += v * w[i % 3];
  }
  return sum % 10;
}

/// "yyyy-mm-dd" or "yymmdd" as the MRZ's YYMMDD.
String mrzDate(String d) {
  final digits = d.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length == 8) return digits.substring(2);
  if (digits.length == 6) return digits;
  throw ArgumentError('date must be yyyy-mm-dd or yymmdd: $d');
}

/// K_seed from the document number, date of birth and expiry printed in the MRZ.
Uint8List keySeed(String documentNumber, String birth, String expiry) {
  final n = documentNumber.toUpperCase().replaceAll(' ', '').padRight(9, '<');
  final dob = mrzDate(birth), exp = mrzDate(expiry);
  final info = '$n${checkDigit(n)}$dob${checkDigit(dob)}$exp${checkDigit(exp)}';
  return _sha1(ascii.encode(info)).sublist(0, 16);
}

Uint8List _parity(Uint8List k) {
  final out = Uint8List.fromList(k);
  for (var i = 0; i < out.length; i++) {
    final b = out[i] & 0xFE;
    var ones = 0;
    for (var j = 1; j < 8; j++) {
      if ((b >> j) & 1 == 1) ones++;
    }
    out[i] = b | (ones % 2 == 0 ? 1 : 0);
  }
  return out;
}

/// The 16-byte 3DES key for counter 1 (encryption) or 2 (MAC).
Uint8List deriveKey(Uint8List seed, int counter) => _parity(_sha1([...seed, 0, 0, 0, counter]).sublist(0, 16));

Uint8List pad(List<int> d) {
  final out = [...d, 0x80];
  while (out.length % 8 != 0) {
    out.add(0);
  }
  return _b(out);
}

Uint8List unpad(Uint8List d) {
  var i = d.length - 1;
  while (i >= 0 && d[i] == 0) {
    i--;
  }
  if (i < 0 || d[i] != 0x80) throw ChipException('bad padding');
  return d.sublist(0, i);
}

Uint8List _tripleDes(Uint8List key16, Uint8List data, bool encrypt) {
  final key = _cat([key16, key16.sublist(0, 8)]);
  final c = CBCBlockCipher(DESedeEngine())..init(encrypt, ParametersWithIV(KeyParameter(key), Uint8List(8)));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 8) {
    c.processBlock(data, off, out, off);
  }
  return out;
}

Uint8List encrypt3des(Uint8List key16, Uint8List data) => _tripleDes(key16, data, true);
Uint8List decrypt3des(Uint8List key16, Uint8List data) => _tripleDes(key16, data, false);

/// ISO 9797-1 MAC algorithm 3 (retail MAC) with padding method 2.
Uint8List retailMac(Uint8List key16, List<int> message) {
  final data = pad(message);
  final ka = key16.sublist(0, 8), kb = key16.sublist(8, 16);
  // single DES = 3DES with one key three times (PointyCastle has no plain DES engine)
  KeyParameter one(Uint8List k) => KeyParameter(_cat([k, k, k]));
  final des = CBCBlockCipher(DESedeEngine())..init(true, ParametersWithIV(one(ka), Uint8List(8)));
  var h = Uint8List(8);
  for (var off = 0; off < data.length; off += 8) {
    des.processBlock(data, off, h, 0);
  }
  final d = DESedeEngine()..init(false, one(kb));
  final t = Uint8List(8);
  d.processBlock(h, 0, t, 0);
  final e = DESedeEngine()..init(true, one(ka));
  final out = Uint8List(8);
  e.processBlock(t, 0, out, 0);
  return out;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

int _sw(Uint8List r) => r.length < 2 ? 0 : (r[r.length - 2] << 8) | r[r.length - 1];

/// The terminal's half of BAC's mutual authentication: the EXTERNAL
/// AUTHENTICATE data for the chip's challenge (kept for the reply check).
class BacStep {
  BacStep(this.kEnc, this.kMac, this.rndIc, this.rndIfd, this.kIfd);
  final Uint8List kEnc, kMac, rndIc, rndIfd, kIfd;

  Uint8List command() {
    final e = encrypt3des(kEnc, _cat([rndIfd, rndIc, kIfd]));
    return _cat([e, retailMac(kMac, e)]);
  }

  /// The session keys and send sequence counter, from the chip's reply.
  SecureMessaging finish(Uint8List reply) {
    if (reply.length != 40) throw ChipException('unexpected BAC reply');
    final r = reply.sublist(0, 32);
    if (!_same(retailMac(kMac, r), reply.sublist(32))) throw ChipException('BAC reply MAC is wrong');
    final s = decrypt3des(kEnc, r);
    if (!_same(s.sublist(0, 8), rndIc) || !_same(s.sublist(8, 16), rndIfd)) {
      throw ChipException('BAC: the chip did not answer our challenge');
    }
    final kIc = s.sublist(16, 32);
    final seed = _b([for (var i = 0; i < 16; i++) kIfd[i] ^ kIc[i]]);
    final ssc = _cat([rndIc.sublist(4), rndIfd.sublist(4)]);
    return SecureMessaging(deriveKey(seed, 1), deriveKey(seed, 2), ssc);
  }
}

/// 3DES secure messaging: wraps commands, checks and opens responses.
class SecureMessaging {
  SecureMessaging(this.kEnc, this.kMac, Uint8List ssc) : ssc = Uint8List.fromList(ssc);
  final Uint8List kEnc, kMac;
  final Uint8List ssc;

  void _inc() {
    for (var i = ssc.length - 1; i >= 0; i--) {
      ssc[i] = (ssc[i] + 1) & 0xFF;
      if (ssc[i] != 0) break;
    }
  }

  static List<int> _len(int n) => n < 0x80 ? [n] : (n < 0x100 ? [0x81, n] : [0x82, n >> 8, n & 0xFF]);

  /// cla ins p1 p2 [data] [le]: the protected APDU.
  Uint8List wrap(int cla, int ins, int p1, int p2, {List<int>? data, int? le}) {
    _inc();
    final header = [cla | 0x0C, ins, p1, p2];
    final do87 = <int>[];
    if (data != null && data.isNotEmpty) {
      final enc = [0x01, ...encrypt3des(kEnc, pad(data))];
      do87.addAll([0x87, ..._len(enc.length), ...enc]);
    }
    final do97 = le == null ? <int>[] : [0x97, 0x01, le & 0xFF];
    final mac = retailMac(kMac, [...ssc, ...pad(header), ...do87, ...do97]);
    final body = [...do87, ...do97, 0x8E, 0x08, ...mac];
    return _b([...header, body.length, ...body, 0x00]);
  }

  /// The plain response data of a protected response, or a [ChipException].
  Uint8List unwrap(Uint8List resp) {
    _inc();
    final sw = _sw(resp);
    if (sw != 0x9000) throw ChipException('the chip refused', sw);
    final body = resp.sublist(0, resp.length - 2);
    List<int>? do87, do99, mac;
    final macInput = <int>[...ssc];
    var i = 0;
    while (i < body.length) {
      final tag = body[i++];
      var n = body[i++];
      if (n == 0x81) {
        n = body[i++];
      } else if (n == 0x82) {
        n = (body[i] << 8) | body[i + 1];
        i += 2;
      }
      final v = body.sublist(i, i + n);
      final whole = body.sublist(i - (n < 0x80 ? 2 : (n < 0x100 ? 3 : 4)), i + n);
      i += n;
      if (tag == 0x87) {
        do87 = v;
        macInput.addAll(whole);
      } else if (tag == 0x99) {
        do99 = v;
        macInput.addAll(whole);
      } else if (tag == 0x8E) {
        mac = v;
      }
    }
    if (mac == null || !_same(retailMac(kMac, macInput), mac)) throw ChipException('response MAC is wrong');
    if (do99 != null && (do99.length != 2 || do99[0] != 0x90 || do99[1] != 0x00)) {
      throw ChipException('the chip refused', (do99[0] << 8) | do99[1]);
    }
    if (do87 == null) return Uint8List(0);
    return unpad(decrypt3des(kEnc, _b(do87.sublist(1))));
  }
}

/// eMRTD files by short id: EF.COM, EF.SOD, DG1 (MRZ), DG2 (face).
class EF {
  static const com = 0x011E, sod = 0x011D, dg1 = 0x0101, dg2 = 0x0102;
}

/// Opens the chip with BAC and reads files over secure messaging.
class ChipSession {
  ChipSession(this.transceive, {Random? random}) : _rnd = random ?? Random.secure();
  final Transceive transceive;
  final Random _rnd;
  SecureMessaging? _sm;

  static const aid = [0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01];

  Future<Uint8List> _plain(List<int> apdu) async {
    final r = await transceive(_b(apdu));
    final sw = _sw(r);
    if (sw != 0x9000) throw ChipException('the chip refused', sw);
    return r.sublist(0, r.length - 2);
  }

  Uint8List _random(int n) => _b(List.generate(n, (_) => _rnd.nextInt(256)));

  Future<void> openWithBac(String documentNumber, String birth, String expiry) async {
    await _plain([0x00, 0xA4, 0x04, 0x0C, aid.length, ...aid]);
    final seed = keySeed(documentNumber, birth, expiry);
    final rndIc = await _plain([0x00, 0x84, 0x00, 0x00, 0x08]);
    if (rndIc.length != 8) throw ChipException('bad chip challenge');
    final step = BacStep(deriveKey(seed, 1), deriveKey(seed, 2), rndIc, _random(8), _random(16));
    final reply = await transceive(_b([0x00, 0x82, 0x00, 0x00, 0x28, ...step.command(), 0x28]));
    final sw = _sw(reply);
    if (sw != 0x9000) {
      throw ChipException(sw == 0x6300 ? 'the passport details do not open this chip' : 'BAC refused', sw);
    }
    _sm = step.finish(reply.sublist(0, reply.length - 2));
  }

  Future<Uint8List> _sec(int ins, int p1, int p2, {List<int>? data, int? le}) async {
    final sm = _sm;
    if (sm == null) throw ChipException('the chip is not open');
    return sm.unwrap(await transceive(sm.wrap(0x00, ins, p1, p2, data: data, le: le)));
  }

  /// The whole file, read in chunks (offsets up to 32767, ample for DG1, DG2 and EF.SOD).
  Future<Uint8List> readFile(int fid) async {
    await _sec(0xA4, 0x02, 0x0C, data: [fid >> 8, fid & 0xFF]);
    final head = await _sec(0xB0, 0, 0, le: 4);
    if (head.length < 2) throw ChipException('empty file');
    var lenBytes = 1, total = head[1];
    if (head[1] == 0x81) {
      lenBytes = 2;
      total = head[2];
    } else if (head[1] == 0x82) {
      lenBytes = 3;
      total = (head[2] << 8) | head[3];
    }
    final size = 1 + lenBytes + total;
    final out = BytesBuilder()..add(head.sublist(0, min(head.length, size)));
    while (out.length < size) {
      final off = out.length;
      if (off > 0x7FFF) throw ChipException('file too large for short reads');
      final n = min(0xDF, size - off);
      final chunk = await _sec(0xB0, off >> 8, off & 0xFF, le: n);
      if (chunk.isEmpty) throw ChipException('chip stopped sending');
      out.add(chunk);
    }
    return out.toBytes().sublist(0, size);
  }
}
