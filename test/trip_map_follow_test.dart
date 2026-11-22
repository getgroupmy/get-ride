// The trip maps, a frame at a time (features/ride/live_ride_map.dart).
//
// A car is driven down a road here and the real map watched as it goes: on the
// passenger's phone, which hears where the car is every five seconds, and on
// the driver's own, which has the phone's GPS. Each frame the car as drawn and
// the camera are checked against where the car really is.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/follow_motion.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/live_fix.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_live_fix_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'support/trip_road.dart';

void main() {
  group("the passenger's map", () {
    late Road road;
    late RoadGeo geo;
    late DateTime clock;

    setUp(() {
      road = Road();
      geo = RoadGeo(road);
      clock = t0;
    });

    Future<void> show(WidgetTester tester, RideRequest r) => tester.pumpWidget(
      ProviderScope(
        overrides: [geoServiceProvider.overrideWithValue(geo)],
        child: MaterialApp(home: Scaffold(body: LiveRideMap(ride: r, now: () => clock))),
      ),
    );

    /// Drives the real car at [speed] for [seconds], its position sent every
    /// [every] seconds and heard [late] after, and returns what each frame
    /// showed. [hand] is run once, at that many seconds in.
    Future<List<Seen>> drive(
      WidgetTester tester, {
      double speed = 14,
      double seconds = 45,
      double every = 5,
      double late = 0.2,
      double? stopAt,
      (double, Future<void> Function())? hand,
    }) async {
      final seen = <Seen>[];
      var sentCount = 0;
      var handed = false;
      double realAt(double t) => speed * (stopAt == null ? t : math.min(t, stopAt));
      for (var f = 0; f * frameSeconds <= seconds; f++) {
        final t = f * frameSeconds;
        clock = t0.add(Duration(microseconds: (t * 1e6).round()));
        if (t >= sentCount * every + late) {
          final sentAt = sentCount * every;
          // Nothing is sent from a car that has stopped (its phone reports
          // only when it has moved).
          if (stopAt == null || sentAt <= stopAt + every) {
            final spot = road.spot(realAt(sentAt));
            await show(
              tester,
              ride(road, car: spot.at, heading: spot.bearing, sent: t0.add(Duration(microseconds: (sentAt * 1e6).round()))),
            );
          }
          sentCount++;
        }
        if (hand != null && !handed && t >= hand.$1) {
          handed = true;
          await hand.$2();
        }
        await tester.pump(frame);
        // Nothing is on screen until the car is first heard from.
        if (find.byType(RideMap).evaluate().isEmpty) continue;
        final car = rideMap(tester).driverLive!.value;
        if (car == null) continue;
        final line = rideMap(tester).route;
        seen.add((t: t, car: car, camera: cameraOf(tester), lineStart: line.isEmpty ? null : line.first, real: realAt(t)));
      }
      return seen;
    }

    testWidgets('the car drives the road, bend and all, and the camera stays on it', (tester) async {
      const speed = 14.0;
      final seen = await drive(tester, speed: speed);
      expect(seen.length, greaterThan(2000));
      LatLng? was;
      for (final s in seen.where((s) => s.t > 11)) {
        final where = 'at ${s.t.toStringAsFixed(2)} s';
        expect(road.offBy(s.car.at), lessThan(0.5), reason: 'on the road $where');
        // Never standing, never leaping: about the speed the car is driving.
        if (was != null) {
          expect(metresApart(was, s.car.at) / frameSeconds, inInclusiveRange(speed * 0.8, speed * 1.25), reason: where);
        }
        was = s.car.at;
        // A position and a little behind the real car, and no further.
        expect((s.real - road.along(s.car.at)) / speed, inInclusiveRange(4.9, 6.4), reason: where);
        // The camera is on the car, north up, at street zoom.
        expect(metresApart(s.camera.center, s.car.at), lessThan(0.2), reason: 'the camera $where');
        expect(s.camera.rotation, 0);
        expect(s.camera.zoom, followZoom);
      }
      expect(geo.asked, greaterThan(2), reason: 'routed again as the car moved: the road was handed on');
    });

    testWidgets('it faces the way it is driving, turning with the bend', (tester) async {
      final seen = await drive(tester);
      double? was;
      for (final s in seen.where((s) => s.t > 11)) {
        final heading = s.car.heading!;
        if (was != null) expect(shortestTurn(was, heading).abs(), lessThan(followMaxTurnPerSecond * frameSeconds + 1e-6));
        was = heading;
        // The road's own direction where the car is drawn, give or take the
        // ease round the bend.
        final runs = road.spot(road.along(s.car.at)).bearing;
        expect(shortestTurn(heading, runs).abs(), lessThan(25), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
      expect(shortestTurn(seen.firstWhere((s) => road.along(s.car.at) > 200).car.heading!, 0).abs(), lessThan(1));
      expect(shortestTurn(seen.last.car.heading!, 90).abs(), lessThan(1));
    });

    testWidgets('the road line starts at the car, not ahead of it', (tester) async {
      final seen = await drive(tester);
      for (final s in seen.where((s) => s.t > 6 && s.lineStart != null)) {
        expect(
          metresApart(s.lineStart!, s.car.at),
          lessThan(carLineStepMetres + 1),
          reason: 'the line and the car at ${s.t.toStringAsFixed(2)} s',
        );
      }
    });

    testWidgets('a car that pulls up is drawn pulling up there, and the frames stop', (tester) async {
      final seen = await drive(tester, speed: 12, stopAt: 20, seconds: 40);
      final stop = road.at(12 * 20);
      expect(metresApart(seen.last.car.at, stop), lessThan(0.1));
      expect(metresApart(seen.last.camera.center, stop), lessThan(0.2));
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'nothing left to move');
      // And it never went past where the car stopped.
      for (final s in seen) {
        expect(road.along(s.car.at), lessThan(12 * 20 + 0.1));
      }
    });

    testWidgets('a hand on the map lets the camera go while the car drives on; left alone, or on recenter, it comes back', (
      tester,
    ) async {
      final seen = await drive(
        tester,
        seconds: 30,
        hand: (
          9,
          () async {
            await tester.drag(find.byType(FlutterMap), const Offset(120, 60));
            await tester.pump();
          },
        ),
      );
      // Once the map has come to rest from the hand's own push, and until it
      // has been left alone long enough ([followResumeAfter]).
      final let = seen.where((s) => s.t > 11 && s.t < 18.5).toList();
      for (final s in let) {
        expect(metresApart(s.camera.center, let.last.camera.center), lessThan(0.01), reason: 'left where the hand put it');
      }
      expect(metresApart(let.first.car.at, let.last.car.at), greaterThan(80), reason: 'the car went on');
      expect(metresApart(let.last.camera.center, let.last.car.at), greaterThan(60), reason: 'without the camera');
      // Ten seconds on, the next position heard brings the camera back by itself.
      expect(metresApart(seen.last.camera.center, seen.last.car.at), lessThan(0.2));
      // And so does the button, at once.
      await tester.drag(find.byType(FlutterMap), const Offset(-150, 40));
      await tester.pump();
      expect(metresApart(cameraOf(tester).center, rideMap(tester).driverLive!.value!.at), greaterThan(60));
      await tester.tap(find.byTooltip('Follow the car'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(metresApart(cameraOf(tester).center, rideMap(tester).driverLive!.value!.at), lessThan(0.2));
    });

    testWidgets('a position far from the last is where the car is, at once', (tester) async {
      await show(tester, ride(road, car: road.at(0), sent: t0));
      await tester.pump(const Duration(seconds: 2));
      clock = t0.add(const Duration(seconds: 5));
      final far = movedAlong(origin, 3000, 200);
      await show(tester, ride(road, car: far, sent: clock));
      await tester.pump();
      expect(rideMap(tester).driverLive!.value!.at, far);
      await tester.pump(const Duration(seconds: 1));
      expect(metresApart(cameraOf(tester).center, far), lessThan(0.2));
    });

    testWidgets('no car any more, none on the map', (tester) async {
      await show(tester, ride(road, car: road.at(0), sent: t0));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('driver-car')), findsOneWidget);
      await show(tester, ride(road, car: road.at(0), sent: t0, status: 'cancelled'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('driver-car')), findsNothing);
      expect(rideMap(tester).driverLive!.value, isNull);
    });
  });

  group("the driver's own map", () {
    late Road road;
    late DateTime clock;
    late StreamController<LiveFix> fixes;
    LatLng? handedDown;
    double? handedHeading;

    setUp(() {
      road = Road();
      clock = t0;
      fixes = StreamController<LiveFix>();
      handedDown = handedHeading = null;
      // Not waited for: a stream nobody listened to never finishes closing.
      addTearDown(() => unawaited(fixes.close()));
    });

    Future<void> show(WidgetTester tester, {bool own = true, String status = 'on_trip'}) => tester.pumpWidget(
      ProviderScope(
        overrides: [geoServiceProvider.overrideWithValue(RoadGeo(road))],
        child: MaterialApp(
          home: Scaffold(
            body: LiveRideMap(
              ride: ride(road, status: status),
              partner: true,
              driverAt: handedDown,
              driverHeading: handedHeading,
              driverFixes: own ? () => fixes.stream : null,
              now: () => clock,
            ),
          ),
        ),
      ),
    );

    /// Drives the car at [speed] for [seconds], its phone giving a fix a
    /// second: to the map itself when [own], and handed down by the screen
    /// ([LiveRideMap.driverAt]) every [handEvery] of them, [handLag] metres
    /// behind.
    Future<List<Seen>> drive(
      WidgetTester tester, {
      double speed = 10,
      double seconds = 70,
      bool own = true,
      int handEvery = 2,
      double handLag = 0,
    }) async {
      final seen = <Seen>[];
      var fixed = 0;
      await show(tester, own: own);
      for (var f = 0; f * frameSeconds <= seconds; f++) {
        final t = f * frameSeconds;
        clock = t0.add(Duration(microseconds: (t * 1e6).round()));
        if (t >= fixed) {
          final spot = road.spot(speed * fixed);
          if (own) fixes.add((at: spot.at, speed: speed, course: spot.bearing, time: clock, accuracy: 5));
          if (fixed % handEvery == 0) {
            final behind = road.spot(math.max(0, speed * fixed - handLag));
            handedDown = behind.at;
            handedHeading = behind.bearing;
            await show(tester, own: own);
          }
          fixed++;
        }
        await tester.pump(frame);
        final car = rideMap(tester).driverLive!.value;
        if (car == null) continue;
        seen.add((t: t, car: car, camera: cameraOf(tester), lineStart: null, real: speed * t));
      }
      return seen;
    }

    testWidgets('the car is where the phone is, every frame, and the map turned to the way it is going', (tester) async {
      const speed = 10.0;
      final seen = await drive(tester, speed: speed);
      LatLng? was;
      double? turned;
      for (final s in seen.where((s) => s.t > 4)) {
        final where = 'at ${s.t.toStringAsFixed(2)} s';
        // Round the bend the car is carried straight on for the moment until
        // the next fix says otherwise: within a couple of metres there, and
        // within one on the straight.
        final bend = s.real > 380 && s.real < 500;
        expect(metresApart(s.car.at, road.at(s.real)), lessThan(bend ? 3.0 : 1.0), reason: 'the car $where');
        if (was != null) expect(metresApart(was, s.car.at), greaterThan(0), reason: 'moving every frame, $where');
        was = s.car.at;
        // Held in the lower part of the map, with the road ahead above it.
        final onScreen = s.camera.latLngToScreenOffset(s.car.at);
        expect((onScreen - const Offset(400, 390)).distance, lessThan(1.5), reason: 'on screen $where');
        expect(s.camera.zoom, followZoom);
        // The map turns steadily, never in a lurch.
        if (turned != null) {
          expect(shortestTurn(turned, s.camera.rotation).abs(), lessThan(followMaxTurnPerSecond * frameSeconds + 1e-6));
        }
        turned = s.camera.rotation;
      }
      expect(shortestTurn(seen.firstWhere((s) => s.real > 200).camera.rotation, 0).abs(), lessThan(1), reason: 'north up');
      expect(shortestTurn(seen.last.camera.rotation, -90).abs(), lessThan(1), reason: 'east up after the bend');
      expect(shortestTurn(seen.last.car.heading!, 90).abs(), lessThan(1));
    });

    testWidgets("the phone's own fixes are followed, not the position handed down after them", (tester) async {
      // Handed down every third fix, 15 m behind: what the screen keeps for
      // the distance driven and the passenger.
      final seen = await drive(tester, seconds: 30, handEvery: 3, handLag: 15);
      for (final s in seen.where((s) => s.t > 4)) {
        expect(metresApart(s.car.at, road.at(s.real)), lessThan(1.0), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
    });

    testWidgets('with no fixes of its own to follow, the map follows the position handed down', (tester) async {
      const speed = 10.0;
      final seen = await drive(tester, speed: speed, seconds: 30, own: false, handEvery: 1);
      LatLng? was;
      for (final s in seen.where((s) => s.t > 4)) {
        expect(metresApart(s.car.at, road.at(s.real)), lessThan(1.5), reason: 'at ${s.t.toStringAsFixed(2)} s');
        if (was != null) expect(metresApart(was, s.car.at), greaterThan(0));
        was = s.car.at;
      }
    });

    /// A second of frames, the clock moving with them.
    Future<void> second(WidgetTester tester) async {
      for (var f = 0; f < 60; f++) {
        clock = clock.add(frame);
        await tester.pump(frame);
      }
    }

    testWidgets("the car is on the map from the phone's first fix, before the screen has handed one down", (tester) async {
      await show(tester);
      expect(rideMap(tester).driverLive!.value, isNull);
      for (var i = 0; i < 4; i++) {
        fixes.add((at: road.at(10.0 * i), speed: 10, course: 0, time: clock, accuracy: 5));
        await second(tester);
        // Rebuilt meanwhile, as the screen does for every row of the ride.
        await show(tester);
      }
      expect(find.byKey(const ValueKey('driver-car')), findsOneWidget);
      final car = rideMap(tester).driverLive!.value!.at;
      expect(metresApart(car, road.at(40)), lessThan(1.5));
      expect(metresApart(cameraOf(tester).center, car), lessThan(200), reason: 'and the camera has come to it');
      expect(cameraOf(tester).zoom, followZoom);
    });

    testWidgets("if the phone's own fixes stop coming, the position handed down is followed again", (tester) async {
      await show(tester);
      for (var i = 0; i < 4; i++) {
        fixes.add((at: road.at(10.0 * i), speed: 10, course: 0, time: clock, accuracy: 5));
        handedDown = road.at(10.0 * i);
        handedHeading = 0;
        await show(tester);
        await second(tester);
      }
      // Nothing more from the phone's own stream; the screen goes on handing
      // positions down.
      for (var i = 4; i < 16; i++) {
        handedDown = road.at(10.0 * i);
        await show(tester);
        await second(tester);
      }
      expect(metresApart(rideMap(tester).driverLive!.value!.at, road.at(160)), lessThan(12), reason: 'not left behind');
    });

    testWidgets('a cancelled ride has no car, whatever the phone goes on saying', (tester) async {
      await show(tester);
      fixes.add((at: road.at(0), speed: 10, course: 0, time: clock, accuracy: 5));
      await second(tester);
      expect(find.byKey(const ValueKey('driver-car')), findsOneWidget);
      await show(tester, status: 'cancelled');
      await second(tester);
      fixes.add((at: road.at(20), speed: 10, course: 0, time: clock, accuracy: 5));
      await second(tester);
      expect(find.byKey(const ValueKey('driver-car')), findsNothing);
      expect(rideMap(tester).driverLive!.value, isNull);
    });

    testWidgets('stopped, the car and the map stay facing the way they were', (tester) async {
      await show(tester);
      for (var i = 0; i < 6; i++) {
        clock = t0.add(Duration(seconds: i));
        fixes.add((at: movedAlong(origin, 10.0 * i, 90), speed: 10, course: 90, time: clock, accuracy: 5));
        for (var f = 0; f < 60; f++) {
          await tester.pump(frame);
        }
      }
      expect(shortestTurn(cameraOf(tester).rotation, -90).abs(), lessThan(1));
      // Pulled up: the GPS gives no course worth the name, and none at all.
      final at = movedAlong(origin, 56, 90);
      for (var i = 6; i < 12; i++) {
        clock = t0.add(Duration(seconds: i));
        fixes.add((at: at, speed: 0, course: i.isEven ? 200 : null, time: clock, accuracy: 5));
        for (var f = 0; f < 60; f++) {
          await tester.pump(frame);
        }
      }
      expect(shortestTurn(cameraOf(tester).rotation, -90).abs(), lessThan(1), reason: 'not swung round to north, or to noise');
      expect(shortestTurn(rideMap(tester).driverLive!.value!.heading!, 90).abs(), lessThan(1));
      expect(metresApart(rideMap(tester).driverLive!.value!.at, at), lessThan(1));
    });
  });

  group('the trip screen', () {
    late Road road;
    late DateTime now;
    late StreamController<RideRequest> rows;
    late StreamController<TripFix> trip;
    late StreamController<LiveFix> own, live;
    late _Rides rides;
    late _LiveFixes sent;

    setUp(() {
      road = Road();
      now = t0;
      rows = StreamController<RideRequest>();
      trip = StreamController<TripFix>();
      own = StreamController<LiveFix>();
      live = StreamController<LiveFix>();
      rides = _Rides();
      sent = _LiveFixes();
      // Not waited for: a stream nobody listened to never finishes closing.
      addTearDown(() {
        unawaited(rows.close());
        unawaited(trip.close());
        unawaited(own.close());
        unawaited(live.close());
      });
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/trip',
        routes: [
          GoRoute(path: '/drive', builder: (_, _) => const Scaffold(body: Text('requests'))),
          GoRoute(path: '/trip', builder: (_, _) => const PartnerTripScreen(requestId: 'r1')),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideLiveFixRepositoryProvider.overrideWithValue(sent),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            tripPositionStreamProvider.overrideWithValue(() => trip.stream),
            tripMapFixesProvider.overrideWithValue(() => own.stream),
            tripLiveFixesProvider.overrideWithValue(() => live.stream),
            tripClockProvider.overrideWithValue(() => now),
            tripFixProvider.overrideWithValue(() async => null),
            geoServiceProvider.overrideWithValue(RoadGeo(road)),
            currentUserIdProvider.overrideWithValue(null),
            fareTariffsProvider.overrideWith((ref) async => const []),
            rideServicesProvider.overrideWith((ref) async => const []),
            serviceBoxNamesProvider.overrideWith((ref) async => const {}),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
    }

    testWidgets("its map follows the phone's every fix; the distance driven and what is shared keep their own pace", (
      tester,
    ) async {
      await open(tester);
      rows.add(ride(road, status: 'on_trip'));
      await tester.pump();
      await tester.pump();
      // The trip's own stream gives its first fix, then nothing for a while
      // (the car has not gone its fifteen metres yet)…
      trip.add((at: road.at(0), heading: 0, accuracy: 5));
      await tester.pump();
      // …while the phone goes on giving one a second.
      LatLng? was;
      for (var second = 0; second < 6; second++) {
        now = t0.add(Duration(seconds: second));
        own.add((at: road.at(2.0 * second), speed: 2, course: 0, time: now, accuracy: 5));
        for (var f = 0; f < 60; f++) {
          await tester.pump(frame);
          final car = rideMap(tester).driverLive!.value!.at;
          if (second >= 2 && was != null) expect(metresApart(was, car), greaterThan(0), reason: 'the car moves every frame');
          was = car;
        }
      }
      expect(metresApart(was!, road.at(2.0 * 6)), lessThan(1.5));
      expect(find.text('0.0 km driven'), findsOneWidget, reason: "counted from the trip's own fixes alone");
      expect(rides.shared, 1, reason: "shared at the trip's own pace");
      await close(tester);
    });

    LiveFix fixAt(int second) =>
        (at: road.at(12.0 * second), speed: 12, course: 0, time: t0.add(Duration(seconds: second)), accuracy: 5);

    testWidgets("every fix goes to the passenger's map, one a second, while the ride is under way", (tester) async {
      await open(tester);
      rows.add(ride(road, status: 'accepted'));
      await tester.pump();
      await tester.pump();
      expect(live.hasListener, isFalse, reason: 'not before location is known to be allowed: the first fix of the trip');
      trip.add((at: road.at(0), heading: 0, accuracy: 5));
      await tester.pump();
      expect(live.hasListener, isTrue);
      // On the way to the pickup, waiting there, and on the trip: a fix a
      // second, each sent as it comes.
      var second = 0;
      for (final status in ['accepted', 'arrived', 'on_trip']) {
        rows.add(ride(road, status: status));
        await tester.pump();
        for (var k = 0; k < 4; k++, second++) {
          now = t0.add(Duration(seconds: second));
          live.add(fixAt(second));
          await tester.pump(const Duration(seconds: 1));
        }
      }
      expect(sent.rides.toSet(), {'r1'});
      expect(sent.fixes, [for (var k = 0; k < 12; k++) fixAt(k)], reason: 'every one, in order, none twice');
      expect(rides.shared, lessThanOrEqualTo(1), reason: 'the ride row keeps its own pace: it is shared from the trip\'s 15 m fixes');
      // The trip is over: nothing more is sent, whatever the phone goes on giving.
      rows.add(ride(road, status: 'completed'));
      await tester.pump();
      for (var k = 0; k < 3; k++, second++) {
        live.add(fixAt(second));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(sent.fixes.length, 12);
      await close(tester);
      expect(live.hasListener, isFalse, reason: 'let go of with the screen');
    });

    testWidgets('a server that has nowhere to take them is asked once; the ride row is shared as it always was', (tester) async {
      sent.answer = (_) => throw const PostgrestException(message: 'Could not find the function public.ride_live_fix', code: 'PGRST202');
      await open(tester);
      rows.add(ride(road, status: 'on_trip'));
      await tester.pump();
      await tester.pump();
      trip.add((at: road.at(0), heading: 0, accuracy: 5));
      await tester.pump();
      for (var second = 0; second < 12; second++) {
        now = t0.add(Duration(seconds: second));
        live.add(fixAt(second));
        // The trip's own stream, every fifteen metres or so.
        trip.add((at: road.at(12.0 * second), heading: 0, accuracy: 5));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(sent.asked, 1);
      expect(rides.shared, 3, reason: 'at 0, 5 and 10 s');
      await close(tester);
    });

    testWidgets('on a slow connection the fixes do not pile up: one on its way, and then the newest', (tester) async {
      final answers = <Completer<bool>>[];
      sent.answer = (_) {
        final c = Completer<bool>();
        answers.add(c);
        return c.future;
      };
      await open(tester);
      rows.add(ride(road, status: 'on_trip'));
      await tester.pump();
      await tester.pump();
      trip.add((at: road.at(0), heading: 0, accuracy: 5));
      await tester.pump();
      for (var second = 0; second < 4; second++) {
        live.add(fixAt(second));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(sent.asked, 1, reason: 'the first has not been answered');
      answers.single.complete(true);
      await tester.pump();
      await tester.pump();
      expect(sent.fixes, [fixAt(0), fixAt(3)]);
      answers.last.complete(true);
      await close(tester);
    });

    testWidgets('a ride that takes none (it has passed to another driver) is left alone for a while', (tester) async {
      sent.answer = (_) async => false;
      await open(tester);
      rows.add(ride(road, status: 'on_trip'));
      await tester.pump();
      await tester.pump();
      trip.add((at: road.at(0), heading: 0, accuracy: 5));
      await tester.pump();
      for (var second = 0; second < 10; second++) {
        live.add(fixAt(second));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(sent.asked, 1);
      await close(tester);
    });
  });
}

class _Rides implements RideRepository {
  int shared = 0;

  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async => shared++;

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What the trip screen sent to the passenger's map.
class _LiveFixes implements RideLiveFixRepository {
  final rides = <String>[];
  final fixes = <LiveFix>[];
  int asked = 0;
  FutureOr<bool> Function(LiveFix fix)? answer;

  @override
  Future<bool> send(String rideId, LiveFix fix) async {
    asked++;
    rides.add(rideId);
    fixes.add(fix);
    final answer = this.answer;
    return answer == null ? true : await answer(fix);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
