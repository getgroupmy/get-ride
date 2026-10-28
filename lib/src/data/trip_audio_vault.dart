import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/trip_audio_cipher.dart';

/// Where each recording's key is kept, behind a seam so tests can stand in
/// for the phone's secure storage.
abstract class TripAudioKeyStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

/// The phone's Keychain (iOS) or Keystore-backed storage (Android).
///
/// iOS: readable after the first unlock since the phone started, so a trip
/// recorded with the screen locked can still be sealed and uploaded; never
/// synced to iCloud and never restored to another phone from a backup.
/// Android: AES-GCM with the key wrapped by the Android Keystore.
class SecureTripAudioKeyStore implements TripAudioKeyStore {
  const SecureTripAudioKeyStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'trip_audio_keys'),
    iOptions: IOSOptions(accountName: 'get_ride_trip_audio', accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<String?> read(String name) => _storage.read(key: name);

  @override
  Future<void> write(String name, String value) => _storage.write(key: name, value: value);

  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}

/// Keys held only while the app runs: where there is no Keychain or
/// Keystore. Trip audio is recorded on the phone apps only, so a browser or
/// a desktop build never seals anything with it.
class MemoryTripAudioKeyStore implements TripAudioKeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async => values[name] = value;

  @override
  Future<void> delete(String name) async => values.remove(name);
}

bool get _phone => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

// Off the UI thread: an hour of speech is about 15 MB.
void _sealFile(({String raw, String out, Uint8List key}) a) =>
    File(a.out).writeAsBytesSync(sealTripAudio(a.key, File(a.raw).readAsBytesSync()), flush: true);

Uint8List _openFile(({String path, String secret}) a) =>
    TripAudioSecret.decode(a.secret)!.open(File(a.path).readAsBytesSync());

/// One store for every trip recording on the phone, the driver's and the
/// rider's: each file sealed with its own key ([TripAudioSecret]), the key
/// in secure storage under the recording's id. A recording is decrypted
/// only in memory, for an upload support asked for; its file and key go
/// together.
class TripAudioVault {
  TripAudioVault([TripAudioKeyStore? keys]) : keys = keys ?? (_phone ? const SecureTripAudioKeyStore() : MemoryTripAudioKeyStore());

  final TripAudioKeyStore keys;

  static String keyName(String id) => 'trip_audio_key_$id';

  /// Seals the finished recording at [rawPath] into [outPath] under a fresh
  /// key, then deletes the plain file. Nothing is left behind on a failure
  /// but the plain file (which the caller deletes).
  Future<void> seal(String id, String rawPath, String outPath) async {
    final key = tripAudioRandomBytes(tripAudioKeyBytes);
    await keys.write(keyName(id), TripAudioSecret(key).encode());
    try {
      await compute(_sealFile, (raw: rawPath, out: outPath, key: key));
    } catch (_) {
      await _deleteFile(outPath);
      await _forget(id);
      rethrow;
    }
    await _deleteFile(rawPath);
  }

  /// Whether a key is held for [id].
  Future<bool> holds(String id) async => TripAudioSecret.decode(await keys.read(keyName(id))) != null;

  /// The recording [id] at [path], decrypted in memory. Throws when its key
  /// is gone or the file is not the one sealed under it.
  Future<Uint8List> open(String id, String path) async {
    final secret = await keys.read(keyName(id));
    if (TripAudioSecret.decode(secret) == null) throw const TripAudioCipherException('no key for this recording');
    return compute(_openFile, (path: path, secret: secret!));
  }

  /// Keeps the key of a rider recording sealed before the vault (0315).
  Future<void> adopt(String id, TripAudioSecret secret) => keys.write(keyName(id), secret.encode());

  /// Deletes the recording's file (when given) and its key.
  Future<void> delete(String id, {String? path}) async {
    if (path != null) await _deleteFile(path);
    await _forget(id);
  }

  Future<void> _forget(String id) async {
    try {
      await keys.delete(keyName(id));
    } catch (_) {}
  }

  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

final tripAudioVaultProvider = Provider((_) => TripAudioVault());
