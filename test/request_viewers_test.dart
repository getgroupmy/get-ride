import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

class _Rides implements RideRequestViewersFake {
  _Rides(this.answer);
  RequestViewers answer;
  int asked = 0;
  final viewed = <String>[];

  @override
  Future<RequestViewers> viewers(String requestId) async {
    asked++;
    return answer;
  }

  @override
  Future<void> markViewed(String requestId) async => viewed.add(requestId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

abstract class RideRequestViewersFake implements RideRepository {}

RideRequest _open() => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

void main() {
  group('wording', () {
    test('parses the RPC row, and nothing reads as nobody', () {
      final v = RequestViewers.parse([
        {
          'viewed': 13,
          'viewing': 3,
          'photos': ['a', ' ', 'b', null],
        },
      ]);
      expect((v.viewed, v.viewing), (13, 3));
      expect(v.photos, ['a', 'b']);
      expect(RequestViewers.parse(const []), RequestViewers.none);
      expect(RequestViewers.parse(null).any, isFalse);
      expect(RequestViewers.parse({'viewed': 1, 'viewing': 5}).viewing, 1, reason: 'never more looking than looked');
    });

    test('looking now beats looked, singular and plural', () {
      expect(const RequestViewers(viewed: 13, viewing: 3).label, '3 drivers are viewing your request');
      expect(const RequestViewers(viewed: 1, viewing: 1).label, '1 driver is viewing your request');
      expect(const RequestViewers(viewed: 13).label, '13 drivers viewed your request');
      expect(const RequestViewers(viewed: 1).label, '1 driver viewed your request');
      expect(RequestViewers.none.label, isNull);
    });

    test('four faces at most, the rest as +N', () {
      const v = RequestViewers(viewed: 13, photos: ['a', 'b', 'c', 'd', 'e']);
      final (:faces, :more) = v.faces();
      expect(faces, ['a', 'b', 'c', 'd']);
      expect(more, 9);
      final none = const RequestViewers(viewed: 2, viewing: 2).faces();
      expect(none.faces, isEmpty);
      expect(none.more, 2);
    });
  });

  testWidgets('the bar draws faces and +N, and nothing for nobody', (tester) async {
    Future<void> host(RequestViewers v) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DriversViewingBar(viewers: v)),
      ),
    );
    await host(RequestViewers.none);
    expect(find.byKey(const ValueKey('drivers-viewing')), findsNothing);
    await host(const RequestViewers(viewed: 13, photos: ['https://x/a.png']));
    expect(find.text('13 drivers viewed your request'), findsOneWidget);
    expect(find.text('+12'), findsOneWidget);
  });

  testWidgets('the rider sees who is looking, asked again every few seconds', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var now = DateTime.now();
    final rides = _Rides(const RequestViewers(viewed: 3, viewing: 3));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(rides),
          rideStreamProvider.overrideWith((ref, id) => Stream.value(_open())),
          searchClockProvider.overrideWithValue(() => now),
          riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
        ],
        child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('3 drivers are viewing your request'), findsOneWidget);
    final first = rides.asked;
    rides.answer = const RequestViewers(viewed: 5, viewing: 1);
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(rides.asked, greaterThan(first));
    expect(find.text('1 driver is viewing your request'), findsOneWidget);
  });

  testWidgets("a driver's request sheet says it is being looked at, and keeps saying so", (tester) async {
    final rides = _Rides(RequestViewers.none);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rideRepositoryProvider.overrideWithValue(rides)],
        child: MaterialApp(
          home: Scaffold(
            body: RideRequestSheet(
              request: _open(),
              shown: Duration.zero,
              now: DateTime.now(),
              onAccept: () async {},
              onSkip: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(rides.viewed, ['r1']);
    await tester.pump(requestViewHeartbeat);
    expect(rides.viewed, ['r1', 'r1']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(requestViewHeartbeat * 2);
    expect(rides.viewed, hasLength(2), reason: 'stops once the sheet closes');
  });
}
