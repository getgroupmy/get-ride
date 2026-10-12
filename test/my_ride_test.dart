// My Ride — favourite drivers (migration 0160): lib/src/core/my_ride.dart,
// lib/src/data/my_ride_repository.dart and the RideRequest getters.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/my_ride_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('parseMyRideCode', () {
    test('a bare code, any case, spaces and dashes ignored', () {
      expect(parseMyRideCode('AB2C3D4E'), 'AB2C3D4E');
      expect(parseMyRideCode('  ab2c 3d4e '), 'AB2C3D4E');
      expect(parseMyRideCode('ab2c-3d4e'), 'AB2C3D4E');
    });

    test('the QR payload, any case, trailing slash', () {
      expect(parseMyRideCode('getride://myride/AB2C3D4E'), 'AB2C3D4E');
      expect(parseMyRideCode('GETRIDE://MYRIDE/ab2c3d4e/'), 'AB2C3D4E');
      expect(parseMyRideCode(myRideQrPayload('xy7z8w9v')), 'XY7Z8W9V');
    });

    test('anything else is not a code', () {
      expect(parseMyRideCode(null), isNull);
      expect(parseMyRideCode(''), isNull);
      expect(parseMyRideCode('AB2C3D4'), isNull, reason: 'too short');
      expect(parseMyRideCode('AB2C3D4EF'), isNull, reason: 'too long');
      expect(parseMyRideCode('AB0C3D4E'), isNull, reason: '0 is not in the alphabet');
      expect(parseMyRideCode('ABIC3D4E'), isNull, reason: 'I is not in the alphabet');
      expect(parseMyRideCode('https://example.com/AB2C3D4E'), isNull, reason: 'another link');
    });

    test('the alphabet is 32 unambiguous characters', () {
      expect(myRideCodeAlphabet.length, 32);
      expect(myRideCodeAlphabet, isNot(contains(RegExp('[01IO]'))));
    });
  });

  test('formatMyRideCode groups by four', () {
    expect(formatMyRideCode('ab2c3d4e'), 'AB2C 3D4E');
    expect(formatMyRideCode('ABC'), 'ABC');
  });

  test('myRideQrPayload', () {
    expect(myRideQrPayload(' ab2c3d4e '), 'getride://myride/AB2C3D4E');
  });

  group('effectiveMyRideMaxKm', () {
    test('no limit when neither is set', () {
      expect(effectiveMyRideMaxKm(null, null), isNull);
      expect(effectiveMyRideMaxKm(0, 0), isNull);
    });
    test('the one that is set', () {
      expect(effectiveMyRideMaxKm(8, null), 8);
      expect(effectiveMyRideMaxKm(0, 12), 12);
    });
    test('the smaller when both are', () {
      expect(effectiveMyRideMaxKm(8, 12), 8);
      expect(effectiveMyRideMaxKm(20, 12), 12);
    });
  });

  group('the favourites window', () {
    final now = DateTime.utc(2026, 10, 12, 9);
    test('open while targeted and before targetedUntil', () {
      final until = now.add(const Duration(seconds: 42));
      expect(myRideWindowOpen(targets: ['d1'], targetedUntil: until, now: now), isTrue);
      expect(myRideWindowRemaining(targets: ['d1'], targetedUntil: until, now: now), const Duration(seconds: 42));
    });
    test('closed with no targets, no deadline, or past it', () {
      expect(
        myRideWindowOpen(targets: const [], targetedUntil: now.add(const Duration(minutes: 1)), now: now),
        isFalse,
      );
      expect(myRideWindowOpen(targets: ['d1'], targetedUntil: null, now: now), isFalse);
      expect(myRideWindowOpen(targets: ['d1'], targetedUntil: now, now: now), isFalse);
      expect(
        myRideWindowRemaining(targets: ['d1'], targetedUntil: now.subtract(const Duration(seconds: 1)), now: now),
        isNull,
      );
    });
  });

  group('isStarredFor', () {
    test('targeted at me', () {
      expect(isStarredFor(riderId: 'r1', targetDriverIds: ['me'], me: 'me', favouriteRiderIds: const {}), isTrue);
    });
    test('from a rider who has me as a favourite', () {
      expect(isStarredFor(riderId: 'r1', targetDriverIds: const [], me: 'me', favouriteRiderIds: {'r1'}), isTrue);
    });
    test('otherwise not, and never signed out', () {
      expect(isStarredFor(riderId: 'r2', targetDriverIds: ['d9'], me: 'me', favouriteRiderIds: {'r1'}), isFalse);
      expect(isStarredFor(riderId: 'r1', targetDriverIds: ['me'], me: null, favouriteRiderIds: {'r1'}), isFalse);
    });
    test('pinStarredFirst keeps the order within each group', () {
      expect(pinStarredFirst([1, 2, 3, 4, 5], (n) => n.isEven), [2, 4, 1, 3, 5]);
    });
  });

  group('ServiceDispatchConfig', () {
    test('defaults', () {
      final c = ServiceDispatchConfig.fromValues(null);
      expect(c.searchRadiusMinKm, 3);
      expect(c.searchRadiusMaxKm, 15);
      expect(c.widenAfter, const Duration(seconds: 30));
      expect(c.myRideMaxKm, isNull);
      expect(c.myRideWindow, const Duration(seconds: 60));
    });
    test('from the service entry, with the server clamps', () {
      final c = ServiceDispatchConfig.fromValues({
        searchRadiusMinKmKey: 5,
        searchRadiusMaxKmKey: '2',
        searchWidenAfterSecKey: 0,
        myRideMaxKmKey: 10,
        myRideWindowSecKey: 9999,
      });
      expect(c.searchRadiusMinKm, 5);
      expect(c.searchRadiusMaxKm, 5, reason: 'max is never under min');
      expect(c.widenAfter, const Duration(seconds: 30), reason: '0 takes the default');
      expect(c.myRideMaxKm, 10);
      expect(c.myRideWindow, const Duration(seconds: 600));
    });
  });

  group('rows', () {
    test('FavouriteDriver.fromRow', () {
      final d = FavouriteDriver.fromRow({
        'driver_id': 'd1',
        'name': 'Dan',
        'added_at': '2026-10-01T00:00:00Z',
        'available': true,
        'online': true,
        'last_seen': 'online',
        'distance_km': 2.5,
        'make': 'Perodua',
        'model': 'Bezza',
        'colour': 'White',
        'plate': 'WXY 1600',
        'rating': 4.8,
      });
      expect(d.driverId, 'd1');
      expect(d.available && d.online, isTrue);
      expect(d.lastSeen, LastSeen.online);
      expect(d.distanceKm, 2.5);
      expect(d.vehicleLabel, 'White Perodua Bezza');
      expect(d.rating, 4.8);
    });
    test('an unavailable driver with nothing else', () {
      final d = FavouriteDriver.fromRow({'driver_id': 'd2', 'available': false, 'vehicle': 'Myvi'});
      expect(d.name, 'Driver');
      expect(d.available, isFalse);
      expect(d.lastSeen, isNull);
      expect(d.vehicleLabel, 'Myvi');
    });
    test('FavouriteRider.fromRow', () {
      final r = FavouriteRider.fromRow({
        'rider_id': 'r1',
        'name': 'Aminah A.',
        'hidden': true,
        'hidden_at': '2026-10-02T00:00:00Z',
        'rides_together': 3,
      });
      expect(r.name, 'Aminah A.');
      expect(r.hidden, isTrue);
      expect(r.hiddenAt, isNotNull);
      expect(r.ridesTogether, 3);
    });
  });

  group('AddFavouriteResult.fromJson', () {
    test('added', () {
      final r = AddFavouriteResult.fromJson({
        'ok': true,
        'driver': {'driver_id': 'd1', 'name': 'Dan'},
      });
      expect(r, isA<FavouriteAdded>());
      expect((r as FavouriteAdded).driver?.name, 'Dan');
      expect(r.driver?.available, isTrue);
    });
    test('refused, with the wait when rate limited', () {
      final r = AddFavouriteResult.fromJson({'ok': false, 'error': 'rate_limited', 'retry_after': 120});
      expect((r as FavouriteNotAdded).error, AddFavouriteError.rateLimited);
      expect(r.retryAfter, const Duration(minutes: 2));
      expect(
        (AddFavouriteResult.fromJson({'ok': false, 'error': 'own_code'}) as FavouriteNotAdded).error,
        AddFavouriteError.ownCode,
      );
      expect((AddFavouriteResult.fromJson(null) as FavouriteNotAdded).error, AddFavouriteError.unknown);
    });
    test('every error has a message', () {
      for (final e in AddFavouriteError.values) {
        expect(e.message, isNotEmpty);
      }
    });
  });

  test('OfferToAllOutcome.fromJson', () {
    expect(OfferToAllOutcome.fromJson({'ok': true, 'opened': true}), OfferToAllOutcome.opened);
    expect(OfferToAllOutcome.fromJson({'ok': true, 'opened': false}), OfferToAllOutcome.alreadyOpen);
    expect(OfferToAllOutcome.fromJson({'ok': false, 'error': 'not_open'}), OfferToAllOutcome.notOpen);
  });

  group('RideRequest', () {
    final now = DateTime.now().toUtc();
    test('an ordinary request has no My Ride', () {
      final r = RideRequest({'id': 'x', 'rider_id': 'r1', 'status': 'open'});
      expect(r.targetDriverIds, isEmpty);
      expect(r.isMyRide, isFalse);
      expect(r.myRideWindowOpenAt(now), isFalse);
      expect(r.starredFor('me', const {}), isFalse);
      expect(r.starredFor('me', {'r1'}), isTrue);
    });
    test('a targeted one', () {
      final r = RideRequest({
        'id': 'x',
        'rider_id': 'r1',
        'status': 'open',
        'target_driver_ids': ['me', 'd2'],
        'targeted_until': now.add(const Duration(seconds: 30)).toIso8601String(),
        'my_ride_max_km': 5,
        'fallback_pushed_at': null,
      });
      expect(r.targetDriverIds, ['me', 'd2']);
      expect(r.isMyRide, isTrue);
      expect(r.myRideMaxKm, 5);
      expect(r.myRideWindowOpenAt(now), isTrue);
      expect(r.myRideWindowRemainingAt(now)!.inSeconds, inInclusiveRange(29, 30));
      expect(r.fallbackPushedAt, isNull);
      expect(r.starredFor('me', const {}), isTrue);
      expect(r.starredFor('d9', const {}), isFalse);
    });
  });

  test('isMissingMyRide', () {
    expect(isMissingMyRide(const PostgrestException(message: 'x', code: 'PGRST202')), isTrue);
    expect(isMissingMyRide(const PostgrestException(message: 'x', code: '42883')), isTrue);
    expect(
      isMissingMyRide(const PostgrestException(message: 'Could not find the function public.my_ride_code')),
      isTrue,
    );
    expect(isMissingMyRide(const PostgrestException(message: 'not_authorized', code: '42501')), isFalse);
  });
}
