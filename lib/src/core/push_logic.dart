// What the push-notification layer decides, kept free of plugins so it can be
// unit-tested. The plugin side is lib/src/data/push_service.dart.
//
// Push goes through Firebase Cloud Messaging on Android and iOS. The Firebase
// project is supplied at build time rather than through google-services.json /
// GoogleService-Info.plist, so a build without it simply has no push:
//
//   --dart-define=FIREBASE_PROJECT_ID=...
//   --dart-define=FIREBASE_MESSAGING_SENDER_ID=...
//   --dart-define=FIREBASE_ANDROID_APP_ID=...   --dart-define=FIREBASE_ANDROID_API_KEY=...
//   --dart-define=FIREBASE_IOS_APP_ID=...       --dart-define=FIREBASE_IOS_API_KEY=...
//
// These are Firebase's public client identifiers, not secrets. The server
// side (sending) is the send-push edge function (supabase/functions/send-push).
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'partner_remote_action.dart' show remoteActionIdFromPush, remoteActionRoute;

/// The Firebase client settings for one build, as passed with --dart-define.
class FirebaseEnv {
  const FirebaseEnv({
    this.projectId = '',
    this.messagingSenderId = '',
    this.androidAppId = '',
    this.androidApiKey = '',
    this.iosAppId = '',
    this.iosApiKey = '',
    this.iosBundleId = '',
  });

  /// The values compiled into this build.
  const FirebaseEnv.fromEnvironment()
      : projectId = const String.fromEnvironment('FIREBASE_PROJECT_ID'),
        messagingSenderId = const String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
        androidAppId = const String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
        androidApiKey = const String.fromEnvironment('FIREBASE_ANDROID_API_KEY'),
        iosAppId = const String.fromEnvironment('FIREBASE_IOS_APP_ID'),
        iosApiKey = const String.fromEnvironment('FIREBASE_IOS_API_KEY'),
        iosBundleId = const String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID', defaultValue: 'com.taxxee.teksi');

  final String projectId;
  final String messagingSenderId;
  final String androidAppId;
  final String androidApiKey;
  final String iosAppId;
  final String iosApiKey;
  final String iosBundleId;
}

/// Firebase options for [platform], or null when this build has no push
/// there: on web and desktop, or when any value the platform needs is
/// missing. A half-configured build gets no push rather than a crash.
FirebaseOptions? firebaseOptionsFor(TargetPlatform platform, FirebaseEnv env, {bool isWeb = false}) {
  if (isWeb) return null;
  String clean(String v) => v.trim();
  final project = clean(env.projectId);
  final sender = clean(env.messagingSenderId);
  if (project.isEmpty || sender.isEmpty) return null;

  switch (platform) {
    case TargetPlatform.android:
      final appId = clean(env.androidAppId);
      final apiKey = clean(env.androidApiKey);
      if (appId.isEmpty || apiKey.isEmpty) return null;
      return FirebaseOptions(apiKey: apiKey, appId: appId, messagingSenderId: sender, projectId: project);
    case TargetPlatform.iOS:
      final appId = clean(env.iosAppId);
      final apiKey = clean(env.iosApiKey);
      if (appId.isEmpty || apiKey.isEmpty) return null;
      return FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: sender,
        projectId: project,
        iosBundleId: clean(env.iosBundleId).isEmpty ? null : clean(env.iosBundleId),
      );
    default:
      return null;
  }
}

/// The page of the full message a push carries (`data.message_id`), or null.
String? pushMessageRoute(Map<String, dynamic> data) {
  final id = data['message_id'];
  if (id is! String || id.trim().isEmpty) return null;
  return '/account/notifications/${Uri.encodeComponent(id.trim())}';
}

/// The `platform` stored beside the token in `push_tokens`, matching what
/// the Expo app writes (`Platform.OS`).
String? pushPlatformName(TargetPlatform platform) => switch (platform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => null,
    };

