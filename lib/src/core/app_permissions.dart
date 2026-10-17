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

/// Which checks one audience is held to (Admin → App Settings →
/// Permissions, migration 0196): each enforced, or bypassed.
class PermissionChecks {
  const PermissionChecks({
    this.locationService = true,
    this.location = true,
    this.locationAlways = false,
    this.locationAlwaysAndroid = false,
    this.notifications = true,
  });

  /// The phone's Location switched on.
  final bool locationService;

  /// GET.ride allowed to use it.
  final bool location;

  /// Allowed "Always" (iPhone; partners).
  final bool locationAlways;

  /// Allowed "All the time" (Android; partners). Off unless the admin turns
  /// it on: Android keeps an online driver's location through its
  /// foreground service with "While using the app" already.
  final bool locationAlwaysAndroid;

  /// GET.ride allowed to send notifications.
  final bool notifications;

  static bool _on(Object? v, bool fallback) => switch (v) {
    bool b => b,
    String s => !const {'false', 'f', '0', 'off', 'no'}.contains(s.trim().toLowerCase()),
    _ => fallback,
  };

  factory PermissionChecks.fromJson(Object? json, PermissionChecks fallback) {
    final m = json is Map ? json : const {};
    return PermissionChecks(
      locationService: _on(m['locationService'], fallback.locationService),
      location: _on(m['location'], fallback.location),
      locationAlways: _on(m['locationAlways'], fallback.locationAlways),
      locationAlwaysAndroid: _on(m['locationAlwaysAndroid'], fallback.locationAlwaysAndroid),
      notifications: _on(m['notifications'], fallback.notifications),
    );
  }

  Map<String, bool> toJson({bool always = false}) => {
    'locationService': locationService,
    'location': location,
    if (always) 'locationAlways': locationAlways,
    if (always) 'locationAlwaysAndroid': locationAlwaysAndroid,
    'notifications': notifications,
  };

  PermissionChecks copyWith({
    bool? locationService,
    bool? location,
    bool? locationAlways,
    bool? locationAlwaysAndroid,
    bool? notifications,
  }) => PermissionChecks(
    locationService: locationService ?? this.locationService,
    location: location ?? this.location,
    locationAlways: locationAlways ?? this.locationAlways,
    locationAlwaysAndroid: locationAlwaysAndroid ?? this.locationAlwaysAndroid,
    notifications: notifications ?? this.notifications,
  );

  bool get any => locationService || location || locationAlways || locationAlwaysAndroid || notifications;
}

/// The admin's permission rules: riders before the home map, partners
/// before going online, and whether Settings shows the Permissions card.
/// Everything enforced and the card shown when they can't be read.
class PermissionRules {
  const PermissionRules({
    this.user = const PermissionChecks(),
    this.partner = const PermissionChecks(locationAlways: true),
    this.showPermissionsCard = true,
  });

  final PermissionChecks user;
  final PermissionChecks partner;
  final bool showPermissionsCard;

  static const defaults = PermissionRules();

  factory PermissionRules.fromJson(Object? json) {
    if (json is! Map) return defaults;
    return PermissionRules(
      user: PermissionChecks.fromJson(json['user'], defaults.user),
      partner: PermissionChecks.fromJson(json['partner'], defaults.partner),
      showPermissionsCard: PermissionChecks._on(json['showPermissionsCard'], true),
    );
  }

  Map<String, Object> toJson() => {
    'user': user.toJson(),
    'partner': partner.toJson(always: true),
    'showPermissionsCard': showPermissionsCard,
  };
}

/// What must change before going on: one entry for each check that holds
/// someone up.
enum PermissionBlock {
  serviceOff('Turn on Location', 'Location is switched off on this phone.'),
  locationNotAsked('Allow location', 'GET.ride needs your location to find your pickup and the drivers near you.'),
  locationOff('Allow location in Settings', 'Location is off for GET.ride. Turn it on in Settings.'),
  notAlways(
    'Set location to Always',
    'GET.ride needs your location all the time while you are online, so riders keep finding you and trips stay on '
        'track while you use other apps or the screen is off.',
  ),
  // Google Play's prominent disclosure for background location: what is
  // collected, when, and what for, shown before Android is asked.
  notAllTheTime(
    'Allow location all the time',
    'GET.ride collects your location in the background, even when the app is closed or not in use, while you are '
        'online and during trips. Riders see you on the way to them and during the trip, and it is kept for safety. '
        'It is not collected while you are offline.',
  ),
  notificationsNotAsked(
    'Allow notifications',
    'So you hear ride requests, calls and trip updates when GET.ride is not on screen.',
  ),
  notificationsOff(
    'Turn on notifications',
    "Notifications are off for GET.ride, so you wouldn't hear ride requests, calls or trip updates. Turn them on in "
        'Settings.',
  );

  const PermissionBlock(this.title, this.message);
  final String title;
  final String message;

  bool get isLocation => index <= notAllTheTime.index;

  /// Only the phone's Settings can fix it (the app can't ask again).
  bool get needsSettings => this == serviceOff || this == locationOff || this == notificationsOff;

  /// Where in the phone's Settings it is changed, when that is the way.
  String? get settingsPath => switch (this) {
    notAlways || locationOff => 'Settings → GET.ride → Location → Always',
    notAllTheTime => 'Settings → Apps → GET.ride → Permissions → Location → Allow all the time',
    notificationsOff => 'Settings → GET.ride → Notifications → Allow',
    _ => null,
  };
}

/// Everything holding someone up under [checks], location first. Anything a
/// phone can't say ([PermState.unknown]) is let through, and nothing is
/// asked of the web. "Always" is an iPhone setting; Android's "All the
/// time" is its own switch, off by default, since Android keeps an online
/// driver's location through its foreground service with only "While using
/// the app". Pure.
List<PermissionBlock> permissionBlocks({
  required PermissionChecks checks,
  required bool serviceOn,
  required PermState location,
  required PermState notifications,
  required TargetPlatform platform,
  bool web = false,
}) {
  if (web) return const [];
  final out = <PermissionBlock>[];
  if (checks.locationService && !serviceOn) out.add(PermissionBlock.serviceOff);
  final always = checks.locationAlways && platform == TargetPlatform.iOS;
  final allTheTime = checks.locationAlwaysAndroid && platform == TargetPlatform.android;
  if (checks.location || always || allTheTime) {
    switch (location) {
      case PermState.notAsked:
        out.add(PermissionBlock.locationNotAsked);
      case PermState.denied:
        out.add(PermissionBlock.locationOff);
      case PermState.limited when always:
        out.add(PermissionBlock.notAlways);
      case PermState.limited when allTheTime:
        out.add(PermissionBlock.notAllTheTime);
      default:
        break;
    }
  }
  if (checks.notifications) {
    if (notifications == PermState.notAsked) out.add(PermissionBlock.notificationsNotAsked);
    if (notifications == PermState.denied) out.add(PermissionBlock.notificationsOff);
  }
  return out;
}
