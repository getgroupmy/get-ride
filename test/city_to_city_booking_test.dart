// City to City bookings (migration 0307), the pure half: the cancel fee
// (as c2c_cancel_fee), the fare and leave checks (as the insert trigger),
// the fare steps and bar, the rows read and sent, and the words the rider
// app shows. The server's cases are in
// supabase/tests/city_to_city_bookings_0307.sql.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/home_sections.dart';

/// The quote for Kuala Lumpur to Ipoh: fare card RM 116.25 + RM 20, range RM 130 to 150.
const _card = C2cQuote(
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

const _fixed = C2cQuote(
  ruleId: 'r2',
  fareMode: C2cFareMode.fixed,
  fareCard: null,
  addOn: 0,
  suggested: 190,
  low: 175,
  high: 205,
  rangeMode: C2cRangeMode.auto,
  rangePercent: 8,
  bookAheadDays: 30,
  minYears: 3,
  currency: 'MYR',
);

void main() {
  group('the cancel fee (as c2c_cancel_fee)', () {
    final leave = DateTime(2026, 10, 30, 9);
    const s = C2cSettings();

    test('free until 24 hours before, then RM 20', () {
      expect(c2cCancelFee(s, leave, DateTime(2026, 10, 29, 8, 59)), 0);
      expect(c2cCancelFee(s, leave, DateTime(2026, 10, 29, 9)), 20, reason: 'from the hour itself');
      expect(c2cCancelFee(s, leave, DateTime(2026, 10, 30, 8)), 20);
      expect(c2cFreeCancelUntil(s, leave), DateTime(2026, 10, 29, 9));
    });

    test('off, or no driver yet: free', () {
      expect(c2cCancelFee(s.copyWith(cancelFeeOn: false), leave, DateTime(2026, 10, 30, 8)), 0);
      expect(c2cCancelFee(s, leave, DateTime(2026, 10, 30, 8), booked: false), 0);
    });

    test('its own amount and window', () {
      final own = s.copyWith(cancelFeeAmount: 35.5, cancelFreeHours: 6);
      expect(c2cCancelFee(own, leave, DateTime(2026, 10, 30, 2, 59)), 0);
      expect(c2cCancelFee(own, leave, DateTime(2026, 10, 30, 3)), 35.5);
    });

    test('the words on the booking', () {
      expect(c2cCancelText(s, leave),
          'Free to cancel until 24 hours before (Thu 29 Oct, 9:00), then RM 20. The fee goes to the driver.');
      expect(c2cCancelText(s.copyWith(cancelFeeOn: false), leave), 'Free to cancel any time.');
      expect(c2cCancelText(s.copyWith(cancelFreeHours: 1), leave), contains('until 1 hour before'));
    });
  });

  group('the fare (as the insert trigger)', () {
    test('within the range', () {
      expect(c2cFareProblem(140, _card), isNull);
      expect(c2cFareProblem(130, _card), isNull);
      expect(c2cFareProblem(150, _card), isNull);
      expect(c2cFareProblem(129, _card), 'Your fare must be between RM 130 and RM 150.');
      expect(c2cFareProblem(150.5, _card), isNotNull);
    });

    test('a fixed fare: only it', () {
      expect(c2cFareProblem(190, _fixed), isNull);
      expect(c2cFareProblem(185, _fixed), 'This route has a fixed fare of RM 190.');
    });

    test('where the Price step starts: the suggestion to the nearest RM 5, in range', () {
      expect(c2cStartFare(_card), 135, reason: '136.25 rounds to 135');
      expect(c2cStartFare(_fixed), 190);
      const low = C2cQuote(ruleId: null, fareMode: C2cFareMode.card, fareCard: 100, addOn: 0, suggested: 101,
          low: 104, high: 120, rangeMode: C2cRangeMode.set, rangePercent: 8, bookAheadDays: 14, minYears: null,
          currency: 'MYR');
      expect(c2cStartFare(low), 104, reason: 'kept within the range');
    });

    test('RM 5 a step, to whole steps, never out of range', () {
      expect(c2cStepFare(135, 1, _card), 140);
      expect(c2cStepFare(136.25, 1, _card), 140, reason: 'up to the next whole step');
      expect(c2cStepFare(136.25, -1, _card), 135);
      expect(c2cStepFare(150, 1, _card), 150);
      expect(c2cStepFare(130, -1, _card), 130);
      expect(c2cStepFare(190, 1, _fixed), 190, reason: 'a fixed fare doesn\'t move');
    });

    test('the bar: the range inside it, the fare on it', () {
      final bar = c2cFareBar(140, _card);
      expect(bar.start, greaterThan(0));
      expect(bar.end, lessThan(1));
      expect(bar.at, closeTo((bar.start + bar.end) / 2, 1e-9), reason: '140 is the middle of 130 to 150');
      expect(c2cFareBar(130, _card).at, closeTo(bar.start, 1e-9));
    });

    test('the lines', () {
      expect(c2cQuoteLine(_card), 'Fare card RM 116.25 + City to City RM 20 = RM 136.25 suggested');
      expect(c2cQuoteLine(_fixed), 'Fixed fare RM 190 on this route');
      expect(c2cRangeLine(_card, 'Kuala Lumpur to Ipoh'), 'Most drivers accept RM 130 to RM 150 for Kuala Lumpur to Ipoh.');
      expect(c2cRangeLine(_fixed, 'Kuala Lumpur to George Town'), 'Drivers take RM 190 for Kuala Lumpur to George Town.');
      expect(c2cOfferDiff(140, 140), 'Your fare');
      expect(c2cOfferDiff(145, 140), '+ RM 5');
      expect(c2cOfferDiff(137.5, 140), '- RM 2.50');
    });
  });

  group('when (as the insert trigger)', () {
    final now = DateTime(2026, 10, 28, 12);
    test('at least 1 hour from now, within the book-ahead days', () {
      expect(c2cLeaveProblem(now.add(const Duration(minutes: 59)), now, 14), 'Leave at least 1 hour from now.');
      expect(c2cLeaveProblem(now.add(const Duration(hours: 1)), now, 14), isNull);
      expect(c2cLeaveProblem(now.add(const Duration(days: 14)), now, 14), isNull);
      expect(c2cLeaveProblem(now.add(const Duration(days: 14, minutes: 1)), now, 14),
          'Book up to 14 days ahead on this route.');
      expect(c2cLeaveProblem(now.add(const Duration(days: 2)), now, 1), 'Book up to 1 day ahead on this route.');
    });

    test('the words', () {
      final t = DateTime(2026, 10, 30, 9);
      expect(c2cLeaveText(t), 'Leave Fri 30 Oct at 9:00');
      expect(c2cFlexText(t, true), 'Flexible, 8:30 to 9:30');
      expect(c2cFlexText(t, false), 'Exact time');
      expect(c2cArriveText(t, 150), 'Arrive about 11:30');
      expect(c2cTripSize(205.4, 160), '205 km, about 2 h 40 min.');
      expect(c2cTripSize(80, 60), '80 km, about 1 h.');
      expect(c2cTimeLeft(const Duration(days: 2, hours: 14, minutes: 5)), '2 d 14 h');
      expect(c2cTimeLeft(const Duration(hours: 3, minutes: 20)), '3 h 20 min');
      expect(c2cTimeLeft(const Duration(minutes: 14)), '14 min');
      expect(c2cOffersLine(0, null, now), 'No offers yet. Drivers who can take the trip see it now.');
      expect(c2cOffersLine(2, now.add(const Duration(hours: 5)), now), '2 offers. Request open for 5 h 0 min more.');
      expect(c2cOffersLine(1, now.subtract(const Duration(minutes: 1)), now), '1 offer.');
    });
  });

  test('payments as the settings allow, In app first', () {
    expect(c2cPayments(const C2cSettings()), [C2cPayment.inApp, C2cPayment.cash]);
    expect(c2cPayments(const C2cSettings(payInApp: false)), [C2cPayment.cash]);
  });

  test('statuses', () {
    expect(C2cStatus.of('driver_arriving'), C2cStatus.driverArriving);
    expect(C2cStatus.of('nonsense'), C2cStatus.open);
    expect([for (final s in C2cStatus.values) if (s.waiting) s.key], ['open', 'offered']);
    expect([for (final s in C2cStatus.values) if (s.withDriver) s.key], ['booked', 'driver_arriving', 'on_trip']);
    expect([for (final s in C2cStatus.values) if (s.ended) s.key], ['completed', 'cancelled', 'expired', 'declined']);
  });

  test('a booking and an offer read from their rows', () {
    final b = C2cBooking.fromRow({
      'id': 'b1',
      'ref': 'CC-20481',
      'pickup_name': '12 Jalan Contoh',
      'pickup_place': {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'},
      'drop_name': '21 Jalan Sampel',
      'drop_place': {'country': 'Malaysia', 'state': 'Perak', 'city': 'Ipoh'},
      'distance_km': '205.00',
      'duration_min': 160,
      'leave_at': '2026-10-30T01:00:00Z',
      'flexible': true,
      'passengers': 2,
      'luggage': 'suitcases',
      'fare': 140,
      'currency': 'MYR',
      'quote': {'fareMode': 'card', 'suggested': 136.25, 'low': 130, 'high': 150, 'fareCard': 116.25, 'addOn': 20},
      'payment': 'in_app',
      'status': 'booked',
      'agreed_fare': 145,
      'driver_id': 'd1',
      'driver_leave_at': '2026-10-30T01:15:00Z',
    });
    expect(b.route, 'Kuala Lumpur to Ipoh');
    expect(b.pickupLine, '12 Jalan Contoh, Kuala Lumpur');
    expect(b.price, 145, reason: 'the agreed fare once booked');
    expect(b.leaves, b.driverLeaveAt);
    expect(b.quote!.low, 130);
    expect(b.payment, C2cPayment.inApp);
    expect(b.luggage, C2cLuggage.suitcases);
    expect(c2cTripLine(b.passengers, b.luggage), 'Whole car · 2 passengers · 1 to 2 suitcases');

    final o = C2cOffer.fromRow({
      'id': 'o1', 'booking_id': 'b1', 'driver_id': 'd1', 'price': 145, 'leave_at': '2026-10-30T01:15:00Z',
      'driver_name': 'Aiman Contoh', 'driver_rating': 4.9, 'driver_trips': 312, 'car': 'Proton X50', 'plate': 'VKA 2231',
    });
    expect(o.initials, 'AC');
    expect(o.ratingLine, '4.9 (312 trips)');
    expect(o.carLine, 'Proton X50, VKA 2231');
    expect(o.open, isTrue);
    expect(C2cOffer.fromRow({'id': 'x', 'booking_id': 'b', 'driver_id': 'd', 'price': 1, 'leave_at': ''}).ratingLine,
        'New driver');
  });

  test('the row the app sends', () {
    final row = c2cBookingRow(
      pickup: const C2cEnd(name: '12 Jalan Contoh', lat: 3.15, lng: 101.7,
          place: Geo(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur')),
      drop: const C2cEnd(name: '21 Jalan Sampel', address: '21 Jalan Sampel, Ipoh', lat: 4.6, lng: 101.08,
          place: Geo(country: 'Malaysia', state: 'Perak', city: 'Ipoh')),
      distanceKm: 205.123,
      durationMin: 160.04,
      leaveAt: DateTime.utc(2026, 10, 30, 1),
      flexible: true,
      passengers: 9,
      luggage: C2cLuggage.many,
      fare: 140,
      payment: C2cPayment.cash,
    );
    expect(row['pickup_place'], {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'});
    expect(row.containsKey('pickup_address'), isFalse);
    expect(row['drop_address'], '21 Jalan Sampel, Ipoh');
    expect(row['distance_km'], 205.12);
    expect(row['duration_min'], 160.0);
    expect(row['leave_at'], '2026-10-30T01:00:00.000Z');
    expect(row['passengers'], 6, reason: 'at most 6');
    expect(row['luggage'], 'many');
    expect(row['payment'], 'cash');
    expect(row.containsKey('status'), isFalse, reason: 'the server sets the status');
  });

  group('the home box', () {
    test('a box named City to City opens the page once the service is on', () {
      List<ServiceBoxView> boxes({required bool on}) => serviceBoxViews(
        const {},
        boxes: [
          {'name': 'City to City'},
          {'name': 'Something else'},
        ],
        cityToCityAvailable: on,
      );
      expect(boxes(on: true).first.route, c2cPageRoute);
      expect(boxes(on: true).first.cityToCity, isTrue);
      expect(boxes(on: false).first.route, isNull, reason: 'coming soon while the service is off');
      expect(boxes(on: true)[1].cityToCity, isFalse);
    });

    test('what the admin reads', () {
      expect(serviceBoxIsCityToCity(title: 'City to\nCity'), isTrue);
      expect(serviceBoxIsCityToCity(title: 'Box', route: c2cPageRoute), isTrue);
      expect(serviceBoxIsCityToCity(title: 'Box', linked: 'City to City'), isTrue);
      expect(serviceBoxOpensText(title: 'City to City'), startsWith('City to City page'));
    });
  });
}
