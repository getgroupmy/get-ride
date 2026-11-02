/// The store review account's demo (0333 and its follow-up): every feature
/// a reviewer may try, and how each plays out on the phone alone. Nothing
/// here is ever sent: the server still refuses the account every real
/// write (STORE_REVIEW_DEMO). Pure.
library;

import 'dart:math' as math;

import '../booking_modules.dart';
import '../demo_mode.dart' show demoPassengers, demoPlaces;

// ---- What the reviewer can try ------------------------------------------------------------------------

enum DemoSide { passenger, driver }

/// One feature of the app and how to try it in the demo.
class DemoFeature {
  const DemoFeature({
    required this.key,
    required this.title,
    required this.side,
    required this.how,
    this.route,
  });

  final String key;
  final String title;
  final DemoSide side;

  /// What to tap, in plain words.
  final String how;

  /// The page it starts on, where it has one of its own.
  final String? route;
}

/// Every feature, passenger side first, in the order the demo hub lists
/// them. docs/store_review_notes.md lists the same.
const demoFeatures = <DemoFeature>[
  DemoFeature(
    key: familyModuleRide,
    title: 'Ride now',
    side: DemoSide.passenger,
    route: '/',
    how: 'Choose where to, pick a car and tap Find driver. Demo drivers send offers; accept one and the car drives '
        'to you and on to the drop-off. Then pay, rate and get the receipt.',
  ),
  DemoFeature(
    key: familyModuleScheduled,
    title: 'Scheduled ride',
    side: DemoSide.passenger,
    route: '/trips/scheduled',
    how: 'On the booking panel pick a later time, then book. The booking is listed under Trips > Scheduled; tap '
        'Run it now to see the ride play out.',
  ),
  DemoFeature(
    key: familyModuleHire,
    title: 'Hire by time (hourly, daily, weekly, monthly)',
    side: DemoSide.passenger,
    route: '/',
    how: 'Tap Hire a driver on the home page, choose hours or days, and book. Now: demo drivers answer as for a '
        'ride. Later or for days: listed under Trips > Scheduled.',
  ),
  DemoFeature(
    key: familyModuleCityToCity,
    title: 'City to City',
    side: DemoSide.passenger,
    route: '/city-to-city',
    how: 'Book a whole car to another city: from, to, when, passengers and your fare. Demo drivers send offers.',
  ),
  DemoFeature(
    key: familyModuleCourier,
    title: 'Courier',
    side: DemoSide.passenger,
    how: 'Send a parcel: pickup, drop-off, size and your offer. Demo couriers send offers and deliver it.',
  ),
  DemoFeature(
    key: familyModuleFreight,
    title: 'Freight',
    side: DemoSide.passenger,
    how: 'Move goods with a van or lorry: what it is, from, to and your offer. Demo drivers send offers.',
  ),
  DemoFeature(
    key: 'family',
    title: 'Family',
    side: DemoSide.passenger,
    route: '/account/family',
    how: 'A demo family: you are the host of two members. Change a limit, add a child, see a member\'s demo '
        'trip, and book a ride for a member on the booking panel ("Who is riding").',
  ),
  DemoFeature(
    key: 'chat',
    title: 'Chat with the driver',
    side: DemoSide.passenger,
    how: 'On a demo trip tap Chat. The demo driver answers.',
  ),
  DemoFeature(
    key: 'call',
    title: 'Call the driver',
    side: DemoSide.passenger,
    how: 'On a demo trip tap Call. A demo call rings and connects; no real call is made.',
  ),
  DemoFeature(
    key: 'sos',
    title: 'SOS',
    side: DemoSide.passenger,
    route: '/account/safety',
    how: 'On a demo trip tap the red SOS button, or open Safety. Every step is shown; in the demo nothing is sent '
        'to anyone.',
  ),
  DemoFeature(
    key: 'support',
    title: 'Help: chat and call support',
    side: DemoSide.passenger,
    route: '/account/support',
    how: 'Chat with us opens a demo support chat that answers; its call button rings a demo agent.',
  ),
  DemoFeature(
    key: 'wallet',
    title: 'GET.wallet: top up and pay',
    side: DemoSide.passenger,
    route: '/wallet',
    how: 'Top up the demo wallet, pay rides with it, and pay a shop by QR (demo). No real money moves.',
  ),
  DemoFeature(
    key: 'my_qr',
    title: 'My QR',
    side: DemoSide.passenger,
    route: '/account/my-qr',
    how: 'Your own codes, to share with a driver or a friend.',
  ),
  DemoFeature(
    key: 'driver_requests',
    title: 'Ride requests',
    side: DemoSide.driver,
    route: '/drive',
    how: 'Go online. Demo requests arrive; accept one and drive it (the car moves itself), start, complete and see '
        'the fare added to your demo GET.credit.',
  ),
  DemoFeature(
    key: 'counter_offer',
    title: 'Offer your own fare',
    side: DemoSide.driver,
    route: '/drive',
    how: 'On a demo request tap Offer a fare and pick an amount. The demo passenger accepts or declines.',
  ),
  DemoFeature(
    key: 'scheduled_jobs',
    title: 'Scheduled jobs',
    side: DemoSide.driver,
    route: '/drive/scheduled',
    how: 'Demo bookings for later: accept one, show interest, or give one back.',
  ),
  DemoFeature(
    key: 'mygig',
    title: 'myGiG (street hail)',
    side: DemoSide.driver,
    route: '/drive/mygig',
    how: 'Enter where the passenger is going and send. The demo passenger accepts the fare and the trip starts.',
  ),
  DemoFeature(
    key: 'credit',
    title: 'GET.credit',
    side: DemoSide.driver,
    route: '/wallet',
    how: 'Move demo GET.wallet money into GET.credit, and see demo earnings arrive.',
  ),
  DemoFeature(
    key: 'earnings',
    title: 'Earnings and statements',
    side: DemoSide.driver,
    route: '/drive/earnings',
    how: 'What a driver made by day and week, and monthly statements (empty for the demo account).',
  ),
  DemoFeature(
    key: 'permits',
    title: 'Documents and permits',
    side: DemoSide.driver,
    route: '/drive/permits',
    how: 'A driver\'s licence, vehicle papers and permits with their expiry dates.',
  ),
];

