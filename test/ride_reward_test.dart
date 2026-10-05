import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';

RideRequest ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'partner_id': 'driver',
  'partner_name': 'Ali',
  'status': status,
  'fare': 20,
  'ride_fare': 22.5,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
});

class _FakeRides implements RideRepository {
  _FakeRides(this.reward);
  final double reward;
  final claims = <String>[];

  @override
  Future<double> claimRideReward(RideRequest r) async {
    claims.add(r.status.db);
    return r.status == RideStatus.completed ? reward : 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<(_FakeRides, StreamController<RideRequest>)> pump(WidgetTester tester, double reward) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rides = _FakeRides(reward);
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
    return (rides, rows);
  }

  testWidgets('the reward is claimed once when the trip completes and shown', (tester) async {
    final (rides, rows) = await pump(tester, 225);
    rows.add(ride('on_trip'));
    await tester.pump();
    await tester.pump();
    expect(rides.claims, isEmpty);
    expect(find.byKey(const ValueKey('ride-reward')), findsNothing);

    rows.add(ride('completed'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(rides.claims, ['completed']);
    expect(find.text('You earned 225 GC'), findsOneWidget);

    rows.add(ride('completed'));
    await tester.pump();
    await tester.pump();
    expect(rides.claims, ['completed'], reason: 'claimed once per screen');
  });

  testWidgets('nothing is shown when no coins were earned', (tester) async {
    final (rides, rows) = await pump(tester, 0);
    rows.add(ride('completed'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(rides.claims, ['completed']);
    expect(find.byKey(const ValueKey('ride-reward')), findsNothing);
  });
}
