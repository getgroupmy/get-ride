// City to City for drivers (migration 0308), the pure half: the Requests
// list as the server sends it, what a locked request says, the commission
// and what the driver keeps, the offer's price and times, the steps on the
// day, giving a trip up, My trips; and the City to City threads of the ride
// chat (rows, files, the outbox, the push's route).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/ride_chat_outbox.dart';

const _quote = {'fareMode': 'card', 'suggested': 136.25, 'low': 130, 'high': 150, 'bookAheadDays': 14};

Map<String, dynamic> _row({
  String id = 'b1',
  String status = 'open',
  DateTime? leaveAt,
  Map<String, dynamic> quote = _quote,
  double fare = 140,
  bool flexible = true,
  int passengers = 2,
}) => {
  'id': id,
  'ref': 'CC-20481',
  'pickup_name': '12 Jalan Contoh',
  'pickup_place': {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur', 'suburb': 'Ampang'},
  'drop_name': '21 Jalan Sampel',
  'drop_place': {'country': 'Malaysia', 'state': 'Perak', 'city': 'Ipoh'},
  'distance_km': 205,
  'duration_min': 160,
  'leave_at': (leaveAt ?? DateTime(2026, 10, 30, 9)).toUtc().toIso8601String(),
  'flexible': flexible,
  'passengers': passengers,
  'luggage': 'suitcases',
  'fare': fare,
  'currency': 'MYR',
  'quote': quote,
  'payment': 'cash',
  'status': status,
};

void main() {
  group('the Requests list (c2c_driver_requests)', () {
    final feed = C2cDriverFeed.fromJson({
      'approved': true,
      'hasArea': true,
      'drivingSince': '2016-01-01',
      'years': 10,
      'canSetDrivingSince': false,
      'requests': [
        {
          ..._row(),
          'rider_name': 'Farah T.',
          'rider_rating': 4.8,
          'eligibility': {'ok': true, 'minYears': 3, 'years': 10, 'experienceOk': true, 'needs': []},
          'commission_rate_now': 0.12,
          'my_offer': {'id': 'o1', 'price': 150, 'leave_at': DateTime(2026, 10, 30, 9, 15).toUtc().toIso8601String()},
        },
        {
          ..._row(id: 'b2'),
          'pickup_name': 'Ampang, Kuala Lumpur',
          'pickup_lat': null,
          'rider_name': 'Wei Jie L.',
          'eligibility': {
            'ok': false,
            'minYears': 3,
            'years': 10,
            'experienceOk': true,
            'needs': [
              {'name': 'Singapore permit', 'country': 'Singapore'},
            ],
          },
          'commission_rate_now': null,
          'my_offer': null,
        },
      ],
    });

    test('read as sent', () {
      expect(feed.approved, isTrue);
      expect(feed.years, 10);
      expect(feed.requests, hasLength(2));
      final a = feed.requests.first;
      expect(a.riderName, 'Farah T.');
      expect(a.locked, isFalse);
      expect(a.commissionRate, 0.12);
      expect(a.myOffer!.price, 150);
      expect(a.myOffer!.leaveAt, DateTime(2026, 10, 30, 9, 15));
      expect(a.booking.quote!.low, 130);
      final b = feed.requests.last;
      expect(b.locked, isTrue);
      expect(b.booking.pickupLat, isNull, reason: 'a locked request comes without its points');
      expect(b.myOffer, isNull);
    });

    test('nothing or rubbish reads as empty', () {
      expect(C2cDriverFeed.fromJson(null).requests, isEmpty);
      expect(C2cDriverFeed.fromJson({'requests': 'x'}).approved, isFalse);
    });

    test('why a driver gets no requests', () {
      expect(c2cDriverBlock(const C2cDriverFeed()), 'City to City opens once your partner account is approved.');
      expect(c2cDriverBlock(const C2cDriverFeed(approved: true)), contains('service area'));
      expect(c2cDriverBlock(const C2cDriverFeed(approved: true, hasArea: true)), isNull);
    });
  });

  group('a request the driver may not take', () {
    test('what it needs', () {
      expect(c2cLockLine(const C2cEligibility()), isNull);
      expect(c2cLockLine(const C2cEligibility(ok: false, needs: ['Singapore permit'])), 'Needs: Singapore permit');
      expect(
        c2cLockLine(const C2cEligibility(ok: false, minYears: 5, years: 2, experienceOk: false, needs: ['APAD permit'])),
        'Needs: APAD permit, 5 years of driving',
      );
      expect(c2cLockLine(const C2cEligibility(ok: false, minYears: 1, experienceOk: false)), 'Needs: 1 year of driving');
    });

    test('the years under it', () {
      expect(c2cYearsLine(const C2cEligibility()), isNull);
      expect(c2cYearsLine(const C2cEligibility(ok: false, minYears: 5, years: 2, experienceOk: false)),
          'You have 2 years of driving.');
      expect(c2cYearsLine(const C2cEligibility(ok: false, minYears: 3, experienceOk: false)),
          'Add when your licence was first issued.');
    });
  });

  group('the card', () {
    final b = C2cBooking.fromRow(_row());
    test('when, from and to, the rider', () {
      expect(c2cRequestWhen(b), 'Fri 30 Oct, 9:00 (± 30 min), 2 people');
      expect(c2cRequestWhen(C2cBooking.fromRow(_row(flexible: false, passengers: 1))), 'Fri 30 Oct, 9:00, 1 person');
      expect(c2cAreaLine(b.pickupPlace, b.pickupName), 'Ampang, Kuala Lumpur');
      expect(c2cAreaLine(const Geo(), 'Somewhere'), 'Somewhere');
      expect(c2cRiderLine('Farah T.', 4.8), 'Farah T. 4.8');
      expect(c2cRiderLine('Farah T.', null), 'Farah T., new rider');
      expect(c2cBookedWhen(b), 'Fri 30 Oct, 9:00, whole car, 2 people');
    });

    test('the commission and what the driver keeps', () {
      expect(c2cCommissionHeader([0.12, null, 0.12]), 'Commission 12%');
      expect(c2cCommissionHeader([0.12, 0.1]), 'Commission 10% to 12%');
      expect(c2cCommissionHeader([null]), isNull);
      expect(c2cKeepLine(90, 0.12), 'RM 90, you keep RM 79.20 after 12%');
      expect(c2cKeepLine(140, 0.125), 'RM 140, you keep RM 122.50 after 12.5%');
      expect(c2cKeepLine(90, null), 'RM 90');
    });
  });

  group('the offer', () {
    test('starts RM 10 over the fare, within the range; a fixed fare is the fare', () {
      expect(c2cOfferStart(C2cBooking.fromRow(_row())), 150);
      expect(c2cOfferStart(C2cBooking.fromRow(_row(fare: 145))), 150, reason: 'never above the range');
      expect(c2cOfferStart(C2cBooking.fromRow(_row(quote: {'fareMode': 'fixed', 'suggested': 190}, fare: 190))), 190);
    });

    test('the price as the server checks it', () {
      final b = C2cBooking.fromRow(_row());
      expect(c2cOfferPriceProblem(140, b), isNull);
      expect(c2cOfferPriceProblem(155, b), 'Offer between RM 130 and RM 150.');
      final fixed = C2cBooking.fromRow(_row(quote: {'fareMode': 'fixed', 'suggested': 190}, fare: 190));
      expect(c2cOfferPriceProblem(185, fixed), 'This route has a fixed fare of RM 190.');
      expect(c2cOfferPriceProblem(190, fixed), isNull);
    });

    test('the times: every 15 minutes within 30 when flexible, else the rider\'s', () {
      final at = DateTime(2026, 10, 30, 9);
      expect([for (final t in c2cLeaveChoices(at, true)) c2cClock(t)], ['8:30', '8:45', '9:00', '9:15', '9:30']);
      expect(c2cLeaveChoices(at, false), [at]);
      expect(c2cOfferSentLine(150), 'Offer of RM 150 sent. Waiting for the rider.');
    });
  });

  group('the day', () {
    test('the steps', () {
      expect(c2cNextStep(C2cStatus.booked), (to: C2cStatus.driverArriving, label: 'On my way'));
      expect(c2cNextStep(C2cStatus.driverArriving), (to: C2cStatus.onTrip, label: 'Rider picked up'));
      expect(c2cNextStep(C2cStatus.onTrip), (to: C2cStatus.completed, label: 'Complete trip'));
      expect(c2cNextStep(C2cStatus.completed), isNull);
      expect(c2cNextStep(C2cStatus.open), isNull);
    });

    test('giving a trip up: booked or on the way, before the time to leave', () {
      final now = DateTime(2026, 10, 30, 8);
      expect(c2cDriverCanCancel(C2cBooking.fromRow(_row(status: 'booked')), now), isTrue);
      expect(c2cDriverCanCancel(C2cBooking.fromRow(_row(status: 'driver_arriving')), now), isTrue);
      expect(c2cDriverCanCancel(C2cBooking.fromRow(_row(status: 'on_trip')), now), isFalse);
      expect(c2cDriverCanCancel(C2cBooking.fromRow(_row(status: 'booked')), DateTime(2026, 10, 30, 9)), isFalse);
    });

    test('My trips: today, later, done', () {
      final now = DateTime(2026, 10, 28, 10);
      final trips = c2cDriverTrips([
        C2cBooking.fromRow(_row(id: 'later', status: 'booked', leaveAt: DateTime(2026, 10, 30, 9))),
        C2cBooking.fromRow(_row(id: 'tonight', status: 'booked', leaveAt: DateTime(2026, 10, 28, 20))),
        C2cBooking.fromRow(_row(id: 'going', status: 'on_trip', leaveAt: DateTime(2026, 10, 28, 8))),
        C2cBooking.fromRow(_row(id: 'old', status: 'completed', leaveAt: DateTime(2026, 10, 20, 8))),
        C2cBooking.fromRow(_row(id: 'gone', status: 'cancelled', leaveAt: DateTime(2026, 10, 25, 8))),
      ], now);
      expect([for (final b in trips.today) b.id], ['going', 'tonight']);
      expect([for (final b in trips.later) b.id], ['later']);
      expect([for (final b in trips.done) b.id], ['gone', 'old']);
      expect(c2cTripsTabLabel(0), 'My trips');
      expect(c2cTripsTabLabel(3), 'My trips (3)');
      expect(c2cDriverTag(C2cStatus.driverArriving), 'On the way');
    });

    test('a booking read with its points, commission and when the driver gave it up', () {
      final b = C2cBooking.fromRow({
        ..._row(status: 'open'),
        'pickup_lat': 3.15,
        'pickup_lng': 101.7,
        'rider_id': 'r1',
        'commission_rate': 0.12,
        'commission_amount': 16.8,
        'driver_dropped_at': DateTime(2026, 10, 28, 9).toUtc().toIso8601String(),
        'note': 'Gate B',
      });
      expect(b.pickupLat, 3.15);
      expect(b.riderId, 'r1');
      expect(b.commissionAmount, 16.8);
      expect(b.driverDroppedAt, DateTime(2026, 10, 28, 9));
      expect(b.note, 'Gate B');
    });
  });

  group('the chat of a booking (the ride chat, 0308)', () {
    test('a thread is a ride or "c2c:" and the booking', () {
      expect(c2cChatThread('b1'), 'c2c:b1');
      expect(isC2cChatThread('c2c:b1'), isTrue);
      expect(isC2cChatThread('r1'), isFalse);
      expect(rideChatThreadKey('c2c:b1'), (column: 'c2c_booking_id', id: 'b1'));
      expect(rideChatThreadKey('r1'), (column: 'request_id', id: 'r1'));
    });

    test('a row knows its thread', () {
      final m = RideMessage.fromRow({'id': 'm1', 'c2c_booking_id': 'b1', 'sender_role': 'rider', 'body': 'Hi'})!;
      expect(m.requestId, 'c2c:b1');
      expect(RideMessage.fromRow({'id': 'm2', 'request_id': 'r1', 'sender_role': 'partner', 'body': 'Hi'})!.requestId, 'r1');
    });

    test('files go in the booking\'s folder', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      expect(rideChatMediaPath('c2c:b1', RideMessageType.image, 'JPG', at, 'ab12'), 'b1/image-1700000000000-ab12.jpg');
      expect(rideChatMediaPath('r1', RideMessageType.audio, 'm4a', at, 'cd34'), 'r1/audio-1700000000000-cd34.m4a');
    });

    test('a waiting message is sent under the booking', () {
      final p = PendingRideMessage(
        clientMsgId: 'c1',
        requestId: 'c2c:b1',
        senderId: 'u1',
        role: RideChatRole.partner,
        type: RideMessageType.text,
        body: 'On my way',
        createdAt: DateTime(2026, 10, 28),
      );
      expect(p.toRow(), {
        'c2c_booking_id': 'b1',
        'sender_role': 'partner',
        'type': 'text',
        'client_msg_id': 'c1',
        'body': 'On my way',
      });
      expect(PendingRideMessage.fromJson(p.toJson())!.requestId, 'c2c:b1');
    });

    test('its push opens the chat on the recipient\'s side', () {
      expect(pushRouteFor({'type': 'ride_message', 'c2c_booking_id': 'b1', 'role': 'partner'}),
          '/drive/city-to-city/b1/chat');
      expect(pushRouteFor({'type': 'ride_message', 'c2c_booking_id': 'b1', 'role': 'rider'}), '/city-to-city/b1/chat');
      expect(pushRouteFor({'type': 'ride_message', 'request_id': 'r1', 'role': 'partner'}), '/drive/trip/r1/chat');
    });
  });
}