/// Where tapping a notification opens, from the `data` the database
/// triggers attach (migrations 0067 / 0077 / 0129 / 0131). Null
/// opens the app wherever it was.
String? pushRouteFor(Map<String, dynamic> data) {
  switch (data['type']) {
    case 'ride_request':
    case 'ride_request_fare_raised':
      // Only partners are sent these; the queue is on the Drive tab.
      return '/drive';
    case 'wallet_transfer_request':
    case 'wallet_transfer_response':
      return '/wallet';
    case 'partner_remote_action':
      // Support asked the driver's phone to change their status (0286): the
      // Drive page runs it; the line kept in Notifications opens Drive.
      final id = remoteActionIdFromPush(data);
      return id == null ? '/drive' : remoteActionRoute(id);
    case 'identity_check':
      // A dispatch ID's selfie or ID (0281): to the admin, the queue; to the
      // person, the decision on their sign-in steps.
      return data['for'] == 'admin' ? '/admin/documents?kind=signin' : '/dispatch';
    case 'online_selfie_check':
      // A low selfie match when a partner went online (0290): to the admin,
      // that check, with Call partner, Go offline and Add to watch list.
      final check = data['check_id'];
      return check is String && check.isNotEmpty
          ? '/admin/m/online-selfie-check?id=${Uri.encodeComponent(check)}'
          : '/admin/documents?kind=signin';
    case 'ride_message':
      // A City to City booking's chat (migration 0308), on the recipient's side.
      final booking = data['c2c_booking_id'];
      if (booking is String && booking.isNotEmpty) {
        final b = Uri.encodeComponent(booking);
        return data['role'] == 'partner' ? '/drive/city-to-city/$b/chat' : '/city-to-city/$b/chat';
      }
      // The chat over the recipient's own trip screen (migration 0129 says
      // which side they are on).
      final id = data['request_id'];
      if (id is! String || id.isEmpty) return null;
      final ride = Uri.encodeComponent(id);
      return data['role'] == 'partner' ? '/drive/trip/$ride/chat' : '/ride/$ride/chat';
    case 'c2c_reminder':
    case 'c2c_pay':
      // A City to City trip reminder or "Pay for your trip" (0309): the
      // trips, on the recipient's side.
      return data['role'] == 'partner' ? '/drive/city-to-city?tab=trips' : '/city-to-city';
    case 'c2c_seat':
      // A seat request, booking or answer on a posted trip (0310): the
      // driver's posted trips, the rider's trips.
      return data['role'] == 'partner' ? '/drive/city-to-city?tab=post' : '/city-to-city';
    case 'ride_call':
      // The full-screen incoming call (migration 0131); it goes back to the
      // trip once the call is over.
      final call = data['call_id'];
      if (call is! String || call.isEmpty) return null;
      return '/ride-call/${Uri.encodeComponent(call)}';
    case 'scheduled_reminder':
      // "Ride coming up" (migrations 0189 / 0197): the bookings, the
      // driver's on their side.
      return data['role'] == 'partner' ? '/drive/scheduled' : '/trips/scheduled';
    case 'scheduled_ready':
    case 'scheduled_taken':
      // A booking the driver marked (migration 0198): ready to accept, or
      // taken by someone else. Upcoming.
      return '/drive/scheduled';
    case 'scheduled_cancelled':
      // To a driver only: the passenger cancelled a ride they held, marked
      // or were asked to take (0189 / 0198).
      return '/drive/scheduled?tab=mine';
    case 'scheduled_offer':
    case 'scheduled_offer_accepted':
    case 'scheduled_offer_declined':
    case 'scheduled_offer_expired':
      // A handover or a passenger's choice of driver (0198): its answer goes
      // back to whoever asked, a driver or the passenger.
      return data['role'] == 'partner' ? '/drive/scheduled?tab=mine' : '/trips/scheduled';
    case 'scheduled_assigned':
    case 'scheduled_reassigning':
    case 'scheduled_expired':
      // The passenger's booking moved: a driver confirmed or changed, the
      // driver gave it up, or nobody was found.
      return '/trips/scheduled';
    case 'trip_handover_paid':
      // The share of a trip handed over, added to GET credit (0199).
      return '/wallet';
    case 'trip_handover_offer':
    case 'trip_handover_taken':
      // A partner asked to take over a trip, or told it went to another:
      // the offers are on the Drive tab.
      return '/drive';
    case 'trip_handover_approval':
    case 'trip_handover_accepted':
    case 'trip_handover_declined':
    case 'trip_handover_expired':
    case 'trip_handover_withdrawn':
      // A mid-trip handover moved on (0199): that trip's screen, the
      // driver's or the passenger's.
      final id = data['request_id'];
      if (id is! String || id.isEmpty) return data['role'] == 'partner' ? '/drive' : null;
      final ride = Uri.encodeComponent(id);
      return data['role'] == 'partner' ? '/drive/trip/$ride' : '/ride/$ride';
    case 'ride_expired':
      // Nobody took the request (migration 0139): home, to book again.
      return '/';
    case 'mygig_offer':
      // A driver sent the passenger a myGiG fare (0329): accept or decline it.
      final offer = data['offer_id'];
      return offer is String && offer.isNotEmpty ? '/mygig/offer/${Uri.encodeComponent(offer)}' : '/';
    case 'mygig_booking':
      // A myGiG booking for later or a hire (0330): the driver's Scheduled
      // myGiG, the passenger's scheduled rides.
      return data['role'] == 'partner' ? '/drive/mygig/scheduled' : '/trips/scheduled';
    case 'mygig_answer' when data['request_id'] is! String && data['booking_id'] is String:
      return '/drive/mygig/scheduled';
    case 'mygig_answer':
    case 'mygig_cancelled':
      // The passenger answered the driver's myGiG (0329): the trip, or home.
      final id = data['request_id'];
      return id is String && id.isNotEmpty ? '/drive/trip/${Uri.encodeComponent(id)}' : '/drive';
    case 'partner_status':
    case 'document_status':
      // An approval decision on the partner account or one of its documents
      // (migration 0127): the Drive tab shows where onboarding stands.
      return '/drive';
    case 'partner_review':
      // A driver sent back the changes an admin asked for (0289): to the
      // admin, that application's review.
      final partner = data['partner_id'];
      return partner is String && partner.isNotEmpty
          ? '/admin/m/partner-review?id=${Uri.encodeComponent(partner)}'
          : '/admin/partners';
    case 'vehicle_status':
      final vehicle = data['vehicle_id'];
      return vehicle is String && vehicle.isNotEmpty ? '/drive/vehicles/${Uri.encodeComponent(vehicle)}' : '/drive';
    case 'trip_start_check':
    case 'trip_separation':
      // "Are you in the car?" (trip safety): the passenger's trip screen,
      // where help is one tap away.
      final id = data['request_id'];
      if (id is! String || id.isEmpty) return null;
      return '/ride/${Uri.encodeComponent(id)}';
    case 'lost_item':
      // A lost-item report or its answer: that trip's receipt.
      final id = data['request_id'];
      if (id is! String || id.isEmpty) return null;
      return '/trips/${Uri.encodeComponent(id)}';
    case 'ride_status':
    case 'ride_cancel_request':
      // A trip changed state (migration 0144): driver assigned, arrived,
      // started, cancelled, a cancellation to answer.
    case 'ride_payment':
      // Paying for the finished trip (migration 0142): the passenger to the
      // payment popup, the driver to confirm the cash.
    case 'ride_call_end':
      // "Missed call" (migration 0134): back to the recipient's trip, where
      // Call rings them back.
      final id = data['request_id'];
      if (id is! String || id.isEmpty) return null;
      final ride = Uri.encodeComponent(id);
      return data['role'] == 'partner' ? '/drive/trip/$ride' : '/ride/$ride';
    default:
      // An admin push with a full message (Admin -> Push Notification,
      // 0279): that message's page, over the notifications page.
      return pushMessageRoute(data);
  }
}

