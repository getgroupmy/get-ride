import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare_coins.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

RideRequest ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'partner_id': 'driver',
  'partner_name': 'Ali',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
});

class _FakeRides implements RideRepository {
  _FakeRides({this.redeemed = (coinsUsed: 1500.0, coinValue: 15.0)});
  final FareCoinRedemption? redeemed;
  final calls = <String>[];

  @override
  Future<FareCoinRedemption?> redeemFareCoins(RideRequest r) async {
    calls.add('redeem');
    return redeemed;
  }

  @override
  Future<double> claimRideReward(RideRequest r) async {
    calls.add('reward');
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('fareCoinOffer', () {
    test('covers what the balance allows, capped at the fare', () {
      expect(fareCoinOffer(20, 500, 100)?.coinValue, 5);
      expect(fareCoinOffer(20, 500, 100)?.coinsUsed, 500);
      expect(fareCoinOffer(20, 5000, 100)?.coinValue, 20);
      expect(fareCoinOffer(20, 5000, 100)?.coinsUsed, 2000);
    });

    test('no switch without coins or a rate', () {
      expect(fareCoinOffer(20, 0, 100), isNull);
      expect(fareCoinOffer(20, 500, 0), isNull);
    });
  });

  test('fareCoinSubtitle shows worth while off and the saving while on', () {
    expect(fareCoinSubtitle(on: false, fare: 20, coinBalance: 500, coinsPerCurrency: 100), '500 GC ≈ RM5.00');
    expect(
      fareCoinSubtitle(on: true, fare: 20, coinBalance: 500, coinsPerCurrency: 100),
      '−RM5.00 off the fare at drop-off',
    );
    expect(
      fareCoinSubtitle(on: true, fare: 12, coinBalance: 5000, coinsPerCurrency: 100),
      '−RM12.00 off the fare at drop-off',
    );
  });

  test('fareCoinRedemptionFrom reads the RPC result', () {
    expect(fareCoinRedemptionFrom({'coins_used': 1500, 'coin_value': '15.00'}), (coinsUsed: 1500.0, coinValue: 15.0));
    expect(fareCoinRedemptionFrom(null), (coinsUsed: 0.0, coinValue: 0.0));
  });

  group('redeemChosenFareCoins', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('only for rides booked with coins, and only once completed', () async {
      final store = FareCoinChoiceStore();
      final rides = _FakeRides();
      expect(await redeemChosenFareCoins(rides, store, ride('completed')), isNull);
      expect(rides.calls, isEmpty);

      await store.choose('r1');
      expect(await redeemChosenFareCoins(rides, store, ride('on_trip')), isNull);
      expect(rides.calls, isEmpty);

      expect(await redeemChosenFareCoins(rides, store, ride('completed')), (coinsUsed: 1500.0, coinValue: 15.0));
      expect(await store.chosen('r1'), isFalse, reason: 'settled, so not asked again');
    });

    test('a failed call keeps the choice for the next visit', () async {
      final store = FareCoinChoiceStore();
      await store.choose('r1');
      expect(await redeemChosenFareCoins(_FakeRides(redeemed: null), store, ride('completed')), isNull);
      expect(await store.chosen('r1'), isTrue);
    });
  });

  testWidgets('tracking screen applies the coins at drop-off alongside the reward', (tester) async {
    SharedPreferences.setMockInitialValues({'fare_coins_r1': true});
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rides = _FakeRides();
    final rows = StreamController<RideRequest>();
    addTearDown(rows.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(rides),
          rideStreamProvider.overrideWith((ref, id) => rows.stream),
          walletBalancesProvider.overrideWith((ref) async => const []),
          walletTxProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
      ),
    );
    rows.add(ride('on_trip'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('coins-pending')), findsOneWidget);
    expect(rides.calls, isEmpty);

    rows.add(ride('completed'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(rides.calls, unorderedEquals(['redeem', 'reward']));
    expect(find.text('RM15.00 paid with GET.coin'), findsOneWidget);
    expect(find.byKey(const ValueKey('coins-pending')), findsNothing);
  });
}
