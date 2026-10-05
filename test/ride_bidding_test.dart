import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/fare_offer.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

const _me = '11111111-1111-1111-1111-111111111111';
const _other = '22222222-2222-2222-2222-222222222222';

RideRequest ride({
  String status = 'open',
  double fare = 20,
  double? offered,
  String? partner,
  bool offerMe = true,
  String? partnerName,
}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': status,
  'fare': fare,
  'ride_fare': fare,
  'offered_fare': offered,
  'partner_id': partner,
  'partner_name': partnerName,
  'offer_me': offerMe,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
});

class _FakeRides implements RideRepository {
  final rows = StreamController<RideRequest>.broadcast();
  final calls = <String>[];
  RideRequest? acceptResult;

  @override
  Stream<RideRequest> watch(String id) => rows.stream;

  @override
  Future<RideRequest?> raiseFare(String id, double fare) async {
    calls.add('raise $fare');
    return ride(fare: fare);
  }

  @override
  Future<RideRequest?> acceptOffer(String id, {required String partnerId, required double amount}) async {
    calls.add('accept $partnerId $amount');
    return acceptResult;
  }

  @override
  Future<void> declineOffer(String id, {required String partnerId}) async => calls.add('decline $partnerId');

  @override
  Future<void> withdrawOffer(String id) async => calls.add('withdraw');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('region bidding', () {
    final klBox = jsonEncode({
      'coords': [
        {'latitude': 3.3, 'longitude': 101.5},
        {'latitude': 3.3, 'longitude': 101.8},
        {'latitude': 3.0, 'longitude': 101.8},
        {'latitude': 3.0, 'longitude': 101.5},
      ],
      'bbox': {'north': 3.3, 'south': 3.0, 'east': 101.8, 'west': 101.5},
    });
    final regions = [
      BiddingRegion.fromValues({'country': 'Malaysia'})!,
      BiddingRegion.fromValues({
        'country': 'Malaysia',
        'state': 'Kuala Lumpur',
        'biddingEnabled': false,
        'boundary': klBox,
      })!,
      BiddingRegion.fromValues({'country': 'Malaysia', 'state': 'Penang', 'biddingEnabled': false})!,
    ];
    const kl = LatLng(3.15, 101.7);
    const penang = LatLng(5.4, 100.3);

    test('a containing boundary decides first', () {
      expect(biddingByBoundary(regions, kl), isFalse);
      expect(biddingEnabledAt(regions, kl), isFalse);
      expect(biddingByBoundary(regions, penang), isNull);
    });

    test('names decide when no boundary does; unknown places stay on', () {
      expect(
        biddingEnabledAt(
          regions,
          penang,
          area: const AreaInfo(country: 'malaysia', state: 'Penang'),
        ),
        isFalse,
      );
      expect(
        biddingEnabledAt(
          regions,
          penang,
          area: const AreaInfo(country: 'Malaysia', state: 'Johor'),
        ),
        isTrue,
      );
      expect(biddingEnabledAt(regions, penang), isTrue);
      expect(biddingEnabledAt(regions, null), isTrue);
      expect(BiddingRegion.fromValues({'state': 'x'}), isNull);
    });
  });

  group('fare limits', () {
    test('raises are capped at 4x the quote', () {
      expect(raisedFare(20, 5, quoted: 20), 25);
      expect(raisedFare(78, 5, quoted: 20), 80);
      expect(raisedFare(80, 1, quoted: 20), 80);
    });

    test('counter-offers sit above the fare and below the cap', () {
      expect(counterOfferPresets(20), [24, 26, 30]);
      expect(counterOfferProblem(20, 20), isNotNull);
      expect(counterOfferProblem(21, 20), isNull);
      expect(counterOfferProblem(81, 20), isNotNull);
    });
  });

  group('reading the row', () {
    test('standing offer', () {
      expect(standingOffer(ride(offered: 25, partner: _other))!.amount, 25);
      expect(standingOffer(ride(offered: 25)), isNull);
      expect(standingOffer(ride(status: 'accepted', offered: 25, partner: _other)), isNull);
    });

    test('offer outcomes', () {
      OfferOutcome o(RideRequest r) => offerOutcome(r, me: _me, amount: 25, fareWhenOffered: 20);
      expect(o(ride(offered: 25, partner: _me)), OfferOutcome.pending);
      expect(o(ride(status: 'accepted', fare: 25, partner: _me)), OfferOutcome.won);
      expect(o(ride(status: 'accepted', partner: _other)), OfferOutcome.outbid);
      expect(o(ride(offered: 26, partner: _other)), OfferOutcome.outbid);
      expect(o(ride(fare: 25)), OfferOutcome.raised);
      expect(o(ride()), OfferOutcome.declined);
      expect(o(ride(status: 'cancelled')), OfferOutcome.closed);
    });
  });

  group('rider screen', () {
    Future<_FakeRides> pump(WidgetTester tester, RideRequest first) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => Stream.value(first)),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      await tester.pump();
      await tester.pump();
      return rides;
    }

    testWidgets('accepts a standing offer by partner and amount', (tester) async {
      final rides = await pump(tester, ride(offered: 25, partner: _other, partnerName: 'Ali'));
      expect(find.text('Ali offers RM25.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('accept-offer')));
      await tester.pump();
      expect(rides.calls, ['accept $_other 25.0']);
      expect(find.text('That offer changed before you accepted it.'), findsOneWidget);
    });

    testWidgets('declines an offer and raises the fare', (tester) async {
      final rides = await pump(tester, ride(offered: 25, partner: _other));
      await tester.tap(find.text('Decline'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('raise-5')));
      await tester.pump();
      expect(rides.calls, ['decline $_other', 'raise 25.0']);
    });

    testWidgets('no offer card or raise once accepted', (tester) async {
      await pump(tester, ride(status: 'accepted', partner: _other, partnerName: 'Ali'));
      expect(find.byKey(const ValueKey('ride-offer')), findsNothing);
      expect(find.byKey(const ValueKey('raise-5')), findsNothing);
    });
  });

  group('partner waiting on an offer', () {
    Future<(_FakeRides, Future<RideRequest?>)> pump(WidgetTester tester) async {
      final rides = _FakeRides();
      late Future<RideRequest?> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showDialog<RideRequest>(
                context: context,
                builder: (_) => OfferPendingDialog(
                  repo: rides,
                  ride: ride(),
                  me: _me,
                  amount: 25,
                  window: const Duration(seconds: 3),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      return (rides, result);
    }

    testWidgets('a win closes with the ride', (tester) async {
      final (rides, result) = await pump(tester);
      rides.rows.add(ride(offered: 25, partner: _me));
      await tester.pump();
      expect(find.text('Offer sent'), findsOneWidget);
      rides.rows.add(ride(status: 'accepted', fare: 25, partner: _me));
      await tester.pumpAndSettle();
      expect((await result)!.status, RideStatus.accepted);
    });

    testWidgets('a raise and a timeout are explained; a timeout withdraws', (tester) async {
      var (rides, _) = await pump(tester);
      rides.rows.add(ride(fare: 30));
      await tester.pump();
      expect(find.textContaining('raised the fare to RM30.00'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      (rides, _) = await pump(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('did not answer in time'), findsOneWidget);
      expect(rides.calls, ['withdraw']);
    });
  });
}
