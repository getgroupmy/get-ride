// Keeping the closed-app live stream alive on Android (0405): an aggressive
// power manager (Xiaomi, Oppo, Vivo, Huawei, Samsung and others) can kill the
// background location service even while location is allowed all the time, so
// a trip's dot stops moving after the app is closed. The one lever the user has
// is to let the app run without battery limits. This reads that state and opens
// the settings screen where they can turn it off for our app — the plain list
// (ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), never the Play-restricted
// direct-ask, so it needs no special permission.
//
// iOS has no equivalent (and no API to read or change it), so this is a no-op
// there, reporting "unrestricted".
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether to nudge the user, once, to let the app run without battery limits.
/// Only on Android, only when the background reporter is actually armed (so the
/// nudge is relevant), only while the OS is still restricting the app, and never
/// after it has been shown once. Pure, so it is unit-tested.
bool shouldNudgeBatteryExemption({
  required bool android,
  required bool armed,
  required bool unrestricted,
  required bool alreadyNudged,
}) =>
    android && armed && !unrestricted && !alreadyNudged;

/// The native half (MainActivity.kt, the `get_ride/permissions` channel).
const batteryReliabilityChannel = MethodChannel('get_ride/permissions');

class BatteryReliability {
  const BatteryReliability({this.channel = batteryReliabilityChannel, this.supportedOverride});

  final MethodChannel channel;

  /// Tests: whether the platform has the native half.
  final bool? supportedOverride;

  /// Android has battery optimisation; nowhere else does.
  bool get supported => supportedOverride ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  /// True when the phone is not holding the app back (or there is no such
  /// setting). On any error, true — never nag on a false alarm.
  Future<bool> unrestricted() async {
    if (!supported) return true;
    try {
      return await channel.invokeMethod<bool>('batteryUnrestricted') ?? true;
    } catch (e) {
      debugPrint('[battery] not read: $e');
      return true;
    }
  }

  /// Opens the system screen to turn battery optimisation off for the app.
  Future<void> openSettings() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('openBatterySettings');
    } catch (e) {
      debugPrint('[battery] settings not opened: $e');
    }
  }
}
