// Asks the phone where the app's permissions stand (core/app_permissions.dart),
// never prompting: Settings → Permissions, and the driver's go-online check.
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../core/app_permissions.dart';
import '../features/support/call/mic_gate.dart' show MicStatus, micPermissionProvider;
import 'push_service.dart';

/// The native half (AppDelegate.swift `PermissionsPlugin`, MainActivity.kt).
const permissionsChannel = MethodChannel('get_ride/permissions');

abstract class PermissionProbe {
  /// Where each of [permissionsFor] this platform stands.
  Future<Map<AppPermission, PermState>> statuses();

  /// Whether the phone's location is switched on, and the app's location
  /// permission.
  Future<(bool serviceOn, PermState location)> location();

  /// Whether the app may show notifications.
  Future<PermState> notifications();

  /// Asks for location: the system's question when never asked, and on an
  /// iPhone allowed only while in use, iOS's offer to change it to Always
  /// (shown once at most). Answers where it stands afterwards.
  Future<PermState> requestLocation();

  /// Asks Android for location all the time (background location), once
  /// location is allowed while in use. Answers where it stands afterwards.
  Future<PermState> requestLocationAlways();

  /// Asks for [p] where the phone can still show its question.
  Future<void> request(AppPermission p);

  /// The app's page in the phone's Settings.
  Future<bool> openAppSettings();

  /// The phone's Location settings (location switched off altogether).
  Future<bool> openLocationSettings();
}

final permissionProbeProvider = Provider<PermissionProbe>((ref) => DevicePermissionProbe(ref));

class DevicePermissionProbe implements PermissionProbe {
  DevicePermissionProbe(this._ref);
  final Ref _ref;

  bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<Map<String, dynamic>> _native() async {
    if (!_ios && !_android) return const {};
    try {
      return Map<String, dynamic>.from(await permissionsChannel.invokeMapMethod<String, dynamic>('statuses') ?? {});
    } catch (_) {
      // A build from before the native half.
      return const {};
    }
  }

  static PermState _ofLocation(LocationPermission p) => switch (p) {
    LocationPermission.always => PermState.granted,
    LocationPermission.whileInUse => PermState.limited,
    LocationPermission.deniedForever => PermState.denied,
    // Android can't tell "never asked" from "refused once" without asking.
    LocationPermission.denied => PermState.notAsked,
    LocationPermission.unableToDetermine => PermState.unknown,
  };

  @override
  Future<PermState> notifications() async {
    if (PushService.instance == null) return PermState.unknown;
    try {
      return switch ((await FirebaseMessaging.instance.getNotificationSettings()).authorizationStatus) {
        AuthorizationStatus.authorized || AuthorizationStatus.provisional => PermState.granted,
        AuthorizationStatus.denied || AuthorizationStatus.deniedPermanently => PermState.denied,
        AuthorizationStatus.notDetermined => PermState.notAsked,
      };
    } catch (_) {
      return PermState.unknown;
    }
  }

  @override
  Future<(bool, PermState)> location() async {
    try {
      final on = await Geolocator.isLocationServiceEnabled();
      // iOS says Always vs While Using itself; Geolocator does too elsewhere.
      if (_ios) {
        final native = permStateOf((await _native())['location']);
        if (native != PermState.unknown) return (on, native);
      }
      return (on, _ofLocation(await Geolocator.checkPermission()));
    } catch (_) {
      return (true, PermState.unknown);
    }
  }

  @override
  Future<Map<AppPermission, PermState>> statuses() async {
    final native = await _native();
    final out = <AppPermission, PermState>{};
    for (final p in permissionsFor(defaultTargetPlatform, web: kIsWeb)) {
      out[p] = switch (p) {
        AppPermission.notifications => await notifications(),
        AppPermission.location => (await location()).$2,
        AppPermission.microphone =>
          _ios
              ? switch (await _ref.read(micPermissionProvider).status()) {
                  MicStatus.granted => PermState.granted,
                  MicStatus.denied => PermState.denied,
                  MicStatus.undetermined => PermState.notAsked,
                  MicStatus.unknown => PermState.unknown,
                }
              : permStateOf(native['microphone']),
        AppPermission.camera => permStateOf(native['camera']),
        AppPermission.bluetooth => permStateOf(native['bluetooth']),
        AppPermission.fullScreenCalls => await _fullScreen(),
      };
    }
    return out;
  }

  Future<PermState> _fullScreen() async {
    try {
      return await FlutterCallkitIncoming.canUseFullScreenIntent() ? PermState.granted : PermState.denied;
    } catch (_) {
      return PermState.unknown;
    }
  }

  @override
  Future<PermState> requestLocation() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (_ios && p == LocationPermission.whileInUse) {
        return permStateOf(await permissionsChannel.invokeMethod<String>('requestLocationAlways'));
      }
      return (await location()).$2;
    } catch (_) {
      return (await location()).$2;
    }
  }

  @override
  Future<PermState> requestLocationAlways() async {
    try {
      if (_android && await Geolocator.checkPermission() == LocationPermission.whileInUse) {
        // Background location alone: Android 11+ ignores it asked together
        // with the foreground permission (MainActivity.kt).
        await permissionsChannel.invokeMethod<String>('requestLocationAlways');
      }
    } catch (_) {}
    return (await location()).$2;
  }

  @override
  Future<void> request(AppPermission p) async {
    try {
      switch (p) {
        case AppPermission.notifications:
          await FirebaseMessaging.instance.requestPermission();
          await PushService.instance?.recheckPermission();
        case AppPermission.location:
          await requestLocation();
        case AppPermission.microphone:
          await _ref.read(micPermissionProvider).ensure();
        case AppPermission.fullScreenCalls:
          await FlutterCallkitIncoming.requestFullIntentPermission();
        case AppPermission.camera:
        case AppPermission.bluetooth:
          // Asked by the scanner and the reader when first used.
          await openAppSettings();
      }
    } catch (_) {}
  }

  @override
  Future<bool> openAppSettings() async {
    if (kIsWeb) return false;
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openLocationSettings() async {
    if (kIsWeb) return false;
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }
}
