// City to City for drivers (migration 0308), in light and dark on a phone:
// the Requests tab (Accept at the rider's fare, Offer with the sheet, a
// locked request with Upload permit, an offer sent and withdrawn, the
// cards moving with the locked offer motion), the driving start date in
// date boxes, My trips (today, booked, offered, done), Post a trip (its
// tab; city_to_city_seats_test.dart tests posting), the trip on the day (On my way, Rider picked up, Complete trip),
// Call, giving a trip up, and Chat in the app for both sides (the ride
// chat on the booking's thread), the rider's notice when the driver gave
// the trip up, the Drive card and the driver menu row.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart' show cityToCityMenuItemId, defaultPartnerMenuItems;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/city_to_city_seats.dart' show C2cTrip;
import 'package:get_ride/src/core/reliability_settings.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/ride_chat_outbox.dart';
import 'package:get_ride/src/data/city_to_city_repository.dart';
import 'package:get_ride/src/data/models.dart' show Partner;
import 'package:get_ride/src/data/reliability_repository.dart';
import 'package:get_ride/src/data/ride_chat_repository.dart';
import 'package:get_ride/src/features/partner/city_to_city_driver_screen.dart';
import 'package:get_ride/src/features/partner/city_to_city_driver_trip.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart' show partnerMenuRowShows;
import 'package:get_ride/src/features/ride/city_to_city_parts.dart' show C2cRoundButton;
import 'package:get_ride/src/features/ride/city_to_city_steps.dart' show c2cClockProvider;
import 'package:get_ride/src/features/ride/city_to_city_trip.dart';
import 'package:get_ride/src/features/ride/ride_chat_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider, partnerProvider;
import 'package:get_ride/src/widgets/offer_motion.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// Wednesday 28 October 2026, 10:00.
final _now = DateTime(2026, 10, 28, 10);

const _quote = {'fareMode': 'card', 'suggested': 136.25, 'low': 130, 'high': 150, 'bookAheadDays': 14};

