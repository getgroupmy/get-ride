import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_checkpoint.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart' show rideStreamProvider;
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

RideRequest ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'me',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.1340,
  'drop_lng': 101.6860,
});

class _FakeRides implements RideRepository {
  final log = <String>[];

  @override
  Future<void> updateStatus(String id, RideStatus status) async => log.add('status:${status.db}');

  @override
  Future<void> complete(RideRequest r) async => log.add('complete');

  @override
  Future<bool> recordCheckpoint(String id, TripCheckpoint checkpoint, double? lat, double? lng) async {
    log.add('${checkpoint.name}:$lat,$lng');
    return true;
  }

  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('checkpointPatch', () {
    test('names the columns for each checkpoint', () {
      expect(checkpointPatch(TripCheckpoint.arrive, 3.1, 101.7), {
        'partner_arrive_lat': 3.1,
        'partner_arrive_lng': 101.7,
      });
      expect(checkpointPatch(TripCheckpoint.drop, -6.2, 106.8), {'partner_drop_lat': -6.2, 'partner_drop_lng': 106.8});
    });

    test('writes nothing without a usable fix', () {
      expect(checkpointPatch(TripCheckpoint.arrive, null, 101.7), isNull);
      expect(checkpointPatch(TripCheckpoint.arrive, 3.1, null), isNull);
      expect(checkpointPatch(TripCheckpoint.drop, double.nan, 101.7), isNull);
      expect(checkpointPatch(TripCheckpoint.drop, 3.1, double.infinity), isNull);
      expect(checkpointPatch(TripCheckpoint.drop, 91, 101.7), isNull);
      expect(checkpointPatch(TripCheckpoint.drop, 3.1, 181), isNull);
    });
  });

  group('trip screen', () {
    Future<(_FakeRides, StreamController<RideRequest>)> pump(WidgetTester tester, {LatLng? fix}) async {
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
            tripFixProvider.overrideWithValue(() async => fix),
            currentUserIdProvider.overrideWithValue(null),
          ],
          child: const MaterialApp(home: PartnerTripScreen(requestId: 'r1')),
        ),
      );
      return (rides, rows);
    }

    testWidgets('arriving stamps the arrive checkpoint after the status', (tester) async {
      final (rides, rows) = await pump(tester, fix: const LatLng(3.158, 101.712));
      rows.add(ride('accepted'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('trip-arrive')));
      await tester.pump();
      await tester.pump();
      expect(rides.log, ['status:arrived', 'arrive:3.158,101.712']);
    });

    testWidgets('completing stamps the drop checkpoint', (tester) async {
      final (rides, rows) = await pump(tester, fix: const LatLng(3.134, 101.686));
      rows.add(ride('on_trip'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('trip-complete')));
      await tester.pump();
      await tester.pump();
      expect(rides.log, containsAll(['complete', 'drop:3.134,101.686']));
    });

    testWidgets('no fix, no checkpoint — the trip still advances', (tester) async {
      final (rides, rows) = await pump(tester);
      rows.add(ride('accepted'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('trip-arrive')));
      await tester.pump();
      await tester.pump();
      expect(rides.log, ['status:arrived']);
    });
  });
}
