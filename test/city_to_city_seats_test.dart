// City to City per-seat trips (migration 0310): the pure logic (the seat
// rules merged by region, the price limits, door pickup's extra, the repeat
// dates, the words) on the same cases as the server's twin
// (supabase/tests/city_to_city_seats_0310.sql), and the screens in light
// and dark: the admin page (board 15), Post a trip (board 16), the driver's
// posted trip (requests with the locked offer motion, passengers, start),
// and Find a trip and Book a seat (board 17), with the rider's trip page for
// a request waiting for the driver and one declined.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/city_to_city/city_to_city_seats_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/city_to_city_seats.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/inbox.dart' show InboxIcon, inboxIconFor;
import 'package:get_ride/src/core/push_logic.dart' show pushRouteFor;
import 'package:get_ride/src/data/city_to_city_repository.dart';
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/features/partner/city_to_city_driver_screen.dart';
import 'package:get_ride/src/features/partner/city_to_city_post_trip.dart';
import 'package:get_ride/src/features/ride/city_to_city_screen.dart';
import 'package:get_ride/src/features/ride/city_to_city_steps.dart' show c2cAreaProvider, c2cClockProvider;
import 'package:get_ride/src/features/ride/city_to_city_trip.dart';
import 'package:get_ride/src/features/ride/freight_screen.dart' show freightPlaceSearchProvider, freightRouteProvider;
import 'package:get_ride/src/providers.dart' show currentUserIdProvider, partnerProvider, profileProvider;
import 'package:get_ride/src/data/models.dart' show Partner;
import 'package:get_ride/src/widgets/offer_motion.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// Wednesday 28 October 2026, 10:00.
final _now = DateTime(2026, 10, 28, 10);

const _my = 'Malaysia';
const _cheras = Geo(country: _my, state: 'Kuala Lumpur', city: 'Kuala Lumpur', suburb: 'Cheras');
const _ipoh = Geo(country: _my, state: 'Perak', city: 'Ipoh');
const _klState = C2cPlace(level: 'state', country: _my, state: 'Kuala Lumpur');
const _klCity = C2cPlace(level: 'city', country: _my, state: 'Kuala Lumpur', city: 'Kuala Lumpur');
const _cherasPlace = C2cPlace(level: 'suburb', country: _my, state: 'Kuala Lumpur', city: 'Kuala Lumpur', suburb: 'Cheras');
const _perak = C2cPlace(level: 'state', country: _my, state: 'Perak');

C2cSeatRule _default({bool on = true}) =>
    C2cSeatRule(id: 's0', createdAt: DateTime(2026), values: {...c2cSeatDefaults, 'seats_on': on});

final _rules = [
  _default(),
  C2cSeatRule(
    id: 's1',
    place: _klState,
    createdAt: DateTime(2026, 2),
    values: const {'join_mode': 'approve', 'approve_hours': 3, 'approve_before_min': 90},
  ),
  C2cSeatRule(
    id: 's2',
    place: _cherasPlace,
    createdAt: DateTime(2026, 3),
    values: const {'max_seats': 3, 'max_per_booking': 2, 'cutoff_min': 30, 'post_ahead_days': 20},
  ),
  C2cSeatRule(id: 's3', place: _klCity, active: false, createdAt: DateTime(2026, 4), values: const {'seats_on': false}),
];

String _iso(DateTime d) => d.toUtc().toIso8601String();

