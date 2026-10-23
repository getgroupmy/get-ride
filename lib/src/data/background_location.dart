// "Always on" (migration 0272): a phone whose location is already set to
// "Allow all the time" (Android) or "Always" (iPhone) keeps telling the
// server where it is while the app is in the background or closed, about
// every 15 minutes or after a move of about 200 m (backgroundReportDue), so
// Admin -> God View shows it as Always on. Never asks for the permission.
//
// The work is native, because a closed app runs no Dart:
//   * Android: BackgroundLocation.kt asks LocationManager for updates
//     delivered to BackgroundLocationReceiver (a PendingIntent the system
//     keeps after the app is closed; re-armed after a reboot or an update);
//   * iPhone: BackgroundLocationPlugin in AppDelegate.swift uses
//     significant location changes, which relaunch the app in the
//     background.
// Either one posts the fix to push_background_location with the install's
// random key, never the user's session; the server only knows the key's
// hash, set by the open app's check-in (PushService.checkIn) and dropped
// with the push token at sign-out.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The native half (BackgroundLocation.kt, AppDelegate.swift).
const backgroundLocationChannel = MethodChannel('get_ride/background_location');

/// A new background key: 32 random bytes as 64 hex characters.
String newBackgroundKey([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class BackgroundLocation {
  BackgroundLocation({this.channel = backgroundLocationChannel, this.supportedOverride});

  final MethodChannel channel;

  /// Tests: whether the platform has the native half.
  final bool? supportedOverride;

  static const keyPref = 'background_location_key';

  /// Android and iPhone builds only.
  bool get supported =>
      supportedOverride ??
      (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS));

  /// This install's key, made the first time it is needed.
  Future<String> key() async {
    final prefs = await SharedPreferences.getInstance();
    final kept = prefs.getString(keyPref);
    if (kept != null && kept.length >= 32) return kept;
    final made = newBackgroundKey();
    await prefs.setString(keyPref, made);
    return made;
  }

  /// Starts (or keeps) the native reporter for [key], posting to the project
  /// at [url] with its public [anonKey]. True when the phone took it; false
  /// on a build without the native half or without the permission.
  Future<bool> arm({required String url, required String anonKey, required String key}) async {
    if (!supported || url.isEmpty || anonKey.isEmpty) return false;
    try {
      return await channel.invokeMethod<bool>('arm', {'url': url, 'anonKey': anonKey, 'key': key}) ?? false;
    } catch (e) {
      debugPrint('[background location] not started: $e');
      return false;
    }
  }

  /// God View's "Live now" (migration 0282): the native half streams the
  /// position every 5 s until [until] or until the server says the share is
  /// over (LiveLocation.kt's foreground service; on an iPhone the reporter's
  /// continuous updates). Already streaming: nothing changes. False without
  /// the native half or the reporter armed.
  Future<bool> goLive(DateTime until) async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('live', {'until': until.millisecondsSinceEpoch}) ?? false;
    } catch (e) {
      debugPrint('[background location] live not started: $e');
      return false;
    }
  }

  /// Stops the native reporter. [forgetKey] (signing out): the next account
  /// on this phone gets a new key.
  Future<void> disarm({bool forgetKey = false}) async {
    if (supported) {
      try {
        await channel.invokeMethod<void>('disarm');
      } catch (_) {}
    }
    if (forgetKey) {
      try {
        await (await SharedPreferences.getInstance()).remove(keyPref);
      } catch (_) {}
    }
  }
}
