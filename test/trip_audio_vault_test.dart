// The on-phone store for trip recordings, the driver's and the rider's
// (trip_audio_cipher.dart, trip_audio_vault.dart): the sealed file, its key
// in secure storage, tamper detection, the key going with the file, and the
// move of 0315's rider keys out of SharedPreferences.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/rider_audio.dart';
import 'package:get_ride/src/core/trip_audio_cipher.dart';
import 'package:get_ride/src/data/rider_audio_repository.dart';
import 'package:get_ride/src/data/trip_audio_vault.dart';
import 'package:get_ride/src/data/voice_protection_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _audio(int n) => Uint8List.fromList(List<int>.generate(n, (i) => (i * 7 + 3) % 256));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the sealed file', () {
    final key = tripAudioRandomBytes(tripAudioKeyBytes);

    test('round trip, and the file is not the audio', () {
      for (final n in [0, 1, 15, 16, 17, 1000, 70000]) {
        final plain = _audio(n);
        final sealed = sealTripAudio(key, plain);
        expect(sealed.length, n + 4 + 1 + 16 + 32);
        expect(isSealedTripAudio(sealed), isTrue);
        expect(openTripAudio(key, sealed), plain);
      }
      final a = sealTripAudio(key, _audio(64));
      final b = sealTripAudio(key, _audio(64));
      expect(a, isNot(b), reason: 'a fresh IV each time');
      expect(String.fromCharCodes(a.sublist(21, 85)), isNot(String.fromCharCodes(_audio(64))));
    });

    test('a wrong key is refused', () {
      final sealed = sealTripAudio(key, _audio(500));
      expect(
        () => openTripAudio(tripAudioRandomBytes(tripAudioKeyBytes), sealed),
        throwsA(isA<TripAudioCipherException>()),
      );
      expect(() => openTripAudio(Uint8List(5), sealed), throwsA(isA<TripAudioCipherException>()));
    });

    test('any change to the file is caught', () {
      final sealed = sealTripAudio(key, _audio(500));
      for (final i in [5, 20, 21, 300, sealed.length - 33, sealed.length - 1]) {
        final bad = Uint8List.fromList(sealed)..[i] ^= 0x01;
        expect(() => openTripAudio(key, bad), throwsA(isA<TripAudioCipherException>()), reason: 'byte $i');
      }
      expect(() => openTripAudio(key, sealed.sublist(0, sealed.length - 1)), throwsA(isA<TripAudioCipherException>()));
      expect(() => openTripAudio(key, _audio(10)), throwsA(isA<TripAudioCipherException>()));
      final v2 = Uint8List.fromList(sealed)..[4] = 2;
      expect(() => openTripAudio(key, v2), throwsA(isA<TripAudioCipherException>()));
    });

    test('the secret as kept in secure storage', () {
      final s = TripAudioSecret.decode(TripAudioSecret(key).encode())!;
      expect(s.key, key);
      expect(s.legacy, isFalse);
      final nonce = tripAudioRandomBytes(16);
      final l = TripAudioSecret.decode(TripAudioSecret(key, legacyNonce: nonce).encode())!;
      expect(l.legacy, isTrue);
      expect(l.legacyNonce, nonce);
      final plain = _audio(100);
      expect(l.open(riderAudioCipher(key, nonce, plain)), plain, reason: 'a 0315 file still opens');
      expect(TripAudioSecret.decode(null), isNull);
      expect(TripAudioSecret.decode('nonsense'), isNull);
      expect(TripAudioSecret.decode('v1:%%%'), isNull);
    });
  });

  group('the vault', () {
    late Directory dir;
    late MemoryTripAudioKeyStore keys;
    late TripAudioVault vault;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('trip_audio_vault_test');
      keys = MemoryTripAudioKeyStore();
      vault = TripAudioVault(keys);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    String raw(String name, Uint8List bytes) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return f.path;
    }

    test('seals with a fresh key per recording, deletes the plain file, opens in memory', () async {
      final plain = _audio(5000);
      final a = raw('a.m4a', plain), b = raw('b.m4a', plain);
      await vault.seal('a', a, '${dir.path}/a.enc');
      await vault.seal('b', b, '${dir.path}/b.enc');
      expect(File(a).existsSync(), isFalse);
      expect(File(b).existsSync(), isFalse);
      expect(File('${dir.path}/a.enc').readAsBytesSync(), isNot(plain));
      expect(keys.values.keys, unorderedEquals([TripAudioVault.keyName('a'), TripAudioVault.keyName('b')]));
      expect(keys.values['trip_audio_key_a'], isNot(keys.values['trip_audio_key_b']));
      expect(await vault.holds('a'), isTrue);
      expect(await vault.open('a', '${dir.path}/a.enc'), plain);
      expect(await vault.open('b', '${dir.path}/b.enc'), plain);
    });

    test('a missing or wrong key, or a changed file, does not open', () async {
      await vault.seal('a', raw('a.m4a', _audio(300)), '${dir.path}/a.enc');
      await vault.seal('b', raw('b.m4a', _audio(300)), '${dir.path}/b.enc');
      expect(() => vault.open('b', '${dir.path}/a.enc'), throwsA(isA<TripAudioCipherException>()));
      expect(() => vault.open('zzz', '${dir.path}/a.enc'), throwsA(isA<TripAudioCipherException>()));

      final f = File('${dir.path}/b.enc');
      final bytes = f.readAsBytesSync()..[100] ^= 0x80;
      f.writeAsBytesSync(bytes);
      expect(() => vault.open('b', f.path), throwsA(isA<TripAudioCipherException>()));
    });

    test('deleting a recording takes its key with it', () async {
      await vault.seal('a', raw('a.m4a', _audio(30)), '${dir.path}/a.enc');
      await vault.delete('a', path: '${dir.path}/a.enc');
      expect(File('${dir.path}/a.enc').existsSync(), isFalse);
      expect(keys.values, isEmpty);
      expect(await vault.holds('a'), isFalse);
      await vault.delete('a', path: '${dir.path}/a.enc'); // twice is fine
    });

    test('a failed seal leaves no key and no sealed file', () async {
      await expectLater(vault.seal('a', '${dir.path}/missing.m4a', '${dir.path}/a.enc'), throwsA(anything));
      expect(keys.values, isEmpty);
      expect(File('${dir.path}/a.enc').existsSync(), isFalse);
    });

    test("on the phone's secure storage (the plugin's own stand-in)", () async {
      FlutterSecureStorage.setMockInitialValues({});
      final secure = TripAudioVault(const SecureTripAudioKeyStore());
      await secure.seal('s', raw('s.m4a', _audio(77)), '${dir.path}/s.enc');
      expect(await const FlutterSecureStorage().read(key: 'trip_audio_key_s'), startsWith('v1:'));
      expect(await secure.open('s', '${dir.path}/s.enc'), _audio(77));
      await secure.delete('s', path: '${dir.path}/s.enc');
      expect(await const FlutterSecureStorage().read(key: 'trip_audio_key_s'), isNull);
    });

    test("the driver's store reads a sealed file and a plain one from before", () async {
      final store = VoiceDeviceStore(vault);
      await vault.seal('new', raw('new.m4a', _audio(40)), '${dir.path}/new.enc');
      final old = raw('old.m4a', _audio(50));
      expect(await store.read('new', '${dir.path}/new.enc'), _audio(40));
      expect(await store.read('old', old), _audio(50));
      await store.delete('${dir.path}/new.enc', id: 'new');
      expect(keys.values, isEmpty);
    });
  });

  group("moving 0315's rider keys", () {
    late Directory dir;
    late MemoryTripAudioKeyStore keys;
    late RiderAudioDeviceStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('trip_audio_migrate_test');
      keys = MemoryTripAudioKeyStore();
      store = RiderAudioDeviceStore(TripAudioVault(keys));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('out of SharedPreferences into secure storage; the old file still opens', () async {
      final key = tripAudioRandomBytes(32), nonce = tripAudioRandomBytes(16);
      final plain = _audio(900);
      final path = '${dir.path}/old.enc';
      File(path).writeAsBytesSync(riderAudioCipher(key, nonce, plain));
      final expires = DateTime.utc(2100);
      final legacy = '{"old": {"path": "$path", "key": "${_b64(key)}", "nonce": "${_b64(nonce)}", '
          '"expires": "${expires.toIso8601String()}"}, '
          '"new": {"path": "${dir.path}/new.enc", "expires": "${expires.toIso8601String()}"}}';
      SharedPreferences.setMockInitialValues({riderAudioManifestKey: legacy});

      await store.migrateKeys();
      final prefs = await SharedPreferences.getInstance();
      final after = prefs.getString(riderAudioManifestKey)!;
      expect(after, isNot(contains('key')));
      expect(after, isNot(contains('nonce')));
      expect(after, isNot(contains(_b64(key))));
      final m = await store.manifest();
      expect(m.keys, unorderedEquals(['old', 'new']));
      expect(m['old']!.path, path);
      expect(m['old']!.expiresAt, expires);
      expect(keys.values.keys, ['trip_audio_key_old']);

      expect(await store.open('old', m['old']!), plain);
      await store.delete(path, id: 'old');
      expect(keys.values, isEmpty);

      await store.migrateKeys(); // nothing left to move
      expect(prefs.getString(riderAudioManifestKey), after);
    });

    test('a key that cannot be moved stays until the next start', () async {
      final failing = RiderAudioDeviceStore(TripAudioVault(_FailingKeys()));
      final legacy = '{"old": {"path": "/p/old.enc", "key": "AQI=", "nonce": "Aw==", "expires": "2100-01-01T00:00:00.000Z"}}';
      SharedPreferences.setMockInitialValues({riderAudioManifestKey: legacy});
      await failing.migrateKeys();
      expect((await failing.manifest())['old']!.hasLegacyKey, isTrue);
    });
  });
}

String _b64(Uint8List b) => base64Encode(b);

class _FailingKeys implements TripAudioKeyStore {
  @override
  Future<String?> read(String name) async => null;

  @override
  Future<void> write(String name, String value) => Future.error(StateError('locked'));

  @override
  Future<void> delete(String name) async {}
}