List<DemoFeature> demoFeaturesFor(DemoSide side) => [for (final f in demoFeatures) if (f.side == side) f];

/// The words on top of every simulated screen.
const demoNothingSent = 'Demo: simulated on this phone. Nothing is sent, charged, called or texted.';

// ---- A demo trip, by module -----------------------------------------------------------------------------

/// What a demo trip says at each of its phases, by the module it was
/// booked in.
class DemoTripWords {
  const DemoTripWords({
    required this.title,
    required this.arriving,
    required this.arrived,
    required this.onTrip,
    required this.done,
    required this.doneDetail,
  });

  final String title, arriving, arrived, onTrip, done, doneDetail;
}

DemoTripWords demoTripWords(String module, {required String driver, required String pickup, required String drop}) =>
    switch (module) {
      familyModuleCourier || 'courier_addons' => DemoTripWords(
        title: 'Your delivery',
        arriving: '$driver is coming to collect your parcel at $pickup',
        arrived: '$driver is collecting your parcel',
        onTrip: 'Your parcel is on the way to $drop',
        done: 'Parcel delivered',
        doneDetail: 'Delivered at $drop',
      ),
      familyModuleFreight || 'freight_addons' => DemoTripWords(
        title: 'Your freight',
        arriving: '$driver is driving to $pickup',
        arrived: '$driver is loading your goods',
        onTrip: 'Your goods are on the way to $drop',
        done: 'Goods delivered',
        doneDetail: 'Unloaded at $drop',
      ),
      familyModuleHire => DemoTripWords(
        title: 'Your hire',
        arriving: '$driver is heading to $pickup',
        arrived: '$driver is waiting at $pickup',
        onTrip: 'Your hire is running: the driver and car are yours',
        done: 'Hire ended',
        doneDetail: 'The hire ended at $drop',
      ),
      familyModuleCityToCity || familyModuleSeatTrip => DemoTripWords(
        title: 'City to City',
        arriving: '$driver is heading to $pickup',
        arrived: '$driver is waiting at $pickup',
        onTrip: 'On the road to $drop',
        done: 'You arrived in $drop',
        doneDetail: 'Trip from $pickup to $drop complete',
      ),
      _ => DemoTripWords(
        title: 'Your ride',
        arriving: '$driver is heading to $pickup',
        arrived: '$driver is waiting at $pickup',
        onTrip: 'Heading to $drop',
        done: 'Trip complete',
        doneDetail: 'You arrived at $drop',
      ),
    };

