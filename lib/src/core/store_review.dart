/// The store review login (migration 0333): who the sealed demo account
/// is, the permissions notice every user is shown, and the guided demo tour
/// the reviewer gets. Pure: the screens only draw what is here.
library;

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'app_permissions.dart' show backgroundLocationDisclosure;

/// The one store review account (0333's store_review_user_id()).
const storeReviewUserId = 'a0000333-5707-4e00-8000-000000000333';

/// Whether an Auth user is the store review account: its app_metadata
/// (which only the server sets) or its id.
bool isStoreReviewAccount({String? userId, Map<String, dynamic>? appMetadata}) {
  if (userId == storeReviewUserId) return true;
  final v = appMetadata?['store_review'];
  return v == true || v == 'true';
}

/// The iPhone App Store build (0333): no Android, Google Play, APK or
/// install links there.
bool iosStoreBuild({bool storeBuild = AppConfig.storeBuild, TargetPlatform? platform, bool web = kIsWeb}) =>
    storeBuild && !web && (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;

/// What the app says when the server refuses the demo account something
/// (`STORE_REVIEW_DEMO`).
const storeReviewRefusal =
    'This is the store review demo account. It runs on simulated riders, drivers and trips only, so this '
    'real action is switched off.';

/// Whether a server error is the demo account's seal.
bool isStoreReviewRefusal(Object? error) => '$error'.contains('STORE_REVIEW_DEMO');

// ---- The permissions notice ------------------------------------------------------------------------

/// Where a permission is asked.
enum NoticePlatform { android, ios }

/// One permission the app asks for, and why, in plain words.
class PermissionNoticeItem {
  const PermissionNoticeItem({
    required this.id,
    required this.title,
    required this.why,
    this.platforms = const {NoticePlatform.android, NoticePlatform.ios},
    this.driverOnly = false,
    this.since = 1,
  });

  final String id;
  final String title;
  final String why;
  final Set<NoticePlatform> platforms;

  /// Only asked in driver mode.
  final bool driverOnly;

  /// The notice version that added it ([permissionNoticeVersion]).
  final int since;
}

/// Raise when an app update asks for a permission it did not before, and
/// give the new item that [PermissionNoticeItem.since]: everyone is shown
/// the notice again once.
const permissionNoticeVersion = 1;

/// The notice's opt-in for News and offers: unticked until chosen.
const newsOffersChoice = 'Send me news and offers';

/// Every permission the app really asks for, as android/app/src/main/
/// AndroidManifest.xml and ios/Runner/Info.plist declare them, each with
/// what it is used for, who sees it, when it runs and the choice. Install-
/// time ones nobody is asked for (internet, network state, wake lock, start
/// at boot) are not listed. Kept in step with the Info.plist usage strings.
const permissionNoticeItems = <PermissionNoticeItem>[
  PermissionNoticeItem(
    id: 'location',
    title: 'Location while using the app',
    why: 'GET.ride uses your location while the app is open on your screen.\n\n'
        'What it is used for:\n'
        '• Setting your pickup point for you, so you do not have to type it.\n'
        '• Showing the cars near you and how long they will take to reach you.\n'
        '• Showing the prices and services where you are (some places, such as airports, have their own fees and '
        'pickup points).\n'
        '• Showing your driver where to pick you up, and where you are during the trip.\n'
        '• Sharing your trip with family or friends when you choose to.\n'
        '• Safety: SOS alerts our safety team with your exact position, and you can choose to text it to your '
        'emergency contacts.\n'
        '• While the app is open, a check-in every few minutes, so our support team can see you on its live map and '
        'announcements for your area reach you if you turned on News and offers.\n\n'
        'Who can see it: your driver or passenger, only during your trip; people you share your trip with; Family '
        'members you share with; and the GET.ride support and safety team. It is never sold.\n\n'
        'When it stops: when GET.ride is no longer on your screen, unless a trip is under way, you are online as a '
        'driver or Meter Digital is running (see Location all the time).\n\n'
        'Your choice: if you say no, you can still book by typing your pickup address.',
  ),
  PermissionNoticeItem(
    id: 'location-background',
    title: 'Location all the time',
    why: backgroundLocationDisclosure,
  ),
  PermissionNoticeItem(
    id: 'camera',
    title: 'Camera',
    why: 'The camera opens only when you tap a camera or scan button.\n\n'
        'What it is used for:\n'
        '• Photos of your documents, such as your ID, driving licence, vehicle grant and permits (drivers).\n'
        '• The live selfie check that confirms it is really you.\n'
        '• Photos of a parcel at pickup and delivery, a pet, or something left in a car.\n'
        '• Photos you send in chat.\n'
        '• Scanning QR codes, such as wallet payments, a driver\'s code and referral codes.\n\n'
        'Who can see the photos: documents and selfies: the GET.ride review team only, in private storage. Chat '
        'photos: the person you are chatting with, and our support team if you report a problem. Parcel photos: the '
        'people on that delivery and our support team.\n\n'
        'Your choice: if you say no, you can choose an existing photo instead, and use the rest of the app.',
  ),
  PermissionNoticeItem(
    id: 'microphone',
    title: 'Microphone',
    why: 'The microphone is used only for the features below, and only when you start them or switch them on.\n\n'
        'In-app calls: talk to your driver or passenger about the pickup, or to our support team, without sharing '
        'your phone number. The microphone is on only during the call. Calls are not recorded.\n\n'
        'Voice notes in chat: hold the microphone button to record a short message, then send it. Only the person '
        'you send it to, and our support team if you report a problem, can play it.\n\n'
        'Audio protection (optional, off until you turn it on): for your safety, a passenger (Audio protection) or '
        'a driver (VoiceProtection) can choose to record the sound in the car during a trip, from Start trip to the '
        'end. The recording stays encrypted on that phone; it cannot be played on the phone and is not uploaded. It '
        'is deleted automatically after 24 hours (for passengers, the time set for your area, up to 7 days, as the '
        'app shows). If a problem with that trip is reported, our support team can ask the phone to send it, and '
        'only authorised support staff can listen to it. When a passenger records, the driver is told. While a '
        'driver\'s phone records, the driver\'s trip screen shows it and the passenger sees "Your driver is '
        'recording audio for safety" on their trip screen, with a link to our Privacy Policy.\n\n'
        'When it stops: when the call ends, when you send or cancel the voice note, or when the trip ends.\n\n'
        'Your choice: if you say no, you can still chat by text and use the app, but you cannot make in-app calls, '
        'send voice notes or use audio protection.',
  ),
  PermissionNoticeItem(
    id: 'notifications',
    title: 'Notifications',
    why: 'Notifications tell you what is happening when GET.ride is not open on your screen. You get the ones for '
        'the mode you are using: passenger or driver.\n\n'
        'Your trips (passengers): driver offers, and your driver accepting; your driver arriving, starting the trip '
        'and finishing it; reminders for rides you booked for later, hire bookings and City to City trips; updates '
        'on trips your Family books or pays for.\n\n'
        'Your work (drivers): new ride, delivery and hire requests near you, with a sound so you do not miss them; '
        'a passenger cancelling; reminders for bookings you accepted for later; your account: approvals, '
        'documents about to expire, GET.credit and statements.\n\n'
        'Messages and calls: chat messages and in-app calls from your driver, passenger or our support team. A call '
        'from your driver or passenger can ring over the lock screen like a normal call.\n\n'
        'Money: payments, tips, wallet transfers, receipts and statements.\n\n'
        'Safety: trip safety checks and updates from our safety team.\n\n'
        'News and offers from GET.ride: occasional announcements and promotions, sometimes for your area only, as '
        'notifications and as SMS to your number. Off unless you choose "Send me news and offers" below; turn them '
        'on or off any time in Settings > Notifications > News and offers, or reply STOP to a promotion SMS. Trip, '
        'safety, payment and account messages always come.\n\n'
        'Your choice: you can turn notifications off in your phone settings at any time. If you do, you may miss '
        'driver offers, your driver arriving, and new requests as a driver.',
  ),
  PermissionNoticeItem(
    id: 'bluetooth',
    title: 'Nearby devices (Bluetooth)',
    why: 'Bluetooth connects your phone to devices close by. It is never used to find where you are.\n\n'
        'Pickup and trip check (passengers and drivers, where GET.ride has turned it on): your phone and your '
        'driver\'s phone check that they are next to each other, to confirm you are getting into the right car, '
        'that you are still together during the trip, and in some places to start the trip without typing the '
        'code. Each phone sends a short code that changes every trip and never contains your name or phone '
        'number. If the network drops, chat messages with your driver or passenger can go phone to phone.\n\n'
        'Driver equipment (drivers): an OBD-II reader for the car\'s speed and distance (Meter Digital), and a '
        'receipt printer.\n\n'
        'When it runs: only around your trip, or while a device is connected.\n\n'
        'Your choice: if you say no, you type the trip code instead, and drivers can use the app without a reader '
        'or printer.',
  ),
  PermissionNoticeItem(
    id: 'calls',
    title: 'Calls running in the background',
    why: 'GET.ride has its own in-app calls, so your phone number stays private. You can call your driver or '
        'passenger about the pickup, and our support team.\n\n'
        'What it is used for:\n'
        '• Keeping a call connected when you switch to another app, such as maps or messages, or when the screen '
        'turns off.\n'
        '• Ringing you for a call from your driver or passenger, like a normal phone call, even when GET.ride is in '
        'the background.\n'
        '• Keeping the microphone and speaker working for that call only.\n\n'
        'What you will see: your phone shows that a GET.ride call is on for as long as it lasts.\n\n'
        'When it stops: as soon as the call ends. Nothing runs for calls when there is no call.\n\n'
        'Who can hear it: only you and the person on the call. Calls are not recorded (Audio protection, if you or '
        'your driver turned it on, records the sound in the car during a trip: see Microphone).',
    platforms: {NoticePlatform.android},
  ),
  PermissionNoticeItem(
    id: 'photos',
    title: 'Photos and files',
    why: 'GET.ride opens your photos or files only when you tap a button to attach, upload or save something. You can '
        'give access to selected photos only. It sees only what you pick, never the rest of your gallery or folders.\n\n'
        'Choosing a photo or file you already have:\n'
        '• Your profile photo.\n'
        '• Photos of your documents and vehicle for your driver account.\n'
        '• A photo or file in chat with your driver, passenger or our support team.\n'
        '• A photo of a parcel, a pet or a lost item.\n'
        '• A driver\'s QR code saved as a picture.\n'
        '• Business accounts: invoices and company documents.\n\n'
        'Saving to your phone: receipts, meter receipts, invoices and driver statements you choose to download, as '
        'PDF.\n\n'
        'Who can see them: documents: the GET.ride review team only, in private storage. Chat photos and files: the '
        'person you send them to, and our support team if you report a problem. Your profile photo: your driver or '
        'passenger during a trip.\n\n'
        'Your choice: if you say no, you can still take a new photo with the camera instead, and use the rest of '
        'the app.',
    platforms: {NoticePlatform.ios},
  ),
  PermissionNoticeItem(
    id: 'local-network',
    title: 'Local network',
    why: 'iPhone only, for drivers: to reach a Wi-Fi OBD-II reader or a Wi-Fi receipt printer in the vehicle, for '
        'Meter Digital.\n\n'
        'When it runs: only while you connect to or use such a device. Nothing else on your network is read.\n\n'
        'Your choice: if you say no, use a Bluetooth reader or printer, or none.',
    platforms: {NoticePlatform.ios},
    driverOnly: true,
  ),
];

/// The platform's notice platform; null where nothing is asked (the web,
/// desktop).
NoticePlatform? noticePlatformOf(TargetPlatform platform, {bool web = kIsWeb}) {
  if (web) return null;
  return switch (platform) {
    TargetPlatform.android => NoticePlatform.android,
    TargetPlatform.iOS => NoticePlatform.ios,
    _ => null,
  };
}

/// The items asked for on [platform]; every item when null (a preview).
List<PermissionNoticeItem> permissionNoticeFor(NoticePlatform? platform) =>
    [for (final i in permissionNoticeItems) if (platform == null || i.platforms.contains(platform)) i];

/// Whether the notice is shown now. The store review account: on every
/// sign-in (once per run of the app, [shownThisRun]). Everyone else: once
/// on first sign-in ([seenVersion] null) and again after an update adds a
/// permission ([seenVersion] older than [current]).
bool permissionNoticeDue({
  required bool storeReview,
  required int? seenVersion,
  required bool shownThisRun,
  int current = permissionNoticeVersion,
}) {
  if (shownThisRun) return false;
  if (storeReview) return true;
  return seenVersion == null || seenVersion < current;
}

/// Where the phone remembers the notice version this account saw.
String permissionNoticeKey(String userId) => 'permissions_notice_seen:$userId';

// ---- The guided demo tour ----------------------------------------------------------------------------

enum TourMode { passenger, driver }

/// One step card: what it shows ([route], opened when the step comes up)
/// and what to do there.
class TourStep {
  const TourStep({required this.title, required this.body, required this.route});

  final String title;
  final String body;
  final String route;
}

const passengerTour = <TourStep>[
  TourStep(
    title: 'Home',
    route: '/',
    body: 'This is a passenger\'s home: the map around you, and the booking panel. Everything in this account is '
        'simulated: no real driver, rider or payment is involved.',
  ),
  TourStep(
    title: 'Pick a destination',
    route: '/',
    body: 'Tap "Where to?" and choose a place. The pickup is where you are; you can move it.',
  ),
  TourStep(
    title: 'Fare and vehicles',
    route: '/',
    body: 'Each vehicle type shows its fare for the trip. Pick one, and how you pay.',
  ),
  TourStep(
    title: 'Request a ride',
    route: '/',
    body: 'Tap "Find driver". In this demo the request stays on this phone; no real driver gets it.',
  ),
  TourStep(
    title: 'Driver offers',
    route: '/',
    body: 'Simulated drivers answer: each offer slides in with the driver, the car, the time to you and the price. '
        'Accept one. Offers you leave slide away.',
  ),
  TourStep(
    title: 'Driver on the way',
    route: '/',
    body: 'The trip screen shows the car driving to your pickup and when it will arrive.',
  ),
  TourStep(
    title: 'Trip in progress and arrival',
    route: '/',
    body: 'Once picked up, the car follows the route to your destination, and you are told when you arrive.',
  ),
  TourStep(
    title: 'Pay, rate and receipt',
    route: '/trips',
    body: 'At the end you pay (simulated here), rate the driver, and the receipt is kept under Trips.',
  ),
  TourStep(
    title: 'Scheduled rides',
    route: '/trips/scheduled',
    body: 'Book a ride for later: pick the date and time on the booking panel. Your bookings are listed here.',
  ),
  TourStep(
    title: 'Hire by time and City to City',
    route: '/',
    body: 'On the booking panel, "Hire by time" books a driver and car by the hour, day, week or month, and City to '
        'City books a long trip between cities. Demo drivers answer both.',
  ),
  TourStep(
    title: 'Courier and Freight',
    route: '/',
    body: 'On the home page, Courier sends a parcel and Freight moves goods by van or lorry. Demo couriers and '
        'drivers send offers and deliver.',
  ),
  TourStep(
    title: 'Chat and call',
    route: '/',
    body: 'On a demo trip, Chat and Call reach the demo driver: the chat answers and the call connects, with no '
        'real message or call.',
  ),
  TourStep(
    title: 'Family',
    route: '/account/family',
    body: 'Family lets a host book and pay rides for family members, with limits, a pickup code for children and '
        'trip sharing that every member can see. Here you host a demo family with two members.',
  ),
  TourStep(
    title: 'Wallet',
    route: '/wallet',
    body: 'GET.wallet pays for rides and tips. Top up and pay from the demo balance, and pay a shop by QR from '
        'How it works > Try every feature. No real money moves.',
  ),
  TourStep(
    title: 'Safety and SOS',
    route: '/account/safety',
    body: 'Emergency contacts, trip sharing and the SOS button live here. In a real trip SOS alerts our safety '
        'team. Tap Emergency SOS to see every step: in this demo nothing is sent to anyone.',
  ),
  TourStep(
    title: 'Help and support',
    route: '/account/support',
    body: 'Chat with us opens a demo support chat that answers. Nothing is sent to our team.',
  ),
  TourStep(
    title: 'Try every feature',
    route: '/',
    body: 'Menu > How it works > Try every feature lists every feature with how to try it and a button to open it.',
  ),
];

const driverTour = <TourStep>[
  TourStep(
    title: 'Go online',
    route: '/drive',
    body: 'This is driver mode. Turn on the switch to go online. The app first explains why it needs your '
        'location all the time, then asks. This demo driver never reaches real riders.',
  ),
  TourStep(
    title: 'A request arrives',
    route: '/drive',
    body: 'While online, simulated ride requests come in with the pickup, drop-off, distance and fare. Accept one.',
  ),
  TourStep(
    title: 'Offer your own fare',
    route: '/drive',
    body: 'On a request, Offer a fare sends your own price. The demo passenger takes it (up to 30% more) or says no.',
  ),
  TourStep(
    title: 'Navigate to the pickup',
    route: '/drive',
    body: 'The trip screen drives you to the passenger (simulated) and opens your navigation app if you want.',
  ),
  TourStep(
    title: 'Start the trip',
    route: '/drive',
    body: 'At the pickup, tap Start trip once the passenger is in.',
  ),
  TourStep(
    title: 'Complete the trip',
    route: '/drive',
    body: 'At the drop-off, complete the trip and collect the fare.',
  ),
  TourStep(
    title: 'Earnings',
    route: '/drive/earnings',
    body: 'Earnings shows what you made by day and week (empty for this demo account: demo fares go to the demo '
        'GET.credit in Wallet).',
  ),
  TourStep(
    title: 'Statements',
    route: '/drive/statements',
    body: 'Monthly statements list every trip, fee and payout.',
  ),
  TourStep(
    title: 'GET.credit',
    route: '/wallet',
    body: 'GET.credit is the driver\'s balance that commission and fees come from. Move demo GET.wallet money into '
        'it with Recharge; demo fares arrive here too.',
  ),
  TourStep(
    title: 'Documents and permits',
    route: '/drive/permits',
    body: 'A driver\'s licence, vehicle documents and permits, with their expiry dates, are kept here.',
  ),
  TourStep(
    title: 'myGiG',
    route: '/drive/mygig',
    body: 'myGiG lets a driver take a passenger who stops them on the street, priced by the app. Enter where they '
        'are going and send: the demo passenger accepts and the trip starts.',
  ),
  TourStep(
    title: 'Scheduled jobs',
    route: '/drive/scheduled',
    body: 'Bookings for later that a driver can take: accept a demo booking, or give it back.',
  ),
  TourStep(
    title: 'Preferences',
    route: '/drive/services',
    body: 'Choose the services you take, and your request preferences.',
  ),
];

List<TourStep> tourSteps(TourMode mode) => mode == TourMode.driver ? driverTour : passengerTour;

/// "Step 3 of 9".
String tourStepLabel(int index, int count) => 'Step ${index + 1} of $count';

/// The made-up approved driver the store review account drives as: never
/// written to the server, which refuses the account a real partner row.
Map<String, dynamic> storeReviewDemoPartner(String userId, {String? name}) => {
  'id': userId,
  'name': name ?? 'Demo driver',
  'status': 'approved',
  'vehicle': 'Perodua Bezza (demo)',
  'plate': 'DEMO 333',
  'rating': 4.9,
  'partner_types': const <String>[],
  'documents_ok': true,
};
