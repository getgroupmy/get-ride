/// In-app user guide (Account → User guide). Expo's `user-guide.tsx` described
/// Expo's own screens, including some that never existed (promo codes, intro
/// slides); this one describes this app as it is.
library;

typedef GuideTopic = ({String title, String body});
typedef GuideSection = ({String title, List<GuideTopic> topics});

const userGuide = <GuideSection>[
  (
    title: 'Getting started',
    topics: [
      (
        title: 'Signing in',
        body:
            'Enter your mobile number. If you already have an account, sign in with your 6-digit PIN; '
            'otherwise we send a one-time code by SMS and you choose a PIN. After 5 wrong PINs, sign-in '
            'is locked for 15 minutes.',
      ),
      (title: 'Forgot your PIN', body: 'On the PIN screen, choose to verify by SMS instead, then set a new PIN.'),
      (
        title: 'The tabs',
        body:
            'Ride books a trip, Trips lists your history, Wallet holds your balances, Drive is for '
            'partners, and Account has your profile, safety and settings.',
      ),
    ],
  ),
  (
    title: 'Riding',
    topics: [
      (
        title: 'Booking a ride',
        body:
            'On Ride, set the pickup (your current location by default) and where you are going. Search '
            'for a place, pick one of your recent destinations, or choose on the map. Pick a service, '
            'cash or wallet, add a note for the driver if you like, and book.',
      ),
      (
        title: 'Fares',
        body:
            'The fare is estimated from the route and, where available, live traffic. Estimated tolls '
            'are shown separately and are not included in the fare.',
      ),
      (
        title: 'Offers from drivers',
        body:
            'Where offers are allowed, a driver may propose a different price. Accept it, decline it, '
            'or raise your own fare to attract a driver sooner.',
      ),
      (
        title: 'During the trip',
        body:
            'The ride screen shows your driver, their car and where they are on the map. Tell the '
            'driver your trip code when they arrive. Use SOS · Emergency to call 999 or alert your '
            'emergency contacts with your location.',
      ),
      (
        title: 'Cancelling',
        body:
            'Until a driver accepts, you can cancel straight away. After that, cancelling asks the '
            'driver to approve it.',
      ),
      (title: 'Rewards', body: 'Completed trips can earn GET.coin. Claim it from the trip screen or the receipt.'),
    ],
  ),
  (
    title: 'Trips',
    topics: [
      (
        title: 'History and receipts',
        body:
            'Trips lists every ride you booked or drove. Open one for its receipt, which you can '
            'share or print.',
      ),
    ],
  ),
  (
    title: 'Wallet',
    topics: [
      (
        title: 'Your balances',
        body:
            'GET.wallet is your main balance. GET.credit pays partner commissions and in-app services '
            'and is recharged from GET.wallet. GET.coin is a reward coin you can redeem, trade or send.',
      ),
      (
        title: 'Paying and receiving',
        body:
            'Scan a merchant or friend\'s QR to pay from GET.wallet. Show your own QR to receive money '
            'or coins.',
      ),
      (
        title: 'Sending GET.coin',
        body:
            'Send coins by account id or phone number. The recipient has 15 minutes to accept; '
            'nothing moves until they do.',
      ),
      (title: 'Adding funds', body: 'In-app reload is not available yet. Contact support to add funds to GET.wallet.'),
    ],
  ),
  (
    title: 'Driving',
    topics: [
      (
        title: 'Becoming a partner',
        body:
            'On Drive, tap Get started and add your details, documents and vehicle. You can take jobs '
            'once an admin approves your account.',
      ),
      (
        title: 'Taking requests',
        body:
            'Go online to see open requests, nearest first. Accept one, or offer your own price where '
            'the rider allows it. Auto-accept takes new requests for you.',
      ),
      (
        title: 'Destination mode',
        body:
            'Set where you are heading and switch it on: trips that bring you at least 2 km closer are '
            'listed first, and auto-accept takes only those.',
      ),
      (
        title: 'On a trip',
        body:
            'Navigate opens your chosen navigation app (Settings → Navigation app). Mark arrived, '
            'check the rider\'s trip code, start and complete the trip. Commission is charged to '
            'GET.credit when the trip completes.',
      ),
      (
        title: 'Shared vehicles',
        body:
            'If you drive a car shared with other drivers, choose it on Drive and hand it back when '
            'you finish so the next driver can use it.',
      ),
    ],
  ),
  (
    title: 'TEKSI meter',
    topics: [
      (
        title: 'Meter Digital',
        body:
            'TEKSI drivers bill street hires on the in-app meter. It uses the car\'s OBD-II reader '
            'when one is connected and falls back to GPS where the rate card allows it.',
      ),
      (
        title: 'Ending a hire',
        body:
            'END stops the meter. Then record passengers, luggage, tolls and whether an airport was '
            'involved, and print or share the receipt.',
      ),
      (
        title: 'Readers and printers',
        body:
            'Add a Wi-Fi or Bluetooth OBD-II reader and a thermal receipt printer from the meter\'s '
            'buttons. Vehicle information shows what the reader can tell about the car.',
      ),
    ],
  ),
  (
    title: 'Safety',
    topics: [
      (
        title: 'Emergency contacts and SOS',
        body:
            'Add up to 5 trusted contacts. Emergency SOS opens a message to all of them with a map '
            'link to where you are.',
      ),
      (
        title: 'VoiceProtection',
        body:
            'When switched on, trip audio is recorded on your phone once a ride starts and kept '
            'there for 24 hours. It is only sent to our team if a ride is reported and an agent asks '
            'for it.',
      ),
    ],
  ),
  (
    title: 'Account and settings',
    topics: [
      (
        title: 'Profile',
        body:
            'Edit your name, photo and details from Account. Change your phone number or PIN from '
            'Settings.',
      ),
      (
        title: 'Invite friends',
        body:
            'Share your referral code. A friend who signs up with it, as a new account, earns GET.coin '
            'for both of you.',
      ),
      (title: 'Appearance', body: 'Choose light, dark or the system theme in Settings.'),
      (
        title: 'Help',
        body:
            'Help & support opens a chat with our team. Terms, privacy and licences are under '
            'Settings → Rules & terms.',
      ),
    ],
  ),
];

/// The sections and topics matching [query] (title or text, any case); a
/// section whose title matches keeps all its topics.
List<GuideSection> searchGuide(String query, {List<GuideSection> guide = userGuide}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return guide;
  final out = <GuideSection>[];
  for (final s in guide) {
    if (s.title.toLowerCase().contains(q)) {
      out.add(s);
      continue;
    }
    final topics = s.topics
        .where((t) => t.title.toLowerCase().contains(q) || t.body.toLowerCase().contains(q))
        .toList();
    if (topics.isNotEmpty) out.add((title: s.title, topics: topics));
  }
  return out;
}