/// The module a demo ride row was booked in: its own `demo_module`, else
/// what its columns say (as the server reads a ride request).
String demoModuleOf(Map<String, dynamic> row) {
  final own = row['demo_module'];
  if (own is String && own.isNotEmpty) return own;
  return rideBookingModule(
    courier: row['parcel_size'] != null,
    freight: row['cargo_description'] != null,
    hire: row['hire_hours'] != null || row['hire_package'] != null,
    scheduled: row['pickup_at'] != null,
  );
}

// ---- Chat ----------------------------------------------------------------------------------------------

enum DemoPeer { driver, passenger, support, courier }

/// The first line the other side sends when a demo chat opens.
String demoChatGreeting(DemoPeer peer, String name) => switch (peer) {
  DemoPeer.driver => 'Hi, this is $name, your driver. I\'m on my way.',
  DemoPeer.courier => 'Hi, $name here. I\'ll collect your parcel shortly.',
  DemoPeer.passenger => 'Hi, I\'m at the pickup point.',
  DemoPeer.support => 'Hi, this is the GET.ride support team. How can we help?',
};

/// The demo reply to [text]: a short, sensible answer for its words, else
/// one of a few in turn ([turn]).
String demoChatReply(String text, DemoPeer peer, {int turn = 0}) {
  final t = text.toLowerCase();
  bool has(List<String> w) => w.any(t.contains);
  if (peer == DemoPeer.support) {
    if (has(['refund', 'charge', 'money', 'pay'])) {
      return 'We can look into any payment for you. This is the demo account, so no real money moved.';
    }
    if (has(['lost', 'forgot', 'left'])) return 'Sorry to hear that. We\'ll contact the driver about your item.';
    if (has(['thank'])) return 'You\'re welcome. Anything else?';
    const general = [
      'Thanks for your message. An agent would reply here; this is a demo answer.',
      'Got it. In a real chat we\'d look at your trip and come back to you here.',
    ];
    return general[turn % general.length];
  }
  if (has(['where', 'how long', 'eta', 'far'])) {
    return peer == DemoPeer.passenger ? 'I\'m by the main entrance.' : 'About 3 minutes away.';
  }
  if (has(['wait', 'late', 'minute'])) return 'No problem, I\'ll wait.';
  if (has(['thank'])) return 'You\'re welcome!';
  if (has(['call'])) return 'Sure, you can call me from the trip screen.';
  if (has(['luggage', 'bag', 'parcel'])) return 'That\'s fine, there\'s space.';
  const general = ['OK, noted.', 'Sure.', 'See you soon.'];
  return general[turn % general.length];
}

/// How long the other side "types" before a demo reply shows.
const demoChatReplyAfter = Duration(milliseconds: 1500);

// ---- Calls ---------------------------------------------------------------------------------------------

enum DemoCallState { ringing, connected, ended }

/// How long a demo call rings before it is answered.
const demoCallRingFor = Duration(seconds: 3);

DemoCallState demoCallStateAt(Duration elapsed, {bool hungUp = false}) {
  if (hungUp) return DemoCallState.ended;
  return elapsed < demoCallRingFor ? DemoCallState.ringing : DemoCallState.connected;
}