/// Trip A on the board: KL to Ipoh, Sat 31 Oct 8:00, RM 45, instant, door
/// pickup, a parcel slot.
Map<String, dynamic> _trip({List<Map<String, dynamic>> bookings = const [], bool instant = true}) => {
  'id': 't1',
  'ref': 'CT-5001',
  'driver_id': 'd1',
  'from_name': 'Kuala Lumpur',
  'from_place': {'country': _my, 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'},
  'to_name': 'Ipoh',
  'to_place': {'country': _my, 'state': 'Perak', 'city': 'Ipoh'},
  'distance_km': 205,
  'duration_min': 150,
  'leave_at': _iso(DateTime(2026, 10, 31, 8)),
  'meeting_points': [
    {'name': 'Petrol station, Jalan Contoh', 'lat': 3.13, 'lng': 101.72, 'minutes': 0},
    {'name': 'Bus stop, Jalan Pahang', 'lat': 3.15, 'lng': 101.70, 'minutes': 15},
  ],
  'seats_total': 3,
  'seats_left': 2,
  'seat_price': 45,
  'currency': 'MYR',
  'join_mode': instant ? 'instant' : 'approve',
  'women_only': false,
  'door_pickup': true,
  'door_on': true,
  'door_max_km': 5,
  'door_per_km': 1,
  'parcel_slots': 1,
  'parcels_left': 1,
  'parcel_max_size': 'small',
  'parcel_price': 15,
  'luggage': 'suitcase',
  'repeat_mode': 'weekly',
  'driver_name': 'Hafiz R.',
  'driver_rating': 4.9,
  'car': 'Honda City',
  'plate': 'VKB 5512',
  'status': 'scheduled',
  'max_per_booking': 4,
  'coriders_on': true,
  'may_book': true,
  'bookings': bookings,
};

Map<String, dynamic> _seat({String id = 'sb1', String status = 'booked', int seats = 1, String? kind, String? expires}) => {
  'id': id,
  'ref': 'CC-20510',
  'status': status,
  'item': 'seat',
  'seats': seats,
  'rider_name': 'Aina C.',
  'rider_rating': 4.8,
  'passenger_names': seats > 1 ? [{'name': 'Aina'}, {'name': 'Wei'}] : null,
  'pickup_kind': kind ?? 'meeting',
  'pickup_name': 'Bus stop, Jalan Pahang',
  'leave_at': _iso(DateTime(2026, 10, 31, 8, 15)),
  'fare': 45.0 * seats,
  'currency': 'MYR',
  'payment': 'cash',
  'expires_at': expires,
};

/// A seat booking as the rider's trip page reads it (c2c_bookings).
Map<String, dynamic> _bookingRow({String status = 'booked', String? payStatus, String? cancelledBy}) => {
  'id': 'sb1',
  'ref': 'CC-20510',
  'rider_id': 'r1',
  'trip_kind': 'per_seat',
  'trip_id': 't1',
  'item': 'seat',
  'pickup_kind': 'meeting',
  'seat_price': 45,
  'pickup_name': 'Bus stop, Jalan Pahang',
  'pickup_lat': 3.15,
  'pickup_lng': 101.7,
  'pickup_place': {'country': _my, 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'},
  'drop_name': 'Ipoh',
  'drop_lat': 4.6,
  'drop_lng': 101.09,
  'drop_place': {'country': _my, 'state': 'Perak', 'city': 'Ipoh'},
  'distance_km': 205,
  'duration_min': 150,
  'leave_at': _iso(DateTime(2026, 10, 31, 8, 15)),
  'flexible': false,
  'passengers': 2,
  'passenger_names': [{'name': 'Aina'}, {'name': 'Wei'}],
  'luggage': 'suitcases',
  'fare': 90,
  'currency': 'MYR',
  'quote': {'seatPrice': 45, 'seats': 2, 'doorExtra': 0},
  'payment': 'in_app',
  'status': status,
  'expires_at': status == 'requested' ? _iso(DateTime(2026, 10, 28, 12)) : null,
  'driver_id': 'd1',
  'agreed_fare': status == 'booked' ? 90 : null,
  'pay_status': payStatus,
  'cancelled_by': cancelledBy,
};

class _Repo extends CityToCityRepository {
  _Repo() : super(_db);

  List<C2cSeatRule> seatList = [_default(), C2cSeatRule(id: 's1', place: _klState, createdAt: DateTime(2026, 2))];
  final savedRules = <C2cSeatRule>[];
  List<Map<String, dynamic>> posted = [];
  final posts = <Map<String, Object?>>[];
  final decided = <(String, bool)>[];
  final progress = <(String, C2cTripStatus)>[];
  final cancelledTrips = <String>[];
  final booked = <Map<String, Object?>>[];
  final cancelled = <String>[];
  Map<String, dynamic> row = _bookingRow();

  @override
  Future<C2cSettings> settings() async => const C2cSettings();
  @override
  Future<List<C2cRule>> rules() async => [
    const C2cRule(id: 'r1', from: [_klCity], to: [_perak], tripKind: 'per_seat', fareMode: C2cFareMode.fixed, fixedFare: 45),
  ];
  @override
  Future<List<C2cSeatRule>> seatRules() async => seatList;
  @override
  Future<void> saveSeatRule(C2cSeatRule r) async => savedRules.add(r);

  @override
  Future<C2cPostTerms> postTerms({required C2cEnd from, required C2cEnd to, required double km, required double min}) async =>
      C2cPostTerms.fromJson({
        'terms': {...c2cSeatDefaults, 'seats_on': true},
        'limits': {'mode': 'range', 'low': 35, 'high': 56, 'wholeCar': 140, 'currency': 'MYR'},
        'commissionRate': 0.12,
        'eligibility': {'ok': true, 'experienceOk': true, 'needs': []},
        'approved': true,
        'verifiedWoman': false,
        'available': true,
      });

  @override
  Future<({List<String> ids, int posted, int skipped})> postTrip({
    required C2cEnd from,
    required C2cEnd to,
    required double km,
    required double min,
    required DateTime leaveAt,
    required List<C2cMeetingPoint> points,
    required int seats,
    required double seatPrice,
    C2cJoinMode? join,
    bool womenOnly = false,
    bool door = false,
    int parcelSlots = 0,
    C2cParcelSize? parcelSize,
    double? parcelPrice,
    C2cRepeat repeat = C2cRepeat.none,
    DateTime? repeatUntil,
    bool suitcase = false,
    String? note,
    String? timezone,
  }) async {
    posts.add({'from': from.name, 'to': to.name, 'leave': leaveAt, 'seats': seats, 'price': seatPrice, 'join': join,
        'door': door, 'points': points.length});
    return (ids: ['t9'], posted: 1, skipped: 0);
  }

  @override
  Future<List<C2cTrip>> driverSeatTrips() async => [for (final t in posted) C2cTrip.fromJson(t)];
  @override
  Future<void> seatDecide(String bookingId, {required bool approve, String? reason}) async {
    decided.add((bookingId, approve));
    posted = [
      for (final t in posted)
        {
          ...t,
          'bookings': [
            for (final b in t['bookings'] as List)
              (b as Map)['id'] == bookingId ? {...b, 'status': approve ? 'booked' : 'declined'} : b,
          ],
        },
    ];
  }

  @override
  Future<void> tripProgress(String tripId, C2cTripStatus to) async {
    progress.add((tripId, to));
    posted = [for (final t in posted) t['id'] == tripId ? {...t, 'status': to.key} : t];
  }

  @override
  Future<({int cancelled, double fees, int riders})> tripCancel(String tripId, {String? reason, bool series = false}) async {
    cancelledTrips.add(tripId);
    return (cancelled: 1, fees: 0.0, riders: 0);
  }

  @override
  Future<List<C2cTrip>> searchTrips({required Geo from, required Geo to, DateTime? day, int seats = 1}) async =>
      [C2cTrip.fromJson(_trip())];
  @override
  Future<C2cTrip?> tripForRider(String id) async => C2cTrip.fromJson(_trip());
  @override
  Future<C2cPayInfo> seatPayInfo(String tripId) async => C2cPayInfo.fromJson({
    'when': 'hold', 'wallet': true, 'coin': false, 'mix': false, 'walletBalance': 200, 'coinBalance': 0, 'dues': [],
  });

  @override
  Future<({String id, String status})> bookSeat({
    required String tripId,
    required int seats,
    required Map<String, dynamic> pickup,
    required C2cPayment payment,
    List<C2cPassenger> passengers = const [],
    C2cPayWay? way,
    double? expected,
    Map<String, dynamic>? parcel,
    String? note,
  }) async {
    booked.add({'trip': tripId, 'seats': seats, 'pickup': pickup, 'payment': payment, 'names': [for (final p in passengers) p.name],
        'way': way, 'expected': expected});
    return (id: 'sb1', status: 'booked');
  }

  @override
  Future<List<({String name, double? rating, String pickup, int seats})>> coriders(String bookingId) async =>
      [(name: 'Kumar', rating: 4.7, pickup: 'Cheras', seats: 1)];
  @override
  Future<List<C2cBooking>> myTrips() async => [C2cBooking.fromRow(row)];
  @override
  Future<C2cBooking?> booking(String id) async => C2cBooking.fromRow(row);
  @override
  Future<List<C2cOffer>> offers(String bookingId) async => const [];
  @override
  Future<({double fee, String feeStatus})> cancel(String bookingId, {String? reason}) async {
    cancelled.add(bookingId);
    row = {...row, 'status': 'cancelled', 'cancelled_by': 'rider'};
    return (fee: 0.0, feeStatus: 'none');
  }

  @override
  Future<({String name, String? phone})?> contact(String bookingId) async => (name: 'Hafiz', phone: '+60100000001');
  @override
  Future<C2cDriverFeed> driverFeed() async => C2cDriverFeed.fromJson({'approved': true, 'hasArea': true, 'requests': []});
  @override
  Future<List<C2cBooking>> driverTrips() async => const [];
}

final _regions = [
  RegionEntry(id: 'my', values: {'country': _my}),
  RegionEntry(id: 'kl', values: {'country': _my, 'state': 'Kuala Lumpur'}),
  RegionEntry(id: 'sb', values: {'country': _my, 'state': 'Sabah'}),
];

/// The places the search returns, one call after another.
List<Place> _places = [];

Future<_Repo> _pump(WidgetTester tester, Widget home, {Brightness b = Brightness.light, _Repo? repo}) async {
  final r = repo ?? _Repo();
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        cityToCityRepositoryProvider.overrideWithValue(r),
        pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
        regionsProvider.overrideWith((ref) async => _regions),
        c2cClockProvider.overrideWithValue(() => _now),
        currentUserIdProvider.overrideWithValue('d1'),
        c2cServiceActiveProvider.overrideWith((_) async => true),
        partnerProvider.overrideWith((_) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Driver'})),
        profileProvider.overrideWith((_) async => null),
        freightPlaceSearchProvider.overrideWithValue((context, {required title, near, onMap = false}) async =>
            _places.isEmpty ? null : _places.removeAt(0)),
        c2cAreaProvider.overrideWithValue((p) async => p.latitude > 4 ? _ipoh : _cheras),
        freightRouteProvider.overrideWithValue((a, b) async => (km: 205.0, min: 150.0)),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await closeAnyNotice(tester);
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

Future<void> _date(WidgetTester tester, Key key, int d, int m, int y) async {
  final f = find.byKey(key);
  await tester.ensureVisible(f);
  await tester.enterText(find.descendant(of: f, matching: find.byKey(const ValueKey('date-box-day'))), '$d');
  await tester.enterText(find.descendant(of: f, matching: find.byKey(const ValueKey('date-box-month'))), '$m');
  await tester.enterText(find.descendant(of: f, matching: find.byKey(const ValueKey('date-box-year'))), '$y');
  await tester.pumpAndSettle();
}

const _kl = Place(name: 'Kuala Lumpur', address: 'Kuala Lumpur', point: LatLng(3.15, 101.71));
const _ip = Place(name: 'Ipoh', address: 'Ipoh, Perak', point: LatLng(4.60, 101.09));

void main() {
  group('rules merged by region (c2c_seat_terms_for)', () {
    test('a region rule overrides only what it sets; the most specific wins; inactive skipped', () {
      final t = c2cSeatTermsFor(_rules, _cheras);
      expect(t.seatsOn, isTrue, reason: 'the inactive city rule is skipped');
      expect(t.joinMode, C2cJoinMode.approve);
      expect((t.approveHours, t.approveBeforeMin), (3, 90));
      expect((t.cutoffMin, t.maxSeats, t.maxPerBooking), (30, 3, 2));
      expect((t.priceMode, t.pctLow), (C2cSeatPriceMode.range, 25));
      expect(t.ruleIds, ['s2', 's1', 's0']);
      final e = c2cSeatTermsFor(_rules, _ipoh);
      expect((e.joinMode, e.maxSeats), (C2cJoinMode.driverPicks, 4));
      expect(c2cSeatTermsFor([_default(on: false)], _ipoh).seatsOn, isFalse);
    });

    test('the rule above, setting a part and leaving it', () {
      final r = _rules[2];
      final above = c2cSeatTermsAbove(_rules, r);
      expect(above.joinMode, C2cJoinMode.approve, reason: 'Cheras sits in the Kuala Lumpur state rule');
      final own = r.withPart(C2cSeatPart.door, above);
      expect(own.sets(C2cSeatPart.door), isTrue);
      expect(own.values['door_max_km'], 5);
      expect(own.withPart(C2cSeatPart.door, null).sets(C2cSeatPart.door), isFalse);
      final back = C2cSeatRule.fromRow({...own.toRow(), 'created_at': '2026-03-01T00:00:00Z'});
      expect(back.toRow(), own.toRow());
      expect(own.toRow()['place'], _cherasPlace.toJson());
    });

    test('problems', () {
      expect(_default().problem, isNull);
      expect(C2cSeatRule(id: 'x', values: const {'seats_on': true}).problem, 'The default sets every part.');
      expect(
        C2cSeatRule(place: _klState, values: {...c2cSeatDefaults, 'pct_low': 50, 'pct_high': 40}).problem,
        'The lowest % must not be above the highest.',
      );
      expect(C2cSeatRule(place: _klState).problem, isNull, reason: 'a region rule may set nothing');
    });

    test('the summary line', () {
      expect(c2cSeatRuleSummary(C2cSeatTerms(c2cSeatDefaults)), 'Off');
      expect(c2cSeatRuleSummary(C2cSeatTerms({...c2cSeatDefaults, 'seats_on': true})), 'driver picks, range, door pickup');
      expect(
        c2cSeatRuleSummary(C2cSeatTerms({...c2cSeatDefaults, 'seats_on': true, 'join_mode': 'approve',
            'price_mode': 'fixed', 'door_on': false})),
        'driver approves, fixed',
      );
    });
  });

  group("price, door pickup, repeats (the server's cases)", () {
    final terms = C2cSeatTerms({...c2cSeatDefaults, 'seats_on': true});
    test('limits', () {
      var l = c2cSeatLimitsOf(terms, null, 140);
      expect((l.mode, l.low, l.high), (C2cSeatPriceMode.range, 35.0, 56.0));
      expect(l.hint, "Allowed RM 35 to 56 a seat (admin's range)");
      l = c2cSeatLimitsOf(C2cSeatTerms({...terms.values, 'range_mode': 'amount'}), null, 140);
      expect((l.low, l.high), (30.0, 60.0));
      l = c2cSeatLimitsOf(C2cSeatTerms({...terms.values, 'price_mode': 'fixed'}), null, 140);
      expect((l.mode, l.price), (C2cSeatPriceMode.fixed, 46.0));
      l = c2cSeatLimitsOf(C2cSeatTerms({...terms.values, 'price_mode': 'free'}), null, 140);
      expect((l.mode, l.low, l.high), (C2cSeatPriceMode.free, 1.0, null));
      const range = C2cRule(id: 'r', tripKind: 'per_seat', rangeMode: C2cRangeMode.set, rangeLow: 40, rangeHigh: 50);
      l = c2cSeatLimitsOf(terms, range, 140);
      expect((l.low, l.high), (40.0, 50.0));
      const fixed = C2cRule(id: 'r', tripKind: 'per_seat', fareMode: C2cFareMode.fixed, fixedFare: 45);
      l = c2cSeatLimitsOf(terms, fixed, 140);
      expect((l.mode, l.price), (C2cSeatPriceMode.fixed, 45.0));
      expect(c2cSeatLimitsOf(C2cSeatTerms({...terms.values, 'price_mode': 'free'}), fixed, 140).mode,
          C2cSeatPriceMode.free);
      l = c2cSeatLimitsOf(terms, null, 2);
      expect((l.low, l.high), (1.0, 1.0));
      expect(c2cSeatLimitsOf(terms, null, 140).problem(60), 'A seat is at most RM 56.');
      expect(c2cSeatLimitsOf(terms, null, 140).clamp(20), 35);
      expect(c2cSeatRangeExample(terms), 'Kuala Lumpur to Ipoh, whole car RM 140: seat 25% to 40% = RM 35 to RM 56.');
    });

    test("a route's own seat price: per-seat route rules only", () {
      const whole = C2cRule(id: 'w', from: [_klCity], to: [_perak], fareMode: C2cFareMode.fixed, fixedFare: 140);
      const seat = C2cRule(id: 's', from: [_klCity], to: [_perak], tripKind: 'per_seat', fareMode: C2cFareMode.fixed,
          fixedFare: 45);
      expect(c2cSeatRouteRuleFor([whole, seat], _cheras, _ipoh)?.id, 's');
      expect(c2cRuleFor([whole, seat], _cheras, _ipoh)?.rule.id, 'w');
      expect(c2cSeatRouteRuleFor([whole], _cheras, _ipoh), isNull);
      expect(seat.toRow()['trip_kind'], 'per_seat');
    });

    test("door pickup's extra", () {
      expect(c2cDoorExtra(2.44, 1), 2.4);
      expect(c2cDoorExtra(2.45, 1), 2.5);
      expect(c2cDoorExtra(3.1, 1.5), 4.65);
      expect(c2cDoorExtra(0, 1), 0);
      final trip = C2cTrip.fromJson(_trip());
      final near = c2cDoorQuote(trip, 3.15, 101.74);
      expect(near.km, (c2cKmBetween(3.15, 101.74, 3.13, 101.72) * 10).round() / 10);
      expect(near.nearest?.name, 'Petrol station, Jalan Contoh');
      expect((near.ok, near.extra), (true, c2cDoorExtra(near.km, 1)));
      expect(c2cDoorQuote(trip, 3.30, 101.72).ok, isFalse);
      expect(c2cDoorNote(2.4, 2.4), 'Door pickup · 2.4 km off route · + RM 2.40');
      expect(c2cDoorLine(5, 1), 'Door pickup within 5 km (+ RM 1 a km)');
    });

    test('repeat dates', () {
      expect(c2cRepeatDates(DateTime(2026, 10, 31, 8), C2cRepeat.weekly, DateTime(2026, 11, 21)),
          [DateTime(2026, 11, 7, 8), DateTime(2026, 11, 14, 8), DateTime(2026, 11, 21, 8)]);
      expect(c2cRepeatDates(DateTime(2026, 10, 30, 7, 30), C2cRepeat.weekdays, DateTime(2026, 11, 4)),
          [DateTime(2026, 11, 2, 7, 30), DateTime(2026, 11, 3, 7, 30), DateTime(2026, 11, 4, 7, 30)]);
      expect(c2cRepeatDates(DateTime(2026, 10, 30, 7, 30), C2cRepeat.daily, DateTime(2026, 11, 1)).length, 2);
      expect(c2cRepeatDates(DateTime(2026, 10, 30, 7, 30), C2cRepeat.daily, DateTime(2027, 12, 1)).length, 60);
      expect(c2cRepeatDates(DateTime(2026, 10, 30), C2cRepeat.none, DateTime(2026, 12, 1)), isEmpty);
      expect(c2cRepeatLine(C2cRepeat.weekly, DateTime(2026, 10, 31)), 'Repeat every Saturday');
    });

    test('the words', () {
      expect(c2cEarnLine(3, 45), '3 x RM 45 = RM 135');
      expect(c2cSeatKeepLine(135, 0.12), 'You keep RM 118.80 after the 12% City to City commission.');
      expect(c2cPostButton(3), 'Post trip with 3 seats');
      expect(c2cPostButton(1, trips: 4), 'Post trip with 1 seat (4 trips)');
      expect(c2cBookButton(2, 92.4), 'Book 2 seats · RM 92.40');
      expect(c2cBookButton(1, 45, instant: false), 'Request 1 seat · RM 45');
      expect(c2cBookButton(1, 15, parcel: true), 'Send parcel · RM 15');
      expect(c2cSeatTotal(45, 2, doorExtra: 2.4), 92.4);
      expect(c2cNamesProblem(1, const []), isNull);
      expect(c2cNamesProblem(2, const [(name: 'Aina', familyMemberId: null)]), 'Name each passenger, one a seat.');
      expect(c2cNamesProblem(2, const [(name: 'Aina', familyMemberId: null), (name: 'Wei', familyMemberId: 'f1')]), isNull);
      expect(c2cPassengersJson(const [(name: ' Aina ', familyMemberId: null), (name: 'Wei', familyMemberId: 'f1')]), [
        {'name': 'Aina'},
        {'name': 'Wei', 'familyMemberId': 'f1'},
      ]);
      expect(c2cMinutesText(90), '1 h 30 min');
    });
  });

  group('trips and bookings', () {
    test('a trip as riders and its driver see it', () {
      final t = C2cTrip.fromJson(_trip(bookings: [_seat(), _seat(id: 'sb2', status: 'requested', seats: 2)]));
      expect(t.route, 'Kuala Lumpur to Ipoh');
      expect(c2cTripDriverLine(t), 'Hafiz R. 4.9 · Honda City · 2 seats left');
      expect([for (final g in c2cTripTags(t)) g.$1], ['Instant', 'Door pickup', 'Every Saturday', 'Takes parcels']);
      expect((t.requests.length, t.riding.length, t.seatsBooked), (1, 1, 1));
      final b = t.requests.single;
      expect(b.who, 'Aina C. 4.8 · 2 seats');
      expect(b.pickupLine, '8:15 Bus stop, Jalan Pahang');
      expect(b.payLine, 'RM 90, cash');
      expect(b.names, ['Aina', 'Wei']);
      expect(t.meetingPoints[1].at(t.leaveAt), DateTime(2026, 10, 31, 8, 15));
    });

    test("a seat booking in the rider's trips", () {
      final b = C2cBooking.fromRow(_bookingRow());
      expect((b.perSeat, b.quote), (true, null));
      expect(b.passengerNames, ['Aina', 'Wei']);
      expect(c2cBookingKind(b), '2 seats');
      expect(c2cBookingKind(C2cBooking.fromRow({..._bookingRow(), 'item': 'parcel', 'passengers': 1})), 'parcel');
      expect(c2cDriverTrips([b], _now).later, isEmpty, reason: 'seats are listed with the posted trip');
      final d = C2cBooking.fromRow(_bookingRow(status: 'declined', payStatus: 'refunded'));
      expect((d.status, d.status.ended), (C2cStatus.declined, true));
      expect(c2cSeatEndLine(d), 'The driver declined this request. The fare held came back to you.');
      expect(C2cStatus.of('requested').label, 'Waiting for the driver');
    });

    test('pushes, the inbox, the admin page and the grant', () {
      expect(pushRouteFor({'type': 'c2c_seat', 'role': 'partner', 'c2c_booking_id': 'b'}), '/drive/city-to-city?tab=post');
      expect(pushRouteFor({'type': 'c2c_seat', 'role': 'rider', 'c2c_booking_id': 'b'}), '/city-to-city');
      expect(inboxIconFor('c2c_seat'), InboxIcon.ride);
      final e = allAdminEntries.firstWhere((e) => e.path == cityToCitySeatsPath);
      expect(e.pages, [c2cSeatsPage]);
      expect(grantablePages[c2cSeatsPage], 'Settings · City to City per-seat trips');
    });
  });

  for (final b in Brightness.values) {
    testWidgets('admin: per-seat rules (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityToCitySeatsScreen(), b: b);
      expect(find.text('Per-seat trips'), findsWidgets);
      expect(find.byKey(const ValueKey('c2c-seat-rule-s0')), findsOneWidget);
      expect(find.text('driver picks, range, door pickup'), findsWidgets);
      expect(find.byKey(const ValueKey('c2c-seat-price-example')), findsOneWidget);
      expect(find.text('Kuala Lumpur to Ipoh, whole car RM 140: seat 25% to 40% = RM 35 to RM 56.'), findsOneWidget);
      // The route's own seat price.
      expect(find.text('Fixed RM 45 a seat'), findsOneWidget);

      // The Kuala Lumpur rule sets nothing: every part as the rule above.
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-rule-s1')));
      expect(find.text('As the rule above'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-own-join')));
      await _tap(tester, find.text('Driver approves'));
      expect(find.textContaining('lapses after 2 hours'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-save')));
      expect(repo.savedRules.single.values['join_mode'], 'approve');
      expect(repo.savedRules.single.values['price_mode'], isNull, reason: 'the price stays the rule above\'s');
    });

    testWidgets('driver: post a trip (${b.name})', (tester) async {
      _places = [_kl, _ip];
      final repo = await _pump(tester, const C2cPostTripScreen(), b: b);
      expect(find.text('Post a trip'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('c2c-post-from')));
      await _tap(tester, find.byKey(const ValueKey('c2c-post-to')));
      await _date(tester, const ValueKey('c2c-post-date'), 31, 10, 2026);
      expect(find.text('Sat 31 Oct, 8:00'), findsOneWidget);
      expect(find.text('Door pickup within 5 km (+ RM 1 a km)'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-post-women')), findsNothing, reason: 'not a verified woman');
      expect(find.text("Allowed RM 35 to 56 a seat (admin's range)"), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-post-price-down')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-post-earn'))).data, '3 x RM 41 = RM 123');
      await _tap(tester, find.byKey(const ValueKey('c2c-post-price-up')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-post-earn'))).data, '3 x RM 46 = RM 138');
      expect(find.text('You keep RM 121.44 after the 12% City to City commission.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-post-door')));
      await _tap(tester, find.text('I approve riders'));
      await _tap(tester, find.byKey(const ValueKey('c2c-post-submit')));
      await closeNotice(tester);
      expect(repo.posts.single, {
        'from': 'Kuala Lumpur', 'to': 'Ipoh', 'leave': DateTime(2026, 10, 31, 8), 'seats': 3, 'price': 46.0,
        'join': C2cJoinMode.approve, 'door': true, 'points': 1,
      });
    });

    testWidgets('driver: posted trip, a request and the start (${b.name})', (tester) async {
      final repo = _Repo()
        ..posted = [
          _trip(instant: false, bookings: [_seat(), _seat(id: 'sb2', status: 'requested', seats: 2, expires: _iso(DateTime(2026, 10, 28, 12)))]),
        ];
      await _pump(tester, const CityToCityDriverScreen(initialTab: C2cDriverTab.post), b: b, repo: repo);
      expect(find.text('Post a trip and sell seats'), findsOneWidget);
      expect(find.text('1 request'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('c2c-posted-t1')));
      expect(find.text('1 of 3 seats booked · RM 45 a seat · you approve'), findsOneWidget);
      // The request moves with the locked offer motion.
      expect(find.ancestor(of: find.byKey(const ValueKey('c2c-seat-request-sb2')), matching: find.byType(OfferMotion)),
          findsOneWidget);
      expect(find.textContaining('answer within 2 h'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-approve-sb2')));
      expect(repo.decided, [('sb2', true)]);
      expect(find.byKey(const ValueKey('c2c-seat-passenger-sb2')), findsOneWidget);
      expect(find.text('Aina, Wei'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-trip-step')));
      expect(repo.progress, [('t1', C2cTripStatus.onTrip)]);
      expect(find.text('Finish trip'), findsOneWidget);
    });

    testWidgets('rider: find a trip and book two seats (${b.name})', (tester) async {
      _places = [_kl, _ip];
      final repo = await _pump(tester, const CityToCityScreen(), b: b);
      await _tap(tester, find.byKey(const ValueKey('c2c-seats')));
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-from')));
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-to')));
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-search')));
      expect(find.text('Hafiz R. 4.9 · Honda City · 2 seats left'), findsOneWidget);
      expect(find.text('Instant'), findsOneWidget);
      expect(find.text('Door pickup'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-trip-t1')));
      expect(find.text('1 suitcase each · Instant: booked when you tap · '), findsNothing);
      expect(find.textContaining('Instant: booked when you tap'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-up')));
      expect(find.text('Name each passenger, one a seat.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('c2c-seat-name-0')), 'Aina');
      await tester.enterText(find.byKey(const ValueKey('c2c-seat-name-1')), 'Wei');
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-point-1')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-seat-total'))).data, 'RM 90');
      expect(find.text('Book 2 seats · RM 90'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-book')));
      await closeNotice(tester);
      expect(repo.booked.single, {
        'trip': 't1', 'seats': 2, 'pickup': {'kind': 'meeting', 'index': 1}, 'payment': C2cPayment.inApp,
        'names': ['Aina', 'Wei'], 'way': C2cPayWay.wallet, 'expected': 90.0,
      });
      // The trip page: booked, the driver and who else rides.
      expect(find.text('Booking CC-20510 · 2 seats · RM 90'), findsOneWidget);
      expect(find.text('Meeting point'), findsOneWidget);
      expect(find.text('Kumar 4.7 (Cheras)'), findsOneWidget);
      expect(find.text('Riding: Aina, Wei'), findsOneWidget);
    });

    testWidgets('rider: a request waiting, then declined (${b.name})', (tester) async {
      final repo = _Repo()..row = _bookingRow(status: 'requested', payStatus: 'held');
      await _pump(tester, const C2cTripScreen(bookingId: 'sb1'), b: b, repo: repo);
      expect(find.text('Seat request'), findsOneWidget);
      expect(find.text('Waiting for the driver'), findsOneWidget);
      expect(find.textContaining('the fare held comes back'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-request-cancel')));
      await _tap(tester, find.byKey(const ValueKey('c2c-seat-request-cancel-confirm')));
      expect(repo.cancelled, ['sb1']);
      await closeAnyNotice(tester);

      repo.row = _bookingRow(status: 'declined', payStatus: 'refunded');
      // A fresh provider scope, so the booking is read again.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const C2cTripScreen(bookingId: 'sb1'), b: b, repo: repo);
      expect(find.text('The driver declined this request. The fare held came back to you.'), findsOneWidget);
      expect(find.text('Find another trip'), findsOneWidget);
    });
  }
}