/// The outbox event a push carries (migration 0144), to acknowledge it;
/// null for a push that isn't retried.
String? pushEventId(Map<String, dynamic> data) {
  final id = data['event_id'];
  return id is String && id.trim().isNotEmpty ? id.trim() : null;
}

/// Where supabase_flutter keeps the signed-in session on the phone.
String supabaseSessionKey(String supabaseUrl) => 'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

/// The access token of a stored session while it still has [margin] to run;
/// null when there is none, it is unreadable, or it is (nearly) out. The
/// background handler never refreshes a session: that is the app's to do,
/// and two refreshes racing would sign the person out.
String? storedAccessToken(String? stored, DateTime now, {Duration margin = const Duration(seconds: 30)}) {
  if (stored == null || stored.isEmpty) return null;
  Object? json;
  try {
    json = jsonDecode(stored);
  } catch (_) {
    return null;
  }
  if (json is! Map) return null;
  final token = json['access_token'], expires = json['expires_at'];
  if (token is! String || token.isEmpty || expires is! num) return null;
  final until = DateTime.fromMillisecondsSinceEpoch(expires.toInt() * 1000, isUtc: true);
  return until.difference(now.toUtc()) > margin ? token : null;
}

/// SharedPreferences key of the id an Android install makes for itself, the
/// raw material of its push device key.
const pushInstallIdKey = 'push_install_id_v1';

