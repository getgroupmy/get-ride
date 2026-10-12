// The driver's request radius (My Ride, migration 0160): which open requests
// the list shows, the "for you first" window, and the menu row's gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/driver_request_radius.dart';
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/features/partner/my_ride_code_screen.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart';

typedef _Req = ({String id, double? away, String service, bool starred});

void main() {
  group('service dispatch configs', () {
    test('keyed by lower-case name and by id; the first entry with a name wins', () {
      final configs = dispatchConfigsByService([
        (id: 'e1', values: {'name': ' Teksi ', searchRadiusMaxKmKey: 8}),
        (id: 'e2', values: {'name': 'teksi', searchRadiusMaxKmKey: 30}),
        (id: 'e3', values: <String, dynamic>{}),
      ]);
      expect(configs['teksi']!.searchRadiusMaxKm, 8);
      expect(configs['e2']!.searchRadiusMaxKm, 30);
      expect(configs['e3']!.searchRadiusMaxKm, ServiceDispatchConfig.defaultMaxKm);
      expect(dispatchConfigFor(configs, 'TEKSI').searchRadiusMaxKm, 8);
      expect(dispatchConfigFor(configs, 'e2').searchRadiusMaxKm, 30);
    });

    test('an unknown or missing service takes the defaults (15 km)', () {
      expect(dispatchConfigFor(const {}, 'Bike').searchRadiusMaxKm, 15);
      expect(dispatchConfigFor(const {}, null).searchRadiusMaxKm, 15);
      expect(dispatchConfigFor(const {}, '  ').searchRadiusMaxKm, 15);
    });
  });

  group('pickup radius', () {
    test('inside the cap, at it, and beyond it', () {
      expect(withinPickupRadius(awayKm: 3, maxKm: 15), isTrue);
      expect(withinPickupRadius(awayKm: 15, maxKm: 15), isTrue);
      expect(withinPickupRadius(awayKm: 15.1, maxKm: 15), isFalse);
    });

    test('starred requests are never capped', () {
      expect(withinPickupRadius(awayKm: 400, maxKm: 15, uncapped: true), isTrue);
    });

    test('an unknown distance (no fix, or no pickup) is kept', () {
      expect(withinPickupRadius(awayKm: null, maxKm: 15), isTrue);
      expect(withinPickupRadius(awayKm: double.nan, maxKm: 15), isTrue);
    });

    test('a nonsense cap filters nothing', () {
      expect(withinPickupRadius(awayKm: 99, maxKm: 0), isTrue);
      expect(withinPickupRadius(awayKm: 99, maxKm: double.infinity), isTrue);
    });

    test('the filter keeps order, caps per service, and spares the starred', () {
      final caps = {'teksi': 5.0, 'car': 20.0};
      const List<_Req> reqs = [
        (id: 'near', away: 2, service: 'teksi', starred: false),
        (id: 'far-teksi', away: 10, service: 'teksi', starred: false),
        (id: 'far-car', away: 10, service: 'car', starred: false),
        (id: 'far-star', away: 300, service: 'teksi', starred: true),
        (id: 'unknown', away: null, service: 'teksi', starred: false),
      ];
      final kept = filterByPickupRadius<_Req>(
        reqs,
        awayKm: (r) => r.away,
        maxKm: (r) => caps[r.service]!,
        uncapped: (r) => r.starred,
      );
      expect([for (final r in kept) r.id], ['near', 'far-car', 'far-star', 'unknown']);
    });

    test('with the driver position unknown every request shows', () {
      const List<_Req> reqs = [
        (id: 'a', away: null, service: 'teksi', starred: false),
        (id: 'b', away: null, service: 'teksi', starred: false),
      ];
      expect(filterByPickupRadius<_Req>(reqs, awayKm: (r) => r.away, maxKm: (_) => 1, uncapped: (_) => false), reqs);
    });
  });

  group('for you first', () {
    final now = DateTime.utc(2026, 10, 12, 9);

    test('only while the window runs and only for a targeted driver', () {
      final until = now.add(const Duration(seconds: 30));
      expect(myRideForMeFirst(me: 'me', targetDriverIds: ['me'], targetedUntil: until, now: now), isTrue);
      expect(myRideForMeFirst(me: 'other', targetDriverIds: ['me'], targetedUntil: until, now: now), isFalse);
      expect(myRideForMeFirst(me: null, targetDriverIds: ['me'], targetedUntil: until, now: now), isFalse);
      expect(
        myRideForMeFirst(
          me: 'me',
          targetDriverIds: ['me'],
          targetedUntil: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isFalse,
      );
      expect(myRideForMeFirst(me: 'me', targetDriverIds: ['me'], targetedUntil: null, now: now), isFalse);
    });

    test('the countdown rounds up and reads minutes past a minute', () {
      expect(myRideWindowCountdown(const Duration(seconds: 41, milliseconds: 200)), '42 s');
      expect(myRideWindowCountdown(const Duration(seconds: 90)), '1:30');
      expect(myRideWindowCountdown(Duration.zero), isNull);
      expect(myRideWindowCountdown(null), isNull);
    });
  });

  group('menu and copy', () {
    test('My Ride code shows only with a code; Vehicle information only when linked', () {
      expect(partnerMenuRowShows(myRideMenuItemId, obdLinked: true, hasMyRideCode: false), isFalse);
      expect(partnerMenuRowShows(myRideMenuItemId, obdLinked: false, hasMyRideCode: true), isTrue);
      expect(partnerMenuRowShows(vehicleInfoMenuItemId, obdLinked: false, hasMyRideCode: true), isFalse);
      expect(partnerMenuRowShows(vehicleInfoMenuItemId, obdLinked: true, hasMyRideCode: false), isTrue);
      expect(partnerMenuRowShows('wallet', obdLinked: false, hasMyRideCode: false), isTrue);
    });

    test('the My Ride code row is a default driver item', () {
      expect(defaultPartnerMenuItems.map((e) => e.$1), contains(myRideMenuItemId));
    });

    test('a rider row: added date and rides together', () {
      final r = FavouriteRider(riderId: 'r', name: 'Aminah A.', addedAt: DateTime(2026, 10, 3, 12), ridesTogether: 4);
      expect(favouriteRiderSubtitle(r), 'Added 3 Oct 2026 · 4 rides together');
      expect(
        favouriteRiderSubtitle(const FavouriteRider(riderId: 'r', name: 'x', ridesTogether: 1)),
        '1 ride together',
      );
      expect(favouriteRiderSubtitle(const FavouriteRider(riderId: 'r', name: 'x')), 'No rides together yet');
    });

    test('the shared text carries the readable code and the QR link', () {
      final text = myRideShareText('ABCD2345');
      expect(text, contains('ABCD 2345'));
      expect(text, contains('getride://myride/ABCD2345'));
    });
  });
}
