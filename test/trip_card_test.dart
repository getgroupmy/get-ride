// The trip card (lib/src/core/trip_card.dart): what each stage of a ride, a
// courier parcel and a freight move says on the rider's and the driver's
// lock screen, its progress bar, its buttons and their links, the admin's
// switches, and that a courier's delivery code never reaches it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_card.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:latlong2/latlong.dart';

// KL: the pickup at Mid Valley, the drop at KLCC.
const _pickup = LatLng(3.1180, 101.6770);
const _drop = LatLng(3.1579, 101.7116);

RideRequest _ride(String status, {Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'ride-1',
  'status': status,
  'rider_id': 'rider',
  'rider_name': 'Aina Rahman',
  'partner_id': status == 'open' ? null : 'driver',
  'partner_name': 'Ali Hassan',
  'partner_vehicle': 'Perodua Bezza · Silver',
  'partner_plate': 'WXY 4821',
  'pickup_name': 'Mid Valley',
  'pickup_lat': _pickup.latitude,
  'pickup_lng': _pickup.longitude,
  'drop_name': 'KLCC',
  'drop_lat': _drop.latitude,
  'drop_lng': _drop.longitude,
  'distance_km': 7.5,
  'duration_min': 18,
  'fare': 18.5,
  'currency': 'MYR',
  'payment_mode': 'Cash',
  // The driver accepted 3 km south of the pickup and is half way there.
  'partner_accept_lat': 3.0910,
  'partner_accept_lng': 101.6770,
  'partner_live_lat': 3.1045,
  'partner_live_lng': 101.6770,
  'completed_at': status == 'completed' ? '2026-10-22T08:18:00Z' : null,
  ...extra,
});

const _courier = {'parcel_size': 'S', 'cargo_description': 'Documents', 'recipient_name': 'Aminah'};
const _freight = {'cargo_description': 'Sofa and boxes', 'service': 'Van (S)'};

final _now = DateTime(2026, 10, 22, 15, 48);
const _eta17 = (minutes: 16.4, km: 9.4);
const _eta6 = (minutes: 5.2, km: 1.5);

TripCard _card(String status, {Map<String, dynamic> extra = const {}, bool driver = false, ({double minutes, double km})? eta}) =>
    buildTripCard(_ride(status, extra: extra), asDriver: driver, now: _now, eta: eta)!;