/// What identifies this phone to the push server, so a reinstall or a
/// rotated token replaces its old token instead of adding a second one
/// (migration 0165): a hash of [raw] (the install's id, the iPhone's APNs
/// token), never the value itself. Null when there is nothing to go on.
String? pushDeviceKey(String? raw) {
  final v = raw?.trim() ?? '';
  if (v.isEmpty) return null;
  return sha256.convert(utf8.encode('getride-push:$v')).toString();
}

/// The mode a phone in [location] is in, for the notifications that belong
/// to one (migration 0166): driver screens and the taxi meter are 'partner',
/// home and the passenger's rides 'rider', and the screens both share keep
/// [previous]. Null until the app has been anywhere that says.
String? pushModeAt(String location, String? previous) {
  bool under(String root) => location == root || location.startsWith('$root/');
  if (under('/drive') || under('/meter')) return 'partner';
  if (location == '/' || under('/trips') || under('/ride')) return 'rider';
  return previous;
}

/// How often a phone re-reports its area (the region and reverse-geocode
/// work, push_set_location) for area broadcasts, at most.
const pushLocationEvery = Duration(minutes: 30);

/// How far a phone moves before it re-reports its area sooner than that
/// (0272: 200 m, was 1 km).
const pushLocationMoveMeters = 200.0;

/// Whether to work out and tell the server the phone's area now: never told
/// yet, last told [pushLocationEvery] ago, or moved [pushLocationMoveMeters]
/// since. Pure.
bool shouldReportPushLocation({
  required LatLng point,
  required DateTime now,
  LatLng? lastPoint,
  DateTime? lastAt,
}) {
  if (lastPoint == null || lastAt == null) return true;
  if (now.difference(lastAt) >= pushLocationEvery) return true;
  return const Distance().as(LengthUnit.Meter, lastPoint, point) >= pushLocationMoveMeters;
}

/// How often the open app checks in (`push_checkin`, migration 0272): a
/// light report of where the phone is, moved or not, so Admin -> God View
/// sees everyone with the app open and not only those who moved.
const pushCheckinEvery = Duration(minutes: 2);

/// Whether the open app's check-in is due: someone signed in, the app on
/// screen, and nothing sent yet or [pushCheckinEvery] since the last one
/// (less a few seconds, so a timer firing early still counts). Pure.
bool pushCheckinDue({
  required bool signedIn,
  required bool foreground,
  required DateTime now,
  DateTime? lastAt,
}) {
  if (!signedIn || !foreground) return false;
  if (lastAt == null) return true;
  return now.difference(lastAt) >= pushCheckinEvery - const Duration(seconds: 5);
}

/// The closed app's report (`push_background_location`, migrations 0272, 0276):
/// about every [backgroundReportEvery], or sooner after a move of
/// [backgroundReportMoveMeters]. The native reporters apply this same rule
/// (android BackgroundLocationReceiver.kt, ios AppDelegate.swift
/// BackgroundLocationPlugin); it is kept and tested here.
const backgroundReportEvery = Duration(minutes: 15);
const backgroundReportMoveMeters = 200.0;

/// Whether a background fix is worth sending: nothing sent yet, the last
/// one [backgroundReportEvery] ago, or a move of [backgroundReportMoveMeters]
/// since. Pure.
bool backgroundReportDue({Duration? sinceLast, double? movedMetres}) {
  if (sinceLast == null) return true;
  if (sinceLast >= backgroundReportEvery) return true;
  return (movedMetres ?? 0) >= backgroundReportMoveMeters;
}

/// Whether this phone keeps reporting from the background: someone signed
/// in, push tokens to report against, and location already set to "Allow
/// all the time" / "Always" (never asked for here). Pure.
bool backgroundReportingWanted({required bool signedIn, required bool locationAlways, required bool hasTokens}) =>
    signedIn && locationAlways && hasTokens;

/// How long to wait before each further try at the iPhone's PushKit (VoIP)
/// token, which iOS can hand over a while after launch.
const voipRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(seconds: 60),
];

/// Whether to warn that notifications are off: only to someone signed in,
/// on the rider's or driver's screens (not admin pages or sign-in), and not
/// again in this launch once they said "Not now". Pure.
bool shouldWarnNotificationsOff({
  required bool off,
  required bool signedIn,
  required bool dismissed,
  required String location,
}) {
  if (!off || !signedIn || dismissed) return false;
  return pushModeAt(location, null) != null;
}
