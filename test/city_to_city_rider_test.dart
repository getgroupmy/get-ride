// City to City, the rider's app (migration 0307), in light and dark on a
// phone: the page, the five trip steps (not available at a pickup, the
// date boxes and time, passengers and luggage, the fare within the range,
// In app or Cash) and the request sent; the offers with the locked motion,
// Decline and Accept; the booked trip with Call and the cancel fee; after
// the trip, the rating; a cancelled trip; and the admin's Driving since.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/people/partner_screens.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/data/city_to_city_repository.dart';
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/features/ride/city_to_city_screen.dart';
import 'package:get_ride/src/features/ride/city_to_city_steps.dart';
import 'package:get_ride/src/features/ride/city_to_city_trip.dart';
import 'package:get_ride/src/features/ride/freight_screen.dart' show freightPlaceSearchProvider, freightRouteProvider;
import 'package:get_ride/src/widgets/offer_motion.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// Wednesday 28 October 2026, 10:00.
final _now = DateTime(2026, 10, 28, 10);

const _kl = Geo(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur');
const _ipoh = Geo(country: 'Malaysia', state: 'Perak', city: 'Ipoh');
const _kk = Geo(country: 'Malaysia', state: 'Sabah', city: 'Kota Kinabalu');

final _places = {
  'kl': const Place(name: '12 Jalan Contoh', address: '12 Jalan Contoh, Kuala Lumpur', point: LatLng(3.15, 101.7)),
  'ipoh': const Place(name: '21 Jalan Sampel', address: '21 Jalan Sampel, Ipoh', point: LatLng(4.6, 101.08)),
  'kk': const Place(name: '3 Jalan Gaya', address: '3 Jalan Gaya, Kota Kinabalu', point: LatLng(5.98, 116.07)),
};

Geo _areaAt(LatLng p) => p.latitude > 5.5 ? _kk : (p.latitude > 4 ? _ipoh : _kl);

const _quote = C2cQuote(
  ruleId: 'r1',
  fareMode: C2cFareMode.card,
  fareCard: 116.25,
  addOn: 20,
  suggested: 136.25,
  low: 130,
  high: 150,
  rangeMode: C2cRangeMode.set,
  rangePercent: 8,
  bookAheadDays: 14,
  minYears: 3,
  currency: 'MYR',
);

Map<String, dynamic> _bookingRow({
  String id = 'b1',
  String status = 'open',
  DateTime? leaveAt,
  double fare = 140,
  String? driver,
  double? agreed,
  double? cancelFee,
  String? cancelFeeStatus,
  int? stars,
}) => {
  'id': id,
  'ref': 'CC-20481',
  'pickup_name': '12 Jalan Contoh',
  'pickup_place': {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'},
  'drop_name': '21 Jalan Sampel',
  'drop_place': {'country': 'Malaysia', 'state': 'Perak', 'city': 'Ipoh'},
  'distance_km': 205,
  'duration_min': 160,
  'leave_at': (leaveAt ?? DateTime(2026, 10, 30, 9)).toUtc().toIso8601String(),
  'flexible': true,
  'passengers': 2,
  'luggage': 'suitcases',
  'fare': fare,
  'currency': 'MYR',
  'quote': {'fareMode': 'card', 'suggested': 136.25, 'low': 130, 'high': 150, 'fareCard': 116.25, 'addOn': 20,
            'bookAheadDays': 14},
  'payment': 'cash',
  'status': status,
  'expires_at': (leaveAt ?? DateTime(2026, 10, 30, 9)).toUtc().toIso8601String(),
  'driver_id': driver,
  'agreed_fare': agreed,
  'cancel_fee': cancelFee,
  'cancel_fee_status': cancelFeeStatus,
  'rider_stars': stars,
};

Map<String, dynamic> _offerRow(String id, String driver, String name, double price, {String status = 'open'}) => {
  'id': id,
  'booking_id': 'b1',
  'driver_id': driver,
  'price': price,
  'leave_at': DateTime(2026, 10, 30, 9, 15).toUtc().toIso8601String(),
  'driver_name': name,
  'driver_rating': 4.9,
  'driver_trips': 312,
  'car': 'Proton X50',
  'plate': 'VKA 2231',
  'status': status,
};

class _Repo extends CityToCityRepository {
  _Repo() : super(_db);

  C2cSettings stored = const C2cSettings();
  Map<String, dynamic>? row;
  List<Map<String, dynamic>> offerRows = [];
  final booked = <Map<String, dynamic>>[];
  final declined = <String>[];
  final accepted = <String>[];
  final cancelled = <String>[];
  final fares = <double>[];
  final rated = <(int, String?)>[];
  final asked = <Geo>[];

  @override
  Future<C2cSettings> settings() async => stored;
  @override
  Future<bool> availableAt(Geo place) async {
    asked.add(place);
    return place.state != 'Sabah';
  }

  @override
  Future<C2cQuote> quote({
    required double lat,
    required double lng,
    required Geo pickup,
    required Geo drop,
    required double km,
    required double min,
  }) async => _quote;

  @override
  Future<C2cBooking> book(Map<String, dynamic> r) async {
    booked.add(r);
    row = _bookingRow(fare: (r['fare'] as num).toDouble());
    offerRows = [_offerRow('o1', 'd1', 'Aiman Contoh', 140), _offerRow('o2', 'd2', 'Mei Ling Sample', 145)];
    return C2cBooking.fromRow(row!);
  }

  @override
  Future<List<C2cBooking>> myTrips() async => [if (row != null) C2cBooking.fromRow(row!)];
  @override
  Future<C2cBooking?> booking(String id) async => row == null ? null : C2cBooking.fromRow(row!);
  @override
  Future<List<C2cOffer>> offers(String bookingId) async => [for (final r in offerRows) C2cOffer.fromRow(r)];

  @override
  Future<void> declineOffer(String offerId) async {
    declined.add(offerId);
    offerRows = [for (final r in offerRows) r['id'] == offerId ? {...r, 'status': 'declined'} : r];
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    accepted.add(offerId);
    final o = offerRows.firstWhere((r) => r['id'] == offerId);
    offerRows = [for (final r in offerRows) r['id'] == offerId ? {...r, 'status': 'accepted'} : {...r, 'status': 'declined'}];
    row = {...row!, 'status': 'booked', 'driver_id': o['driver_id'], 'agreed_fare': o['price'], 'driver_leave_at': o['leave_at']};
  }

  @override
  Future<void> setFare(String bookingId, double fare) async {
    fares.add(fare);
    row = {...row!, 'fare': fare};
  }

  @override
  Future<({double fee, String feeStatus})> cancel(String bookingId, {String? reason}) async {
    cancelled.add(bookingId);
    final leave = DateTime.parse(row!['leave_at'] as String).toLocal();
    final fee = c2cCancelFee(stored, leave, _now, booked: row!['driver_id'] != null);
    final status = fee > 0 ? 'charged' : 'none';
    row = {...row!, 'status': 'cancelled', 'cancel_fee': fee, 'cancel_fee_status': status, 'cancelled_by': 'rider'};
    return (fee: fee, feeStatus: status);
  }

  @override
  Future<({String name, String? phone})?> contact(String bookingId) async => (name: 'Aiman Contoh', phone: '+60100000001');

  @override
  Future<void> rateDriver(String bookingId, int stars, {String? comment}) async {
    rated.add((stars, comment));
    row = {...row!, 'rider_stars': stars};
  }
}

Future<_Repo> _pump(WidgetTester tester, Widget home, {Brightness b = Brightness.light, _Repo? repo, List<Uri>? dialed}) async {
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
        c2cClockProvider.overrideWithValue(() => _now),
        c2cAreaProvider.overrideWithValue((p) async => _areaAt(p)),
        freightRouteProvider.overrideWithValue((a, b) async => (km: 205.0, min: 160.0)),
        freightPlaceSearchProvider.overrideWithValue((context, {required title, near, onMap = false}) async =>
            _next.removeAt(0)),
        c2cLauncherProvider.overrideWithValue((u) async {
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

/// The places the search gives, in turn.
final _next = <Place>[];

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  return switch (w) {
    ButtonStyleButton() => w.onPressed != null,
    _ => (w as dynamic).onPressed != null,
  };
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('plan a trip in five steps, then the offers, decline, accept, booked (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityToCityScreen(), b: b);
      expect(find.text('Going further? Book a whole car to another city, door to door.'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-no-trips')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-plan')));

      // Step 1: a pickup in Sabah is not available; Next waits.
      expect(find.text('Where are you going?'), findsOneWidget);
      expect(find.text('Step 1 of 5'), findsOneWidget);
      _next.addAll([_places['kk']!, _places['ipoh']!]);
      await _tap(tester, find.byKey(const ValueKey('c2c-pickup-search')));
      await _tap(tester, find.byKey(const ValueKey('c2c-drop-search')));
      expect(find.text("City to City isn't available from Kota Kinabalu yet."), findsOneWidget);
      expect(find.text('Choose another pickup'), findsOneWidget);
      expect(_enabled(tester, const ValueKey('c2c-next')), isFalse);
      _next.add(_places['kl']!);
      await _tap(tester, find.text('Choose another pickup'));
      expect(find.byKey(const ValueKey('c2c-not-available')), findsNothing);
      expect(repo.asked.last.city, 'Kuala Lumpur');
      expect(_enabled(tester, const ValueKey('c2c-next')), isTrue);
      await _tap(tester, find.byKey(const ValueKey('c2c-next')));

      // Step 2: date boxes and a time; within the route's 14 days.
      expect(find.text('When do you leave?'), findsOneWidget);
      expect(find.text('Book up to 14 days ahead on this route.'), findsOneWidget);
      expect(_enabled(tester, const ValueKey('c2c-next')), isFalse, reason: 'no date yet');
      final date = find.byKey(const ValueKey('c2c-date'));
      await tester.enterText(find.descendant(of: date, matching: find.byKey(const ValueKey('date-box-day'))), '30');
      await tester.enterText(find.descendant(of: date, matching: find.byKey(const ValueKey('date-box-month'))), '10');
      await tester.enterText(find.descendant(of: date, matching: find.byKey(const ValueKey('date-box-year'))), '2026');
      await tester.pumpAndSettle();
      expect(find.text('Leave Fri 30 Oct at 9:00'), findsOneWidget);
      expect(find.text('Flexible, 8:30 to 9:30'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-next')));

      // Step 3: whole car; sharing comes later; passengers and luggage.
      expect(find.text('Which car?'), findsOneWidget);
      expect(find.text('Coming later'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-pax-up')));
      await _tap(tester, find.byKey(const ValueKey('c2c-luggage-suitcases')));
      await _tap(tester, find.byKey(const ValueKey('c2c-next')));

      // Step 4: the breakdown, the range, the fare within it.
      expect(find.text('Fare card RM 116.25 + City to City RM 20 = RM 136.25 suggested'), findsOneWidget);
      expect(find.text('Most drivers accept RM 130 to RM 150 for Kuala Lumpur to Ipoh.'), findsOneWidget);
      expect(find.text('205 km, about 2 h 40 min.'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-fare'))).data, 'RM 135');
      await _tap(tester, find.byKey(const ValueKey('c2c-fare-down')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-fare'))).data, 'RM 130');
      expect(find.byKey(const ValueKey('c2c-fare-low')), findsOneWidget, reason: 'the bottom of the range');
      expect(_enabled(tester, const ValueKey('c2c-fare-down')), isFalse, reason: 'never below the range');
      await _tap(tester, find.byKey(const ValueKey('c2c-fare-up')));
      await _tap(tester, find.byKey(const ValueKey('c2c-fare-up')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-fare'))).data, 'RM 140');
      await _tap(tester, find.byKey(const ValueKey('c2c-next')));

      // Step 5: the summary, In app or Cash, the cancel rule.
      expect(find.text('Check your trip'), findsOneWidget);
      expect(find.text('Leave Fri 30 Oct at 9:00 (± 30 min)'), findsOneWidget);
      expect(find.text('Whole car, 2 passengers'), findsOneWidget);
      expect(find.text('1 to 2 suitcases'), findsOneWidget);
      expect(find.text('Free to cancel until 24 hours before, then RM 20.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-cash')));
      await _tap(tester, find.byKey(const ValueKey('c2c-find-driver')));
      expect(repo.booked, hasLength(1));
      final sent = repo.booked.single;
      expect([sent['fare'], sent['passengers'], sent['luggage'], sent['payment'], sent['flexible']],
          [140.0, 2, 'suitcases', 'cash', true]);
      expect(sent['pickup_place'], {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'});
      expect(DateTime.parse(sent['leave_at'] as String).toLocal(), DateTime(2026, 10, 30, 9));

      // The offers, with the locked motion.
      expect(find.text('Offers from drivers'), findsOneWidget);
      expect(find.byType(OfferMotionList), findsOneWidget);
      expect(find.text('Aiman Contoh'), findsOneWidget);
      expect(find.text('Mei Ling Sample'), findsOneWidget);
      expect(find.text('+ RM 5'), findsOneWidget);
      expect(find.text('Can leave 9:15'), findsNWidgets(2));
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-offers-line'))).data,
          '2 offers. Request open for 1 d 23 h more.');
      await _tap(tester, find.byKey(const ValueKey('c2c-decline-o2')));
      expect(repo.declined, ['o2']);
      expect(find.text('Mei Ling Sample'), findsNothing, reason: 'slid out to the left');
      await _tap(tester, find.byKey(const ValueKey('c2c-accept-o1')));
      expect(repo.accepted, ['o1']);

      // Booked.
      expect(find.text('Your trip'), findsOneWidget);
      expect(find.text('Booked'), findsOneWidget);
      expect(find.text('Booking CC-20481 · whole car · RM 140'), findsOneWidget);
      expect(find.text('Aiman Contoh'), findsOneWidget);
      expect(find.text('Proton X50, VKA 2231'), findsOneWidget);
      expect(find.text('Arrive about 11:55'), findsOneWidget, reason: 'leaving 9:15 with the driver, 160 minutes');
      expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-cancel-text'))).data,
          'Free to cancel until 24 hours before (Thu 29 Oct, 9:00), then RM 20. The fee goes to the driver.');
    });
  }

  testWidgets('booked: Call, and the cancel fee inside 24 hours', (tester) async {
    final repo = _Repo()
      ..row = _bookingRow(status: 'booked', leaveAt: _now.add(const Duration(hours: 5)), driver: 'd1', agreed: 140)
      ..offerRows = [_offerRow('o1', 'd1', 'Aiman Contoh', 140, status: 'accepted')];
    final dialed = <Uri>[];
    await _pump(tester, const C2cTripScreen(bookingId: 'b1'), repo: repo, dialed: dialed);
    await _tap(tester, find.byKey(const ValueKey('c2c-call')));
    expect(dialed, [Uri(scheme: 'tel', path: '+60100000001')]);
    await _tap(tester, find.byKey(const ValueKey('c2c-cancel-booking')));
    expect(find.text('Cancel and pay RM 20'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('c2c-cancel-confirm')));
    expect(repo.cancelled, ['b1']);
    await pumpNotice(tester);
    expect(find.text('Booking cancelled. RM 20 was taken from your GET wallet.'), findsOneWidget);
    await closeNotice(tester);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('A cancel fee of RM 20 was paid from your GET wallet.'), findsOneWidget);
  });

  testWidgets('an open request: change the fare within the range, cancel free', (tester) async {
    final repo = _Repo()
      ..row = _bookingRow()
      ..offerRows = [];
    await _pump(tester, const C2cTripScreen(bookingId: 'b1'), repo: repo, b: Brightness.dark);
    expect(find.textContaining('No offers yet.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('c2c-change-fare')));
    await _tap(tester, find.byKey(const ValueKey('c2c-new-fare-up')));
    await _tap(tester, find.byKey(const ValueKey('c2c-new-fare-up')));
    expect(tester.widget<Text>(find.byKey(const ValueKey('c2c-new-fare'))).data, 'RM 150');
    expect(_enabled(tester, const ValueKey('c2c-new-fare-up')), isFalse, reason: 'the top of the range');
    await _tap(tester, find.byKey(const ValueKey('c2c-new-fare-save')));
    expect(repo.fares, [150.0]);
    await _tap(tester, find.byKey(const ValueKey('c2c-cancel-request')));
    expect(find.text('No driver is booked yet, so it is free. Drivers stop seeing it.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('c2c-cancel-confirm')));
    expect(repo.cancelled, ['b1']);
    expect(find.text('Cancelled. No fee.'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('after the trip: the rating (${b.name})', (tester) async {
      final repo = _Repo()
        ..row = _bookingRow(status: 'completed', driver: 'd1', agreed: 145)
        ..offerRows = [_offerRow('o1', 'd1', 'Aiman Contoh', 145, status: 'accepted')];
      await _pump(tester, const C2cTripScreen(bookingId: 'b1'), repo: repo, b: b);
      expect(find.text('Trip done'), findsOneWidget);
      expect(find.text('Booking CC-20481 · RM 145 in cash'), findsOneWidget);
      expect(find.text('How was Aiman Contoh?'), findsOneWidget);
      expect(_enabled(tester, const ValueKey('c2c-rate-send')), isFalse);
      await _tap(tester, find.byKey(const ValueKey('c2c-star-4')));
      await tester.enterText(find.byKey(const ValueKey('c2c-rate-comment')), 'Smooth trip');
      await _tap(tester, find.byKey(const ValueKey('c2c-rate-send')));
      expect(repo.rated, [(4, 'Smooth trip')]);
      await closeNotice(tester);
      expect(find.text('You rated this trip'), findsOneWidget);
    });
  }

  testWidgets('the page lists the trips and opens one', (tester) async {
    final repo = _Repo()
      ..row = _bookingRow(status: 'booked', driver: 'd1', agreed: 145)
      ..offerRows = [_offerRow('o1', 'd1', 'Aiman Contoh', 145, status: 'accepted')];
    await _pump(tester, const CityToCityScreen(), repo: repo, b: Brightness.dark);
    expect(find.text('Kuala Lumpur to Ipoh'), findsOneWidget);
    expect(find.text('Fri 30 Oct, 9:00 · Booked'), findsOneWidget);
    expect(find.text('RM 145'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('c2c-trip-b1')));
    expect(find.text('Booked'), findsOneWidget);
  });

  group("the admin's Driving since (partners.driving_since, 0306)", () {
    test('the value saved, or why not', () {
      final today = DateTime(2026, 10, 28);
      expect(partnerDrivingSince('', today), (value: null, error: null));
      expect(partnerDrivingSince('2015-06-01', today), (value: '2015-06-01', error: null));
      expect(partnerDrivingSince('2027-01-01', today).error, 'Check the driving since date.');
      expect(partnerDrivingSince('1929-12-31', today).error, isNotNull);
      expect(partnerDrivingSince('2015-02', today).error, isNotNull, reason: 'not a whole date');
    });

    for (final b in Brightness.values) {
      testWidgets('on Edit Partner, in date boxes (${b.name})', (tester) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          retry: (_, _) => null,
          overrides: [
            ...quietLiveOverrides,
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
            peopleRepositoryProvider.overrideWithValue(_People()),
            partnerFormDataProvider.overrideWith((ref) async => const PartnerFormData(
                typeValues: [], vehicles: [], geo: GeoOptions(), requiredDocs: [])),
          ],
          child: MaterialApp(theme: appTheme(b), home: const PartnerEditScreen(id: 'p1')),
        ));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('partner-driving-since'));
        expect(field, findsOneWidget);
        expect(find.text('Driving since (licence first issued)'), findsOneWidget);
        String box(String part) => tester
            .widget<TextField>(find.descendant(of: field, matching: find.byKey(ValueKey('date-box-$part'))))
            .controller!
            .text;
        expect([box('day'), box('month'), box('year')], ['01', '06', '2015']);
      });
    }
  });
}

class _People extends PeopleRepository {
  _People() : super(_db);

  @override
  Future<Map<String, dynamic>?> partner(String id) async =>
      {'id': 'p1', 'name': 'Driver Satu', 'phone': '+60100000001', 'driving_since': '2015-06-01'};
}
