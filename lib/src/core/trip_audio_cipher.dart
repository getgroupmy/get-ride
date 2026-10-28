/// The sealed file a trip recording is kept in on the phone, the driver's
/// VoiceProtection and the rider's audio protection alike
/// (`lib/src/data/trip_audio_vault.dart`). Pure.
///
/// Each recording has its own random 256-bit key, kept in the phone's
/// Keychain (iOS) or Keystore-backed storage (Android), never next to the
/// file. The file is AES-256-CTR, then HMAC-SHA256 over the header and the
/// ciphertext (encrypt-then-MAC), with the cipher and MAC keys derived from
/// the recording's key, so a changed or swapped file is refused rather than
/// decrypted into noise:
///
///     "GRTA" | version 1 | IV (16) | ciphertext | tag (32)
///
/// Authenticated AES-GCM would do the same, but pointycastle's GCM runs well
/// under 1 MB/s in Dart, and an hour of speech is about 15 MB; CTR plus HMAC
/// is the same strength and runs in a second or two.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/stream/ctr.dart';

import 'rider_audio.dart' show riderAudioCipher;

const tripAudioKeyBytes = 32;
const _ivBytes = 16;
const _tagBytes = 32;
const _magic = [0x47, 0x52, 0x54, 0x41]; // "GRTA"
const _version = 1;
const _headerBytes = 4 + 1 + _ivBytes;

/// Why a sealed recording could not be opened.
class TripAudioCipherException implements Exception {
  const TripAudioCipherException(this.message);
  final String message;

  @override
  String toString() => 'TripAudioCipherException: $message';
}

/// [n] random bytes from the system's secure generator.
Uint8List tripAudioRandomBytes(int n, [math.Random? random]) {
  final r = random ?? math.Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Uint8List _derive(Uint8List key, String label) =>
    Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode('get.ride trip audio v$_version $label')).bytes);

Uint8List _ctr(Uint8List encKey, Uint8List iv, Uint8List data) =>
    (CTRStreamCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(encKey), iv))).process(data);

void _checkKey(Uint8List key) {
  if (key.length != tripAudioKeyBytes) throw const TripAudioCipherException('bad key');
}

/// Seals [plain] under [key] (32 bytes). [iv] is random unless a test sets it.
Uint8List sealTripAudio(Uint8List key, Uint8List plain, {Uint8List? iv}) {
  _checkKey(key);
  final nonce = iv ?? tripAudioRandomBytes(_ivBytes);
  final out = Uint8List(_headerBytes + plain.length + _tagBytes)
    ..setRange(0, 4, _magic)
    ..[4] = _version
    ..setRange(5, _headerBytes, nonce)
    ..setRange(_headerBytes, _headerBytes + plain.length, _ctr(_derive(key, 'enc'), nonce, plain));
  final tag = Hmac(sha256, _derive(key, 'mac')).convert(Uint8List.sublistView(out, 0, out.length - _tagBytes)).bytes;
  out.setRange(out.length - _tagBytes, out.length, tag);
  return out;
}

/// Whether [bytes] look like a sealed recording (not a 0315 rider file).
bool isSealedTripAudio(Uint8List bytes) =>
    bytes.length >= _headerBytes + _tagBytes &&
    bytes[0] == _magic[0] &&
    bytes[1] == _magic[1] &&
    bytes[2] == _magic[2] &&
    bytes[3] == _magic[3];

/// Opens a file [sealTripAudio] made. Throws [TripAudioCipherException] when
/// it isn't one, or the key or the file is not the one it was sealed with.
Uint8List openTripAudio(Uint8List key, Uint8List sealed) {
  _checkKey(key);
  if (!isSealedTripAudio(sealed)) throw const TripAudioCipherException('not a sealed recording');
  if (sealed[4] != _version) throw const TripAudioCipherException('unknown version');
  final body = sealed.length - _tagBytes;
  final want = Hmac(sha256, _derive(key, 'mac')).convert(Uint8List.sublistView(sealed, 0, body)).bytes;
  var diff = 0;
  for (var i = 0; i < _tagBytes; i++) {
    diff |= want[i] ^ sealed[body + i];
  }
  if (diff != 0) throw const TripAudioCipherException('wrong key, or the file was changed');
  final iv = Uint8List.sublistView(sealed, 5, _headerBytes);
  return _ctr(_derive(key, 'enc'), iv, Uint8List.sublistView(sealed, _headerBytes, body));
}

/// What secure storage holds for one recording: its key, and for a rider
/// recording sealed before the vault (migration 0315's HMAC keystream, no
/// tag) the nonce that file was made with.
class TripAudioSecret {
  const TripAudioSecret(this.key, {this.legacyNonce});

  final Uint8List key;
  final Uint8List? legacyNonce;

  bool get legacy => legacyNonce != null;

  String encode() =>
      legacy ? 'rider0315:${base64Encode(key)}:${base64Encode(legacyNonce!)}' : 'v1:${base64Encode(key)}';

  static TripAudioSecret? decode(String? raw) {
    if (raw == null) return null;
    try {
      final p = raw.split(':');
      if (p.length == 2 && p[0] == 'v1') return TripAudioSecret(base64Decode(p[1]));
      if (p.length == 3 && p[0] == 'rider0315') {
        return TripAudioSecret(base64Decode(p[1]), legacyNonce: base64Decode(p[2]));
      }
    } catch (_) {}
    return null;
  }

  /// The recording in [bytes], decrypted.
  Uint8List open(Uint8List bytes) => legacy ? riderAudioCipher(key, legacyNonce!, bytes) : openTripAudio(key, bytes);
}