/// "01:05" since the call connected.
String demoCallClock(Duration elapsed) {
  final talk = elapsed - demoCallRingFor;
  if (talk.isNegative) return '00:00';
  final m = talk.inMinutes, s = talk.inSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

// ---- SOS -----------------------------------------------------------------------------------------------

/// What a real SOS does, step by step, as the demo shows it.
const demoSosSteps = <String>[
  'GET.ride\'s safety team would see your trip and where you are, and get in touch.',
  'Your location would keep updating for them for the next minutes.',
  'You could call the emergency number (999) straight from here.',
  'Your emergency contacts could get a text with your location, the driver and the car.',
];

const demoSosNothingSent = 'Demo account: nothing was sent. No one was alerted, called or texted.';

// ---- Driver: your own fare ---------------------------------------------------------------------------

/// The amounts a demo driver can offer on [fare]: the fare and three steps up.
List<double> demoCounterAmounts(double fare) => [for (final step in const [0, 2, 5, 10]) fare + step];

/// Whether the demo passenger takes [offer] on a request of [fare]: up to
/// 30% over it.
bool demoPassengerTakes(double offer, double fare) => offer <= fare * 1.3 + 0.001;

/// How long the demo passenger thinks about an offer.
const demoCounterAnswerAfter = Duration(seconds: 2);

// ---- Family --------------------------------------------------------------------------------------------

/// The demo family (family_mine's shape): the reviewer hosts a spouse and a
/// child; every booking module switched on.
Map<String, dynamic> demoFamilyJson({required String hostName, List<Map<String, dynamic>>? members, DateTime? now}) {
  final list = members ?? demoFamilyMembers(now ?? DateTime.now());
  return {
    'role': 'host',
    'family': {'id': 'demo-family', 'hostName': hostName, 'cap': 6, 'count': list.length, 'spent': 38.5},
    'members': list,
    'settings': const {'enabled': true, 'children': true},
    'modules': [
      for (final m in bookingModules)
        if (m.built)
          {'key': m.key, 'name': m.name, 'familyPays': true, 'bookForMember': !m.familyPaysOnly, 'childAllowed': true,
            'liveShare': true},
    ],
  };
}

List<Map<String, dynamic>> demoFamilyMembers(DateTime now) => [
  {
    'id': 'demo-member-1',
    'name': 'Aisha',
    'kind': 'member',
    'status': 'active',
    'relation': 'Spouse',
    'phone': '+60 12-000 0333',
    'monthlyLimit': 300,
    'perRideLimit': 50,
    'location': 'ride',
    'locationNow': 'ride',
    'spent': 38.5,
    'limit': 300,
    'left': 261.5,
    'onTrip': true,
  },
  {
    'id': 'demo-member-2',
    'name': 'Adam',
    'kind': 'child',
    'status': 'active',
    'relation': 'Son',
    'birthDate': '${now.year - 10}-03-14',
    'monthlyLimit': 100,
    'perRideLimit': 20,
    'location': 'ride',
    'locationNow': 'ride',
    'spent': 0,
    'limit': 100,
    'left': 100,
  },
];

/// Aisha's demo trip, as the host's live list shows it (family_live).
Map<String, dynamic> demoFamilyLiveJson(DateTime now) => {
  'memberId': 'demo-member-1',
  'name': 'Aisha',
  'kind': 'member',
  'trip': 'demo-family-trip',
  'status': 'on_trip',
  'pickup': demoPlaces[1].$1,
  'drop': demoPlaces[0].$1,
  'driver': 'Mellier',
  'plate': 'DEMO 128',
  'lat': (demoPlaces[1].$3 + demoPlaces[0].$3) / 2,
  'lng': (demoPlaces[1].$4 + demoPlaces[0].$4) / 2,
  'at': now.toUtc().toIso8601String(),
  'area': 'Kuala Lumpur',
};

// ---- Scheduled jobs for a demo driver ----------------------------------------------------------------

/// Two demo bookings for later a demo driver may take (scheduled_rides
/// rows): tomorrow morning and the day after.
List<Map<String, dynamic>> demoOpenScheduledRows(DateTime now, {int seed = 333}) {
  final rnd = math.Random(seed);
  Map<String, dynamic> row(int n, Duration after) {
    final a = demoPlaces[rnd.nextInt(demoPlaces.length)];
    var b = demoPlaces[rnd.nextInt(demoPlaces.length)];
    while (b == a) {
      b = demoPlaces[rnd.nextInt(demoPlaces.length)];
    }
    final day = DateTime(now.year, now.month, now.day).add(after);
    return {
      'id': 'demo-job-scheduled-$n',
      'pickup_at': day.toUtc().toIso8601String(),
      'status': 'scheduled',
      'service': 'Car',
      'pickup_address': '${a.$1}, ${a.$2}',
      'drop_address': '${b.$1}, ${b.$2}',
      'fare': 18.0 + rnd.nextInt(30),
      'currency': 'MYR',
      'distance_km': 6.0 + rnd.nextInt(20),
      'booked_for_name': demoPassengers[rnd.nextInt(demoPassengers.length)],
    };
  }

  return [row(1, const Duration(days: 1, hours: 8, minutes: 30)), row(2, const Duration(days: 2, hours: 17))];
}