void main() {
  group("the rider's ride card", () {
    test('finding a driver', () {
      final c = _card('open');
      expect(c.stage, TripCardStage.finding);
      expect(c.headline, 'Looking for a driver');
      expect(c.chip, 'Finding');
      expect(c.footTitle, 'Mid Valley to KLCC');
      expect(c.footText, 'Offers will show here');
      expect(c.actions, [TripCardAction.cancel]);
      expect(c.progress, closeTo(0.04, 1e-9));
      expect(c.plate, isNull, reason: 'no driver yet');
    });

    test('on the way: name, minutes, car and plate, Call Chat Share', () {
      final c = _card('accepted', eta: _eta6);
      expect(c.headline, 'Ali is 6 min away');
      expect(c.emphasis, '6 min');
      expect(c.chip, '6 min');
      expect(c.compact, '6 min');
      expect(c.driverName, 'Ali');
      expect(c.car, 'Perodua Bezza · Silver');
      expect(c.plate, 'WXY 4821');
      expect(c.actions, [TripCardAction.call, TripCardAction.chat, TripCardAction.share]);
      expect(c.minutesLeft, 6);
      expect(c.eta, _now.add(const Duration(minutes: 6)));
    });

    test('on the way without minutes still names the driver', () {
      expect(_card('accepted').headline, 'Ali is on the way');
      expect(_card('accepted').chip, 'On the way');
    });

    test('arrived: where to meet and the plate', () {
      final c = _card('arrived', extra: {'pickup_door_name': 'Level 1, Door 5'});
      expect(c.headline, 'Ali has arrived');
      expect(c.emphasis, 'arrived');
      expect(c.subline, 'Meet at Level 1, Door 5');
      expect(c.plate, 'WXY 4821');
      expect(c.compact, 'Here');
      expect(c.progress, closeTo(0.45, 1e-9));
    });

    test('on the trip: the arrival time, time and distance left, Share and SOS', () {
      final c = _card('on_trip', eta: _eta17);
      expect(c.headline, 'You will arrive at 4:05 PM');
      expect(c.emphasis, '4:05 PM');
      expect(c.compact, '4:05');
      expect(c.subline, '17 min · 9.4 km left');
      expect(c.footTitle, 'Share your trip');
      expect(c.actions.take(2), [TripCardAction.share, TripCardAction.sos]);
      expect(c.plate, isNull, reason: 'the plate shows only while the driver comes');
    });

    test('done: what it cost and "How was your ride?"', () {
      final c = _card('completed');
      expect(c.stage, TripCardStage.done);
      expect(c.headline, 'You have arrived');
      expect(c.subline, contains('18.50'));
      expect(c.subline, endsWith('Cash'));
      expect(c.footTitle, 'How was your ride?');
      expect(c.footText, 'Tap to rate Ali');
      expect(c.actions, [TripCardAction.rate]);
      expect(c.progress, 1);
      expect(c.isDone, isTrue);
    });

    test('a cancelled or expired ride has no card', () {
      expect(buildTripCard(_ride('cancelled'), asDriver: false, now: _now), isNull);
      expect(buildTripCard(_ride('expired'), asDriver: false, now: _now), isNull);
    });

    test('no more than three buttons (what Android can show)', () {
      for (final s in ['open', 'accepted', 'arrived', 'on_trip', 'completed']) {
        for (final extra in [const <String, dynamic>{}, _courier, _freight]) {
          for (final driver in [false, true]) {
            final c = buildTripCard(_ride(s, extra: extra), asDriver: driver, now: _now, eta: _eta6);
            if (c != null) expect(c.actions.length, lessThanOrEqualTo(tripCardMaxActions));
          }
        }
      }
    });
  });

  group('courier', () {
    test('reads as a parcel at every stage', () {
      expect(_card('open', extra: _courier).headline, 'Looking for a courier');
      expect(_card('open', extra: _courier).subline, startsWith('Small parcel'));
      expect(_card('accepted', extra: _courier, eta: (minutes: 8, km: 2)).headline, 'Ali picks up in 8 min');
      expect(_card('arrived', extra: _courier).headline, 'Ali is at the pickup');
      final onWay = _card('on_trip', extra: {..._courier, 'started_at': '2026-10-22T07:51:00Z'}, eta: (minutes: 32, km: 12));
      expect(onWay.headline, 'Delivers at 4:20 PM');
      expect(onWay.subline, startsWith('Parcel picked up at '));
      final done = _card('completed', extra: _courier);
      expect(done.headline, 'Parcel delivered');
      expect(done.subline, startsWith('Received by Aminah'));
      expect(done.footTitle, 'How was the delivery?');
      expect(TripCardService.of(_ride('open', extra: _courier)), TripCardService.courier);
    });

    test('never carries the delivery code or the trip code, on any stage, for rider or courier', () {
      const code = '4719';
      final secret = {..._courier, 'otp': code, 'delivery_code': code, 'trip_code': code};
      for (final s in ['open', 'accepted', 'arrived', 'on_trip', 'completed']) {
        for (final driver in [false, true]) {
          final c = buildTripCard(_ride(s, extra: secret), asDriver: driver, now: _now, eta: _eta17);
          if (c == null) continue;
          final sent = jsonEncode(c.toPlatform(light: const TripCardColors(), dark: const TripCardColors()));
          expect(sent, isNot(contains(code)), reason: '$s ${driver ? 'driver' : 'rider'}');
          expect(sent, isNot(contains('Delivery code')));
        }
      }
    });
  });

  group('freight', () {
    test('reads as a move at every stage', () {
      expect(_card('open', extra: _freight).headline, 'Looking for a van or lorry');
      expect(_card('open', extra: _freight).subline, 'Van (S)');
      expect(_card('accepted', extra: _freight, eta: (minutes: 22, km: 9)).headline, 'Ali loads in 22 min');
      expect(_card('arrived', extra: _freight).headline, 'Loading your cargo');
      expect(_card('arrived', extra: _freight).chip, 'Loading');
      expect(_card('on_trip', extra: _freight, eta: (minutes: 52, km: 28)).headline, 'Arrives at 4:40 PM');
      expect(_card('on_trip', extra: _freight, eta: (minutes: 52, km: 28)).subline, '28.0 km left');
      expect(_card('completed', extra: _freight).headline, 'Cargo delivered');
      expect(_card('completed', extra: _freight).footTitle, 'How was the move?');
      expect(TripCardService.of(_ride('open', extra: _freight)), TripCardService.freight);
    });
  });

  group("the driver's own card", () {
    test('next pickup with the rider\'s first name and minutes, then waiting, the drop-off, done', () {
      final to = _card('accepted', driver: true, eta: _eta6);
      expect(to.isDriver, isTrue);
      expect(to.headline, 'Pick up Aina in 6 min');
      expect(to.subline, startsWith('Mid Valley'));
      expect(to.actions, [TripCardAction.call, TripCardAction.chat, TripCardAction.sos]);
      expect(to.plate, isNull, reason: "the driver's own car isn't news to them");
      expect(_card('arrived', driver: true).headline, 'Waiting for Aina');
      expect(_card('arrived', driver: true).chip, 'Waiting');
      expect(_card('on_trip', driver: true, eta: _eta17).headline, 'Drop-off at 4:05 PM');
      expect(_card('completed', driver: true).headline, 'Trip complete');
    });

    test('the passenger booked for is the one named', () {
      final c = _card('accepted', driver: true, extra: {'booked_for_name': 'Mei Ling Tan'});
      expect(c.headline, 'Pick up Mei');
    });

    test('courier and freight wording, and no card for an open request', () {
      expect(_card('accepted', driver: true, extra: _courier, eta: _eta6).headline, 'Collect the parcel in 6 min');
      expect(_card('accepted', driver: true, extra: _freight, eta: _eta6).headline, 'Loading point in 6 min');
      expect(_card('on_trip', driver: true, extra: _courier, eta: _eta17).headline, 'Delivery at 4:05 PM');
      expect(_card('completed', driver: true, extra: _freight).headline, 'Cargo delivered');
      expect(buildTripCard(_ride('open'), asDriver: true, now: _now), isNull);
    });
  });

  group('progress', () {
    test('each stage has its stretch of the bar, in order', () {
      expect(tripCardProgress(TripCardStage.finding, 0.9), closeTo(0.04, 1e-9));
      expect(tripCardProgress(TripCardStage.toPickup, 0), closeTo(0.05, 1e-9));
      expect(tripCardProgress(TripCardStage.toPickup, 1), closeTo(0.45, 1e-9));
      expect(tripCardProgress(TripCardStage.arrived, 0), closeTo(0.45, 1e-9));
      expect(tripCardProgress(TripCardStage.onTrip, 0), closeTo(0.5, 1e-9));
      expect(tripCardProgress(TripCardStage.onTrip, 2), 1, reason: 'clamped');
      expect(tripCardProgress(TripCardStage.toPickup, -1), closeTo(0.05, 1e-9), reason: 'clamped');
      expect(tripCardProgress(TripCardStage.done, 0), 1);
    });

    test('to the pickup: the share of the way from where the driver accepted', () {
      final f = tripStageFraction(_ride('accepted'));
      expect(f, closeTo(0.5, 0.02));
      final there = tripStageFraction(_ride('accepted', extra: {'partner_live_lat': _pickup.latitude}));
      expect(there, closeTo(1, 1e-6));
      final behind = tripStageFraction(_ride('accepted', extra: {'partner_live_lat': 3.05}));
      expect(behind, 0, reason: 'further than where they accepted: clamped');
      expect(tripStageFraction(_ride('accepted', extra: {'partner_accept_lat': null})), 0);
    });

    test('on the trip: the route kilometres driven', () {
      expect(tripStageFraction(_ride('on_trip'), kmLeft: 7.5), 0);
      expect(tripStageFraction(_ride('on_trip'), kmLeft: 3), closeTo(0.6, 1e-9));
      expect(tripStageFraction(_ride('on_trip'), kmLeft: 0), 1);
      expect(tripStageFraction(_ride('on_trip'), kmLeft: 20), 0);
      expect(tripStageFraction(_ride('on_trip')), 0);
    });

    test('only moves forward within a stage', () {
      expect(monotonicProgress(0.3, 0.2, sameStage: true), 0.3);
      expect(monotonicProgress(0.3, 0.4, sameStage: true), 0.4);
      expect(monotonicProgress(0.3, 0.2, sameStage: false), 0.2);
      expect(monotonicProgress(null, 0.2, sameStage: true), 0.2);
    });

    test("the card's own progress follows the stage fraction", () {
      final c = buildTripCard(_ride('on_trip'), asDriver: false, now: _now, eta: _eta17, fraction: 0.5)!;
      expect(c.progress, closeTo(0.75, 1e-9));
    });
  });

  group('minutes and kilometres left', () {
    test("along the trip map's road route when it goes to the same place", () {
      final route = TripRouteFix(
        target: _drop,
        points: const [LatLng(3.1045, 101.6770), LatLng(3.1300, 101.6900), _drop],
        minutes: 20,
        km: 10,
      );
      final eta = tripEta(_ride('on_trip'), route: route, driver: const LatLng(3.1045, 101.6770))!;
      expect(eta.minutes, closeTo(20, 0.01));
      expect(eta.km, closeTo(10, 0.01));
      final later = tripEta(_ride('on_trip'), route: route, driver: const LatLng(3.1300, 101.6900))!;
      expect(later.km, lessThan(10));
      expect(later.minutes, lessThan(20));
    });

    test('a route to elsewhere (the pickup, before the trip) is not used', () {
      final route = TripRouteFix(target: _pickup, points: const [LatLng(3.09, 101.67), _pickup], minutes: 99, km: 99);
      final eta = tripEta(_ride('on_trip'), route: route)!;
      expect(eta.minutes, lessThan(99));
    });

    test('in a straight line without a route: the approach speed, or the ride\'s own pace', () {
      final toPickup = tripEta(_ride('accepted'))!;
      expect(toPickup.km, closeTo(1.5, 0.05));
      expect(toPickup.minutes, 4, reason: '1.5 km at 24 km/h, rounded up');
      final onTrip = tripEta(_ride('on_trip'))!;
      expect(onTrip.km, greaterThan(0));
      expect(onTrip.minutes, closeTo(onTrip.km / 7.5 * 18, 1e-6));
    });

    test('nothing to say while waiting at the pickup or with no driver position', () {
      expect(tripEta(_ride('arrived')), isNull);
      expect(tripEta(_ride('on_trip', extra: {'partner_live_lat': null})), isNull);
    });
  });

  group('sending', () {
    test('a new stage goes at once, a move within one every 15 seconds', () {
      final t0 = DateTime(2026, 1, 1, 12);
      expect(tripCardSendDue(now: t0, stage: TripCardStage.toPickup), isTrue);
      expect(
        tripCardSendDue(now: t0.add(const Duration(seconds: 5)), lastSentAt: t0, lastStage: TripCardStage.toPickup, stage: TripCardStage.toPickup),
        isFalse,
      );
      expect(
        tripCardSendDue(now: t0.add(const Duration(seconds: 15)), lastSentAt: t0, lastStage: TripCardStage.toPickup, stage: TripCardStage.toPickup),
        isTrue,
      );
      expect(
        tripCardSendDue(now: t0.add(const Duration(seconds: 1)), lastSentAt: t0, lastStage: TripCardStage.toPickup, stage: TripCardStage.arrived),
        isTrue,
      );
    });

    test('the done card stays its minutes after the trip ended', () {
      final end = DateTime(2026, 1, 1, 12);
      expect(tripCardDoneUntil(completedAt: end, now: end.add(const Duration(minutes: 2)), doneMinutes: 5), end.add(const Duration(minutes: 5)));
      expect(tripCardDoneUntil(now: end, doneMinutes: 5), end.add(const Duration(minutes: 5)));
    });

    test('what the phone is handed', () {
      final c = _card('accepted', eta: _eta6);
      final m = c.toPlatform(
        light: const TripCardColors(accent: 0xFF0C7AB8),
        dark: const TripCardColors(),
        clearAfter: const Duration(minutes: 5),
      );
      expect(m['rideId'], 'ride-1');
      expect(m['role'], 'rider');
      expect(m['stage'], 'toPickup');
      expect(m['plate'], 'WXY 4821');
      expect(m['ongoing'], isTrue);
      expect(m['clearAfterMs'], 300000);
      expect((m['colors']! as Map)['light'], containsPair('accent', 0xFF0C7AB8));
      expect((m['colors']! as Map)['dark'], containsPair('background', 0xFF000000));
      expect(m['actions'], [
        {'id': 'call', 'label': 'Call', 'uri': 'getride://trip/ride-1?do=call'},
        {'id': 'chat', 'label': 'Chat', 'uri': 'getride://trip/ride-1?do=chat'},
        {'id': 'share', 'label': 'Share trip', 'uri': 'getride://trip/ride-1?do=share'},
      ]);
      expect(m['openUri'], 'getride://trip/ride-1');
      expect(m.containsKey('footTitle'), isFalse, reason: 'nothing unset is sent');
      expect(m.values.whereType<String>().where((s) => s.contains('→')), isEmpty);
    });
  });

  group('links', () {
    test('each button opens the trip and runs itself there', () {
      Uri link(TripCardAction? a, {bool driver = false}) => tripCardLink('ride-1', driver: driver, action: a);
      expect(tripCardLinkLocation(link(null)), '/ride/ride-1');
      expect(tripCardLinkLocation(link(TripCardAction.call)), '/ride/ride-1?card=call');
      expect(tripCardLinkLocation(link(TripCardAction.chat)), '/ride/ride-1/chat');
      expect(tripCardLinkLocation(link(TripCardAction.share)), '/ride/ride-1?card=share');
      expect(tripCardLinkLocation(link(TripCardAction.sos)), '/ride/ride-1?card=sos');
      expect(tripCardLinkLocation(link(TripCardAction.cancel)), '/ride/ride-1?card=cancel');
      expect(tripCardLinkLocation(link(TripCardAction.rate)), '/ride/ride-1');
      expect(tripCardLinkLocation(link(TripCardAction.call, driver: true)), '/drive/trip/ride-1?card=call');
      expect(tripCardLinkLocation(link(TripCardAction.chat, driver: true)), '/drive/trip/ride-1/chat');
    });

    test('other links are left to the rest of the router', () {
      expect(tripCardLinkLocation(Uri.parse('getride://ref/ABC')), isNull);
      expect(tripCardLinkLocation(Uri.parse('https://getride.my/trip/ride-1')), isNull);
      expect(tripCardLinkLocation(Uri.parse('getride://trip/a/b')), isNull);
      expect(tripCardLinkLocation(Uri.parse('getride://trip/bad%20id')), isNull);
      expect(tripCardLinkLocation(Uri.parse('getride://trip/ride-1?do=unknown')), '/ride/ride-1');
    });
  });

  group('admin settings', () {
    test('missing means every service on and the done card for 5 minutes', () {
      final s = TripCardSettings.fromDisplay(const {});
      expect(s, const TripCardSettings());
      expect(s.doneMinutes, 5);
      for (final service in TripCardService.values) {
        expect(s.allows(service, asDriver: false), isTrue);
        expect(s.allows(service, asDriver: true), isTrue);
      }
    });

    test('per service, and the driver card on top of its service', () {
      final s = TripCardSettings.fromDisplay({
        tripCardSettingsKey: {'ride': true, 'courier': false, 'freight': true, 'driver': false, 'doneMinutes': 0},
      });
      expect(s.allows(TripCardService.ride, asDriver: false), isTrue);
      expect(s.allows(TripCardService.courier, asDriver: false), isFalse);
      expect(s.allows(TripCardService.ride, asDriver: true), isFalse);
      expect(s.doneMinutes, 0);
      final on = s.copyWith(driver: true);
      expect(on.allows(TripCardService.freight, asDriver: true), isTrue);
      expect(on.allows(TripCardService.courier, asDriver: true), isFalse);
    });

    test('the minutes are kept within 0 to 60 and saved back into the blob', () {
      expect(TripCardSettings.fromDisplay({tripCardSettingsKey: {'doneMinutes': 999}}).doneMinutes, 60);
      expect(TripCardSettings.fromDisplay({tripCardSettingsKey: {'doneMinutes': -3}}).doneMinutes, 0);
      expect(const TripCardSettings().copyWith(doneMinutes: 61).doneMinutes, 60);
      final blob = withTripCardSettings({'serviceEnabled': true}, const TripCardSettings(courier: false, doneMinutes: 7));
      expect(blob['serviceEnabled'], isTrue);
      expect(TripCardSettings.fromDisplay(blob), const TripCardSettings(courier: false, doneMinutes: 7));
    });
  });
}