Map<String, dynamic> _row({
  String id = 'b1',
  String status = 'open',
  DateTime? leaveAt,
  String? driver,
  double? agreed,
  String rider = 'r1',
  String? dropped,
}) => {
  'id': id,
  'ref': 'CC-20481',
  'rider_id': rider,
  'pickup_name': '12 Jalan Contoh',
  'pickup_lat': 3.15,
  'pickup_lng': 101.7,
  'pickup_place': {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur', 'suburb': 'Ampang'},
  'drop_name': '21 Jalan Sampel',
  'drop_lat': 4.6,
  'drop_lng': 101.08,
  'drop_place': {'country': 'Malaysia', 'state': 'Perak', 'city': 'Ipoh'},
  'distance_km': 205,
  'duration_min': 160,
  'leave_at': (leaveAt ?? DateTime(2026, 10, 30, 9)).toUtc().toIso8601String(),
  'flexible': true,
  'passengers': 2,
  'luggage': 'suitcases',
  'fare': 140,
  'currency': 'MYR',
  'quote': _quote,
  'payment': 'cash',
  'status': status,
  'expires_at': (leaveAt ?? DateTime(2026, 10, 30, 9)).toUtc().toIso8601String(),
  'driver_id': driver,
  'agreed_fare': agreed,
  'commission_rate': driver == null ? null : 0.12,
  'driver_dropped_at': dropped,
};

Map<String, dynamic> _request(String id, {bool locked = false, Map<String, dynamic>? mine, DateTime? leaveAt}) => {
  ..._row(id: id, leaveAt: leaveAt),
  'rider_name': 'Farah T.',
  'rider_rating': 4.8,
  'eligibility': locked
      ? {
          'ok': false,
          'minYears': 3,
          'years': 10,
          'experienceOk': true,
          'needs': [
            {'name': 'Singapore permit'},
          ],
        }
      : {'ok': true, 'minYears': 3, 'years': 10, 'experienceOk': true, 'needs': []},
  'commission_rate_now': locked ? null : 0.12,
  'my_offer': mine,
};

class _Repo extends CityToCityRepository {
  _Repo() : super(_db);

  Map<String, dynamic> feed = {
    'approved': true,
    'hasArea': true,
    'years': 10,
    'canSetDrivingSince': false,
    'requests': [
      _request('q1'),
      _request('q2', locked: true, leaveAt: DateTime(2026, 10, 31, 10)),
    ],
  };
  List<Map<String, dynamic>> trips = [];
  final sentOffers = <(String, double, DateTime?)>[];
  final withdrawn = <String>[];
  final steps = <(String, C2cStatus)>[];
  final cancelled = <(String, String?)>[];
  final since = <DateTime>[];

  @override
  Future<C2cSettings> settings() async => const C2cSettings();
  @override
  Future<C2cDriverFeed> driverFeed() async => C2cDriverFeed.fromJson(feed);
  @override
  Future<List<C2cBooking>> driverTrips() async => [for (final r in trips) C2cBooking.fromRow(r)];
  @override
  Future<C2cBooking?> booking(String id) async {
    final r = trips.where((t) => t['id'] == id).firstOrNull;
    return r == null ? null : C2cBooking.fromRow(r);
  }

  @override
  Future<List<C2cOffer>> offers(String bookingId) async => const [];

  @override
  Future<List<C2cTrip>> driverSeatTrips() async => const [];

  @override
  Future<void> makeOffer(String bookingId, double price, {DateTime? leaveAt}) async {
    sentOffers.add((bookingId, price, leaveAt));
    feed = {
      ...feed,
      'requests': [
        for (final r in feed['requests'] as List)
          (r as Map)['id'] == bookingId
              ? {
                  ...r,
                  'my_offer': {
                    'id': 'o-$bookingId',
                    'price': price,
                    'leave_at': (leaveAt ?? DateTime(2026, 10, 30, 9)).toUtc().toIso8601String(),
                  },
                }
              : r,
      ],
    };
  }

  @override
  Future<void> withdrawOffer(String offerId) async {
    withdrawn.add(offerId);
    feed = {
      ...feed,
      'requests': [
        for (final r in feed['requests'] as List)
          (r as Map)['my_offer'] is Map && (r['my_offer'] as Map)['id'] == offerId ? {...r, 'my_offer': null} : r,
      ],
    };
  }

  @override
  Future<void> driverProgress(String bookingId, C2cStatus to) async {
    steps.add((bookingId, to));
    trips = [for (final t in trips) t['id'] == bookingId ? {...t, 'status': to.key} : t];
  }

  @override
  Future<void> driverCancel(String bookingId, {String? reason}) async {
    cancelled.add((bookingId, reason));
    trips = [for (final t in trips) if (t['id'] != bookingId) t];
  }

  @override
  Future<void> setDrivingSince(DateTime d) async {
    since.add(d);
    feed = {...feed, 'canSetDrivingSince': false, 'years': 6};
  }

  @override
  Future<({String name, String? phone})?> contact(String bookingId) async =>
      (name: 'Farah Tan', phone: '+60100000002');
}

/// The ride chat's repository: the thread and what was sent.
class _Chat implements RideChatRepository {
  final rows = StreamController<List<RideMessage>>.broadcast();
  final watched = <String>[];
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<List<RideMessage>> watch(String requestId) {
    watched.add(requestId);
    return (() async* {
      yield const <RideMessage>[];
      yield* rows.stream;
    })();
  }

  @override
  Future<List<RideMessage>> cachedMessages(String requestId) async => const [];

  @override
  Future<void> sendQueued(PendingRideMessage p) async => sent.add(p.toRow());

  @override
  Future<void> mark(List<String> ids, RideMessageStatus to) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<_Repo> _pump(
  WidgetTester tester,
  Widget home, {
  Brightness b = Brightness.light,
  _Repo? repo,
  String me = 'd1',
  List<Uri>? dialed,
  _Chat? chat,
}) async {
  final r = repo ?? _Repo();
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = chat ?? _Chat();
  addTearDown(c.rows.close);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        cityToCityRepositoryProvider.overrideWithValue(r),
        c2cClockProvider.overrideWithValue(() => _now),
        currentUserIdProvider.overrideWithValue(me),
        rideChatRepositoryProvider.overrideWithValue(c),
        reliabilityProvider.overrideWithValue(const ReliabilitySettings(chatOutbox: false)),
        c2cServiceActiveProvider.overrideWith((_) async => true),
        partnerProvider.overrideWith((_) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Driver'})),
        c2cLauncherProvider.overrideWithValue((u) async {
          dialed?.add(u);
          return true;
        }),
        rideChatLauncherProvider.overrideWithValue((u) async {
          dialed?.add(u);
          return true;
        }),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('Requests: accept, offer with the sheet, withdraw, a locked one (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityToCityDriverScreen(), b: b);
      expect(find.text('City to City'), findsOneWidget);
      expect(find.text('Commission 12%'), findsOneWidget);
      expect(find.text('Skip any request: no penalty'), findsOneWidget);
      expect(find.text('Coming later'), findsNothing, reason: 'Post a trip is built (0310)');
      // The cards move with the locked offer motion.
      expect(find.byType(OfferMotionList), findsOneWidget);
      expect(find.ancestor(of: find.byKey(const ValueKey('c2c-request-q1')), matching: find.byType(OfferMotion)),
          findsOneWidget);

      // An open one: the route, when, from, to, the fare and the rider.
      expect(find.text('Fri 30 Oct, 9:00 (± 30 min), 2 people'), findsOneWidget);
      expect(find.text('Pickup: Ampang, Kuala Lumpur'), findsNWidgets(2));
      expect(find.text('Drop-off: Ipoh'), findsNWidgets(2));
      expect(find.text('Farah T. 4.8'), findsNWidgets(2));
      expect(find.text('Offer RM 150'), findsOneWidget);
      expect(find.text('Accept RM 140'), findsOneWidget);
      expect(find.textContaining('→'), findsNothing);

      // A locked one: what it needs and Upload permit, no Offer or Accept.
      expect(find.byKey(const ValueKey('c2c-request-lock-q2')), findsOneWidget);
      expect(find.text('Needs: Singapore permit'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-upload-permit-q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-accept-q2')), findsNothing);

      // Accept: an offer at the rider's fare and time.
      await _tap(tester, find.byKey(const ValueKey('c2c-accept-q1')));
      await closeNotice(tester);
      expect(repo.sentOffers.single, ('q1', 140.0, null));
      await tester.pumpAndSettle();
      expect(find.text('Offer of RM 140 sent. Waiting for the rider.'), findsOneWidget);

      // Withdraw it; then Offer through the sheet: RM 145, leaving 9:15.
      await _tap(tester, find.byKey(const ValueKey('c2c-withdraw-q1')));
      expect(repo.withdrawn, ['o-q1']);
      await _tap(tester, find.byKey(const ValueKey('c2c-offer-q1')));
      expect(find.text('Your offer'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-offer-price'))).data, 'RM 150');
      expect(tester.widget<C2cRoundButton>(find.byKey(const ValueKey('c2c-offer-up'))).onPressed, isNull,
          reason: 'the top of the range');
      await _tap(tester, find.byKey(const ValueKey('c2c-offer-down')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-offer-price'))).data, 'RM 145');
      expect(find.text("+ RM 5 on the rider's RM 140"), findsOneWidget);
      for (final t in ['8:30', '8:45', '9:00', '9:15', '9:30']) {
        expect(find.byKey(ValueKey('c2c-offer-time-$t')), findsOneWidget);
      }
      await _tap(tester, find.byKey(const ValueKey('c2c-offer-time-9:15')));
      await _tap(tester, find.byKey(const ValueKey('c2c-offer-send')));
      await closeNotice(tester);
      expect(repo.sentOffers.last, ('q1', 145.0, DateTime(2026, 10, 30, 9, 15)));
    });

    testWidgets('the driving start date, in date boxes, once (${b.name})', (tester) async {
      final repo = _Repo()
        ..feed = {
          'approved': true,
          'hasArea': true,
          'canSetDrivingSince': true,
          'requests': [
            {
              ..._request('q3'),
              'eligibility': {'ok': false, 'minYears': 3, 'experienceOk': false, 'needs': []},
            },
          ],
        };
      await _pump(tester, const CityToCityDriverScreen(), b: b, repo: repo);
      expect(find.byKey(const ValueKey('c2c-driving-since-card')), findsOneWidget);
      expect(find.text('Needs: 3 years of driving'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-add-driving-since-q3')));
      expect(find.text('When did you start driving?'), findsOneWidget);
      final date = find.byKey(const ValueKey('c2c-driving-since'));
      await tester.enterText(find.descendant(of: date, matching: find.byKey(const ValueKey('date-box-day'))), '15');
      await tester.enterText(find.descendant(of: date, matching: find.byKey(const ValueKey('date-box-month'))), '6');
      await tester.enterText(find.descendant(of: date, matching: find.byKey(const ValueKey('date-box-year'))), '2020');
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('c2c-driving-since-save')));
      await closeNotice(tester);
      expect(repo.since, [DateTime(2020, 6, 15)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('c2c-driving-since-card')), findsNothing);
    });

    testWidgets('not approved: why, and no requests (${b.name})', (tester) async {
      final repo = _Repo()..feed = {'approved': false, 'requests': []};
      await _pump(tester, const CityToCityDriverScreen(), b: b, repo: repo);
      expect(find.byKey(const ValueKey('c2c-driver-blocked')), findsOneWidget);
      expect(find.text('City to City opens once your partner account is approved.'), findsOneWidget);
    });

    testWidgets('My trips and Post a trip (${b.name})', (tester) async {
      final repo = _Repo()
        ..feed = {
          'approved': true,
          'hasArea': true,
          'requests': [
            _request('q1', mine: {'id': 'o1', 'price': 150, 'leave_at': DateTime(2026, 10, 30, 9).toUtc().toIso8601String()}),
          ],
        }
        ..trips = [
          _row(id: 't1', status: 'booked', driver: 'd1', agreed: 90, leaveAt: DateTime(2026, 10, 28, 18)),
          _row(id: 't2', status: 'booked', driver: 'd1', agreed: 140, leaveAt: DateTime(2026, 11, 2, 9)),
          _row(id: 't3', status: 'completed', driver: 'd1', agreed: 120, leaveAt: DateTime(2026, 10, 20, 9)),
        ];
      await _pump(tester, const CityToCityDriverScreen(initialTab: C2cDriverTab.trips), b: b, repo: repo);
      expect(find.text('My trips (3)'), findsOneWidget);
      for (final h in ['Today', 'Booked', 'Offered', 'Done']) {
        expect(find.text(h), findsWidgets);
      }
      expect(find.text('RM 90, you keep RM 79.20 after 12%'), findsOneWidget);
      expect(find.text('Wed 28 Oct, 18:00, whole car, 2 people'), findsOneWidget);
      expect(find.text('RM 150, you keep RM 132 after 12%'), findsOneWidget);
      expect(find.text('Riders see your car and plate once booked.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-tab-post')));
      expect(find.text('Post a trip and sell seats'), findsOneWidget);
      expect(find.textContaining('See the planned form'), findsNothing);
    });

    testWidgets('the day: steps, Call, Chat in the app, give up (${b.name})', (tester) async {
      final dialed = <Uri>[];
      final chat = _Chat();
      final repo = _Repo()..trips = [_row(id: 't1', status: 'booked', driver: 'd1', agreed: 140)];
      await _pump(tester, const C2cDriverTripScreen(bookingId: 't1'), b: b, repo: repo, dialed: dialed, chat: chat);
      expect(find.text('Booked'), findsOneWidget);
      expect(find.text('Booking CC-20481 · whole car · RM 140, you keep RM 123.20 after 12%'), findsOneWidget);
      expect(find.textContaining('collect RM 140 in cash'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-driver-sms')), findsNothing, reason: 'Chat is in the app, not SMS');

      await _tap(tester, find.byKey(const ValueKey('c2c-driver-call')));
      expect(dialed.single, Uri(scheme: 'tel', path: '+60100000002'));
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-navigate')));
      expect(dialed.last.host, 'www.google.com');

      // Chat: the ride chat on the booking's thread, as the driver.
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-chat')));
      expect(find.byType(RideChatScreen), findsOneWidget);
      expect(chat.watched.last, 'c2c:t1');
      expect(find.text('Farah Tan'), findsOneWidget);
      expect(find.text('Your passenger · City to City'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-photo')), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-voice')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('ride-chat-input')), 'On my way soon');
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('ride-chat-send')));
      expect(chat.sent.single, containsPair('c2c_booking_id', 't1'));
      expect(chat.sent.single, containsPair('sender_role', 'partner'));
      expect(chat.sent.single.containsKey('request_id'), isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _tap(tester, find.byKey(const ValueKey('c2c-driver-next')));
      expect(repo.steps.last, ('t1', C2cStatus.driverArriving));
      expect(find.text('On your way to the pickup'), findsOneWidget);
      expect(find.text('Rider picked up'), findsOneWidget);

      // Give up, with a reason: back to open for other drivers.
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-give-up')));
      expect(find.text('Give up this trip?'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('c2c-driver-cancel-reason')), 'Car broke down');
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-cancel-confirm')));
      await closeNotice(tester);
      expect(repo.cancelled.single, ('t1', 'Car broke down'));
    });

    testWidgets('picked up, then Complete trip asks first (${b.name})', (tester) async {
      final repo = _Repo()..trips = [_row(id: 't1', status: 'on_trip', driver: 'd1', agreed: 140)];
      await _pump(tester, const C2cDriverTripScreen(bookingId: 't1'), b: b, repo: repo);
      expect(find.text('Rider on board'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-driver-give-up')), findsNothing, reason: 'never once on the trip');
      expect(find.text('Navigate to drop-off'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-next')));
      expect(find.text('Collect RM 140 in cash from the rider first.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-complete-confirm')));
      expect(repo.steps.single, ('t1', C2cStatus.completed));
      expect(find.text('Trip completed'), findsOneWidget);
    });

    testWidgets('a request in detail, and one no longer open (${b.name})', (tester) async {
      await _pump(tester, const C2cDriverTripScreen(bookingId: 'q1'), b: b);
      expect(find.text('Trip request'), findsOneWidget);
      expect(find.text('Offer between RM 130 and RM 150.'), findsOneWidget);
      expect(find.text('At RM 140, you keep RM 123.20 after 12%.'), findsOneWidget);
      expect(find.text('12 Jalan Contoh, Kuala Lumpur'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-driver-make-offer')), findsOneWidget);
      expect(find.text('Accept RM 140'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const C2cDriverTripScreen(bookingId: 'gone'), b: b);
      expect(find.byKey(const ValueKey('c2c-driver-gone')), findsOneWidget);
    });

    testWidgets('the rider: Chat opens the in-app chat; a driver who gave up (${b.name})', (tester) async {
      final chat = _Chat();
      final riderRepo = _RiderRepo()..row = _row(id: 'b1', status: 'booked', driver: 'd1', agreed: 140);
      await _pump(tester, const C2cTripScreen(bookingId: 'b1'), b: b, repo: riderRepo, me: 'r1', chat: chat);
      await _tap(tester, find.byKey(const ValueKey('c2c-chat')));
      expect(find.byType(RideChatScreen), findsOneWidget);
      expect(chat.watched.last, 'c2c:b1');
      expect(find.text('Your driver · City to City'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey("quick-I'm at the pickup point")));
      expect(chat.sent.single, containsPair('c2c_booking_id', 'b1'));
      expect(chat.sent.single, containsPair('sender_role', 'rider'));
      // The trip ends: read-only.
      riderRepo.row = {...riderRepo.row!, 'status': 'completed'};
      final container = ProviderScope.containerOf(tester.element(find.byType(RideChatScreen)));
      container.invalidate(c2cBookingProvider('b1'));
      await tester.pumpAndSettle();
      expect(find.text('This trip has ended. The chat is read-only.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-input')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      final dropped = _RiderRepo()..row = _row(id: 'b2', dropped: DateTime(2026, 10, 28, 9).toUtc().toIso8601String());
      await _pump(tester, const C2cTripScreen(bookingId: 'b2'), b: b, repo: dropped, me: 'r1');
      expect(find.byKey(const ValueKey('c2c-driver-dropped')), findsOneWidget);
      expect(find.text('Your driver had to cancel'), findsOneWidget);
    });

    testWidgets('someone else can\'t open a booking\'s chat (${b.name})', (tester) async {
      final riderRepo = _RiderRepo()..row = _row(id: 'b1', status: 'booked', driver: 'd1', agreed: 140);
      await _pump(tester, RideChatScreen.cityToCity(bookingId: 'b1'), b: b, repo: riderRepo, me: 'x9');
      expect(find.text('Not your trip'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-input')), findsNothing);
    });

    testWidgets('the Drive card (${b.name})', (tester) async {
      final repo = _Repo()..trips = [_row(id: 't1', status: 'booked', driver: 'd1', agreed: 90, leaveAt: DateTime(2026, 10, 29, 18))];
      await _pump(tester, const Scaffold(body: PartnerCityToCityCard()), b: b, repo: repo);
      expect(find.text('City to City · 1 request'), findsOneWidget);
      expect(find.text('Next: Kuala Lumpur to Ipoh, Thu 29 Oct, 18:00'), findsOneWidget);
    });
  }

  test('the driver menu row: after approval, while the service is on', () {
    expect([for (final d in defaultPartnerMenuItems) d.$1], contains(cityToCityMenuItemId));
    expect(partnerMenuRowShows(cityToCityMenuItemId, obdLinked: false, hasMyRideCode: false), isFalse);
    expect(partnerMenuRowShows(cityToCityMenuItemId, obdLinked: false, hasMyRideCode: false, cityToCity: true), isTrue);
    expect(
      partnerMenuRowShows(cityToCityMenuItemId, obdLinked: false, hasMyRideCode: false, cityToCity: true, approved: false),
      isFalse,
    );
  });
}

/// The rider's side: one booking.
class _RiderRepo extends _Repo {
  Map<String, dynamic>? row;

  @override
  Future<C2cBooking?> booking(String id) async => row == null ? null : C2cBooking.fromRow(row!);
}
