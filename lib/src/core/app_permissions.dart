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
  microphone(
    'Microphone',
    'Calls with your driver, passenger or support, voice notes, and trip audio recording if you turn it on.',
  ),
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
  // The website gets no pushes (the browser keeps its own notification
  // switch), so only the location it asks for is listed.
  if (web) return const [AppPermission.location];
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

/// The background-location disclosure (migration 0333): the permissions
/// notice's "Location all the time" row and the page shown before the
/// phone's own "Allow all the time" / "Always" question, word for word. It
/// says all that the app collects in the background (a trip, online, the
/// meter, and the check-ins of BackgroundLocation, 0272), and matches
/// ios/Runner/Info.plist's NSLocationAlwaysAndWhenInUseUsageDescription.
const backgroundLocationDisclosure =
    'GET.ride collects location data to enable trip tracking, safety and ride requests, even when the app is closed '
    'or not in use.\n\n'
    'When it is collected in the background:\n'
    '• During a trip, for passengers and drivers: so your driver or passenger, and our safety team, can see where '
    'the car is, and SOS can share your exact position.\n'
    '• While you are online as a driver: to send you ride requests near you, match you with the closest passenger, '
    'and record the trip route and distance for the fare, the receipt and your statements.\n'
    '• While Meter Digital is running (taxi drivers): to measure the trip for the meter fare.\n'
    '• Drivers who choose "Allow all the time" (Always on iPhone): approximate location about every 15 minutes, or '
    'when you move about 200 m, even when the app is closed, so our safety and support team can see where you last '
    'were if you need help.\n'
    '• Passengers: only during your own trip, from pickup to drop-off. Where GET.ride offers it, you can also turn '
    'on "Share my last location with GET.ride safety when the app is closed" in Settings: then the same check-ins '
    'run for you too, until you turn it off. Off unless you turn it on.\n\n'
    'Who can see it: your driver or passenger, only during your trip, and the GET.ride safety and support team (on '
    'its live map). It is never sold.\n\n'
    'Your choice: you can change it any time in your phone settings. With "While using the app", the 15-minute '
    'check-ins never run, and location is collected only while GET.ride is open or shows that you are online, on a '
    'trip or running the meter. Drivers may need "Always" to go online on some phones.';

/// What a passenger is held to (0333): never "Always" / "All the time".
/// A trip's background location works with "While using the app" (the
/// foreground service on Android, the location background mode on
/// iPhone), and the closed-app check-ins are the passenger's own opt-in in
/// Settings, asked there after the disclosure.
PermissionChecks riderChecks(PermissionChecks user) => user.copyWith(locationAlways: false, locationAlwaysAndroid: false);

/// Whether the closed app's check-ins may run for this account:
/// a driver as before (0333), a passenger only with the admin's switch on and
/// their own opt-in (0333), or a user with an active safety case that has been
/// disclosed to them (0337). The server keeps the same rule
/// (background_checkin_allowed): it still refuses any report for a safety case
/// until the app has shown the indicator and called the ack.
bool backgroundCheckinsAllowed({
  required bool isPartner,
  required bool switchOn,
  required bool optedIn,
  bool safetyCase = false,
}) =>
    isPartner || (switchOn && optedIn) || safetyCase;

/// What must change before going on: one entry for each check that holds
/// someone up.
enum PermissionBlock {
  serviceOff('Turn on Location', 'Location is switched off on this phone.'),
  locationNotAsked('Allow location', 'GET.ride needs your location to find your pickup and the drivers near you.'),
  locationOff('Allow location in Settings', 'Location is off for GET.ride. Turn it on in Settings.'),
  // The prominent disclosure for background location (Google Play, and
  // Apple's "Always"): what is collected, when, what for and who sees it,
  // shown to riders and drivers alike before the phone is asked.
  notAlways('Location all the time', backgroundLocationDisclosure),
  notAllTheTime('Location all the time', backgroundLocationDisclosure),
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
    notAlways || locationOff => 'Settings > GET.ride > Location > Always',
    notAllTheTime => 'Settings > Apps > GET.ride > Permissions > Location > Allow all the time',
    notificationsOff => 'Settings > GET.ride > Notifications > Allow',
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
