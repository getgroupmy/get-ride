// What the app asks the phone for, and where each stands: Settings →
// Permissions, and the driver's check before going online. Pure.
import 'package:flutter/foundation.dart';

/// Where one permission stands. [limited] is location allowed only while
/// the app is open; [notAsked] has never been asked; [unknown] is a phone
/// that can't say.
enum PermState { granted, limited, denied, notAsked, unknown }

/// The permissions the app uses, in the order Settings lists them.
enum AppPermission {
  notifications('Notifications', 'Ride requests, calls and trip updates while GET.ride is closed.'),
  location('Location', 'Finding pickups, and sharing where you are while online or on a trip.'),
  microphone('Microphone', 'Calls with your driver, passenger or support, and voice notes.'),
  camera('Camera', 'Scanning QR codes and photographing your documents.'),
  bluetooth('Bluetooth', 'OBD-II readers and receipt printers for Meter Digital.'),
  fullScreenCalls('Full-screen calls', 'Ringing calls over the lock screen.');

  const AppPermission(this.title, this.why);
  final String title;
  final String why;
}

/// The permissions that apply on [platform] (full-screen calls are
/// Android's own; the web has only notifications and location).
List<AppPermission> permissionsFor(TargetPlatform platform, {bool web = false}) {
  if (web) return const [AppPermission.notifications, AppPermission.location];
  return [
    for (final p in AppPermission.values)
      if (p != AppPermission.fullScreenCalls || platform == TargetPlatform.android) p,
  ];
}

/// A status as the native side answers it ('granted', 'denied',
/// 'undetermined', and for location 'always' / 'whileInUse').
PermState permStateOf(Object? raw) => switch (raw) {
  'granted' || 'always' => PermState.granted,
  'whileInUse' => PermState.limited,
  'denied' => PermState.denied,
  'undetermined' => PermState.notAsked,
  _ => PermState.unknown,
};

/// The words beside a permission in Settings.
String permStateLabel(AppPermission p, PermState s) => switch (s) {
  PermState.granted => p == AppPermission.location ? 'Always' : 'Allowed',
  PermState.limited => 'While using the app',
  PermState.denied => 'Off',
  PermState.notAsked => 'Not asked yet',
  PermState.unknown => 'Unknown',
};

/// Why a driver can't go online yet: location or notifications not set up.
/// Null when they can.
enum OnlineBlock {
  serviceOff('Turn on Location', 'Location is switched off on this phone. Turn it on to go online.'),
  locationNotAsked(
    'Allow location',
    'GET.ride needs your location to go online, so riders nearby can find you. Allow it, then choose '
        '"Change to Always Allow" when your phone asks.',
  ),
  locationOff(
    'Allow location in Settings',
    'Location is off for GET.ride. In Settings, set Location to "Always" to go online.',
  ),
  notAlways(
    'Set location to Always',
    'To go online, GET.ride needs your location all the time, so riders keep finding you and trips stay '
        'on track while you use other apps or the screen is off. Set Location to "Always".',
  ),
  notificationsNotAsked(
    'Allow notifications',
    'To go online, allow notifications so you hear new ride requests and calls when GET.ride is not on screen.',
  ),
  notificationsOff(
    'Turn on notifications',
    "Notifications are off for GET.ride, so you wouldn't hear new ride requests or calls. Turn them on in "
        'Settings to go online.',
  );

  const OnlineBlock(this.title, this.message);
  final String title;
  final String message;

  bool get isLocation => index <= notAlways.index;

  /// Where in the phone's Settings it is changed, when that is the way.
  String? get settingsPath => switch (this) {
    notAlways || locationOff => 'Settings → GET.ride → Location → Always',
    notificationsOff => 'Settings → GET.ride → Notifications → Allow',
    _ => null,
  };
}

/// What a driver needs to go online: location switched on and, on an
/// iPhone, allowed "Always" (Android keeps an online driver's location
/// through its foreground service, which needs only "While using the app"),
/// then notifications allowed. Anything a phone can't say
/// ([PermState.unknown]) is let through, like the other go-online checks.
OnlineBlock? onlineBlock({
  required bool serviceOn,
  required PermState location,
  required PermState notifications,
  required TargetPlatform platform,
  bool web = false,
}) {
  if (web) return null;
  if (!serviceOn) return OnlineBlock.serviceOff;
  final loc = switch (location) {
    PermState.granted || PermState.unknown => null,
    PermState.limited => platform == TargetPlatform.iOS ? OnlineBlock.notAlways : null,
    PermState.notAsked => OnlineBlock.locationNotAsked,
    PermState.denied => OnlineBlock.locationOff,
  };
  if (loc != null) return loc;
  return switch (notifications) {
    PermState.notAsked => OnlineBlock.notificationsNotAsked,
    PermState.denied => OnlineBlock.notificationsOff,
    _ => null,
  };
}
