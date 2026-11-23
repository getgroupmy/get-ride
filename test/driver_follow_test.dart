// How the driver's map follows them (driver_home_map.dart), measured the way a
// driver sees it: a car is driven along a road, the phone gives a fix a second
// as a real GPS does, and after every frame the dot is compared with where the
// car truly is. The dot must keep up, never stop while the car moves, never
// jump, stay on the road through a bend, and come to rest where the car does.
import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/compass.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/driver_home_map.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const origin = LatLng(3.1579, 101.7116);
final clock0 = DateTime.utc(2026, 11, 19, 8);

/// 50 frames a second.
const frame = Duration(milliseconds: 20);
const frameSeconds = 0.02;

class _FakeRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Where the car truly is at a moment: its place, speed (m/s) and course.
typedef Truth = ({LatLng at, double speed, double course});

/// A point [east] and [north] metres from [origin].
LatLng at(double east, double north) => movedAlong(movedAlong(origin, north, 0), east, 90);

/// [p] as metres east and north of [origin].
({double east, double north}) local(LatLng p) {
  final d = metresApart(origin, p);
  final b = bearingBetween(origin, p) * math.pi / 180;
  return (east: d * math.sin(b), north: d * math.cos(b));
}

Position _position({
  double speed = 0,
  double heading = 0,
  bool hasSpeed = true,
  bool hasHeading = true,
  double headingAccuracy = 0,
  bool hasHeadingAccuracy = false,
}) => Position(
  latitude: origin.latitude,
  longitude: origin.longitude,
  timestamp: clock0,
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: heading,
  headingAccuracy: headingAccuracy,
  speed: speed,
  speedAccuracy: 0,
  hasSpeed: hasSpeed,
  hasHeading: hasHeading,
  hasHeadingAccuracy: hasHeadingAccuracy,
);

void main() {
  group('the arithmetic', () {
    test('easeFraction: the same ease whatever the frame rate', () {
      expect(easeFraction(0, 0.25), 0);
      expect(easeFraction(0.25, 0.25), closeTo(1 - 1 / math.e, 1e-9), reason: '63% of the gap every time constant');
      // Two 8 ms frames close exactly as much as one 16 ms frame.
      final two = 1 - (1 - easeFraction(0.008, 0.25)) * (1 - easeFraction(0.008, 0.25));
      expect(two, closeTo(easeFraction(0.016, 0.25), 1e-12));
      expect(easeFraction(0.016, 0), 1, reason: 'no ease: there at once');
    });

    test('shortestTurn: the short way round, across north', () {
      expect(shortestTurn(350, 10), 20);
      expect(shortestTurn(10, 350), -20);
      expect(shortestTurn(0, 90), 90);
      expect(shortestTurn(0, 270), -90);
      expect(shortestTurn(-359, 1), 0);
      expect(shortestTurn(0, 181), -179);
    });

    test('metresApart, bearingBetween and movedAlong agree with each other', () {
      const from = LatLng(3.15, 101.71);
      for (final bearing in [0.0, 37.0, 90.0, 180.0, 271.5]) {
        final to = movedAlong(from, 25, bearing);
        expect(metresApart(from, to), closeTo(25, 0.01), reason: '25 m along $bearing°');
        expect(bearingBetween(from, to), closeTo(bearing, 0.05));
      }
      // 0.0001° of latitude is about 11.1 m.
      expect(metresApart(from, const LatLng(3.1501, 101.71)), closeTo(11.13, 0.05));
      expect(metresApart(from, from), 0);
      expect(pointBetween(from, const LatLng(3.16, 101.72), 0.5).latitude, closeTo(3.155, 1e-12));
    });

    test('carryWeight: nothing while as good as stopped, everything once moving', () {
      expect(carryWeight(0), 0);
      expect(carryWeight(followCarryFrom), 0);
      expect(carryWeight((followCarryFrom + followCarryFully) / 2), closeTo(0.5, 1e-12));
      expect(carryWeight(followCarryFully), 1);
      expect(carryWeight(30), 1);
    });

    test('deadReckon: the fix carried forward along its course for its age', () {
      const fix = LatLng(3.15, 101.71);
      final onward = deadReckon(fix, speedMps: 10, courseDegrees: 90, ageSeconds: 1);
      expect(metresApart(fix, onward), closeTo(10, 0.01));
      expect(bearingBetween(fix, onward), closeTo(90, 0.05));
      // Nowhere to carry it: no course, standing still, or no time gone.
      expect(deadReckon(fix, speedMps: 10, courseDegrees: null, ageSeconds: 1), fix);
      expect(deadReckon(fix, speedMps: 0.3, courseDegrees: 90, ageSeconds: 1), fix);
      expect(deadReckon(fix, speedMps: 10, courseDegrees: 90, ageSeconds: 0), fix);
      // A lost signal does not send it down the road for ever.
      final coasted = deadReckon(fix, speedMps: 10, courseDegrees: 90, ageSeconds: 60);
      expect(metresApart(fix, coasted), closeTo(10 * followCoastSeconds, 0.01));
    });

    test('deadReckon: speeding up and braking are carried too, and a braking car stops', () {
      const fix = LatLng(3.15, 101.71);
      // Pulling away at 2 m/s²: 5 m/s for a second covers 5 + 1 = 6 m.
      final faster = deadReckon(fix, speedMps: 5, courseDegrees: 0, ageSeconds: 1, accelMps2: 2);
      expect(metresApart(fix, faster), closeTo(6, 0.01));
      // Braking at 2.5 m/s² from 2.5 m/s: stopped after a second, 1.25 m on — and
      // no further, however long the next fix takes.
      final stopping = deadReckon(fix, speedMps: 2.5, courseDegrees: 0, ageSeconds: 1, accelMps2: -2.5);
      expect(metresApart(fix, stopping), closeTo(1.25, 0.01));
      final later = deadReckon(fix, speedMps: 2.5, courseDegrees: 0, ageSeconds: 1.9, accelMps2: -2.5);
      expect(metresApart(fix, later), closeTo(1.25, 0.01), reason: 'it does not roll back, or on');
    });

    test('headingBetween: one fix\'s course to the next, steadily, and no further', () {
      // A second between fixes, turning from 0° to 30°.
      expect(headingBetween(0, 30, ageSeconds: 0, overSeconds: 1), 0);
      expect(headingBetween(0, 30, ageSeconds: 0.5, overSeconds: 1), closeTo(15, 1e-9));
      expect(headingBetween(0, 30, ageSeconds: 1, overSeconds: 1), closeTo(30, 1e-9));
      expect(headingBetween(0, 30, ageSeconds: 5, overSeconds: 1), closeTo(30, 1e-9), reason: 'a late fix: held, not carried on round');
      // The short way, across north.
      expect(headingBetween(350, 20, ageSeconds: 0.5, overSeconds: 1), closeTo(5, 1e-9));
      expect(headingBetween(20, 350, ageSeconds: 0.5, overSeconds: 1), closeTo(5, 1e-9));
      expect(headingBetween(10, 350, ageSeconds: 1, overSeconds: 1), closeTo(350, 1e-9));
      expect(headingBetween(90, 120, ageSeconds: 0.5, overSeconds: 0), closeTo(120, 1e-9), reason: 'no time to spread it over');
    });

    test('turnStep: eased, and no faster than a sweep', () {
      expect(turnStep(0, 0.016), 0);
      expect(turnStep(10, 0.016), closeTo(10 * easeFraction(0.016, followTurnSeconds), 1e-12));
      expect(turnStep(-10, 0.016), closeTo(-10 * easeFraction(0.016, followTurnSeconds), 1e-12));
      // Half a turn to make: paced, not flung round.
      expect(turnStep(180, 0.016), closeTo(followMaxTurnPerSecond * 0.016, 1e-12));
      expect(turnStep(-180, 0.016), closeTo(-followMaxTurnPerSecond * 0.016, 1e-12));
      expect(turnStep(90, 0), 0, reason: 'no time, no turn');
    });

    test('settledFix: a parked car\'s fixes are the same spot measured again', () {
      const dot = LatLng(3.15, 101.71);
      LatLng off(double metres) => movedAlong(dot, metres, 40);
      // Moving: the fix, whatever it is.
      expect(settledFix(dot, off(0.4), speedMps: 8, accuracyMetres: 5), off(0.4));
      expect(settledFix(dot, off(0.4), speedMps: followCarryFrom + 0.1, accuracyMetres: 5), off(0.4));
      // Nothing drawn yet: the fix.
      expect(settledFix(null, off(0.4), speedMps: 0, accuracyMetres: 5), off(0.4));
      // Standing still, a fix a step away: the dot does not move at all.
      expect(settledFix(dot, off(0.4), speedMps: 0, accuracyMetres: 5), dot);
      expect(settledFix(dot, off(followRestStill - 0.01), speedMps: 0.2, accuracyMetres: 5), dot);
      // A little further: a fifth of the way, so it settles on the middle of them.
      final drift = settledFix(dot, off(2), speedMps: 0, accuracyMetres: 5);
      expect(metresApart(dot, drift), closeTo(2 * followRestShare, 0.01));
      // Somewhere else — outside the fix's own accuracy: taken as it comes.
      expect(settledFix(dot, off(30), speedMps: 0, accuracyMetres: 5), off(30));
      expect(settledFix(dot, off(4), speedMps: 0, accuracyMetres: null), off(4), reason: 'no accuracy: 3 m at the least');
      expect(settledFix(dot, off(4), speedMps: 0, accuracyMetres: 1), off(4));
      // A loose fix that agrees with the dot does not drag it about...
      expect(metresApart(dot, settledFix(dot, off(30), speedMps: 0, accuracyMetres: 65)), closeTo(6, 0.05));
      // ...nor one that cannot say whether the car is moving (no GPS: Wi-Fi, cell towers).
      expect(metresApart(dot, settledFix(dot, off(30), speedMps: null, accuracyMetres: 65)), closeTo(6, 0.05));
      // A GPS fix without a speed is not known to be standing still.
      expect(settledFix(dot, off(2), speedMps: null, accuracyMetres: 5), off(2));
      expect(settledFix(dot, off(2), speedMps: null, accuracyMetres: null), off(2));
    });

    test('fixLateness: how much longer a fix took than the promptest of the last few', () {
      final lags = <double>[];
      // The clocks differ by 37 s: only the difference between fixes matters.
      expect(fixLateness(lags, 37.10), 0);
      expect(fixLateness(lags, 37.10), 0);
      expect(fixLateness(lags, 37.40), closeTo(0.30, 1e-9), reason: 'held up for 0.3 s');
      expect(fixLateness(lags, 37.12), closeTo(0.02, 1e-9));
      expect(fixLateness(lags, 39.00), followLateMost, reason: 'no more than it is safe to make up');
      // A prompter one resets what "on time" is.
      expect(fixLateness(lags, 37.00), 0);
      expect(fixLateness(lags, 37.10), closeTo(0.10, 1e-9));
      // The clock is moved on by a minute: late for a while, then that is on time.
      for (var i = 0; i < followLateWindow - 1; i++) {
        expect(fixLateness(lags, 97.10), followLateMost);
      }
      expect(fixLateness(lags, 97.10), 0);
      expect(lags, hasLength(followLateWindow));
    });

    test('fixLateness: more is made up for in a fix from another phone', () {
      final lags = <double>[];
      expect(fixLateness(lags, -3.20, most: followLateMostRemote), 0);
      // Held up for 1.2 s on the way: all of it, where a phone's own fix would
      // be given half a second.
      expect(fixLateness(lags, -2.00, most: followLateMostRemote), closeTo(1.20, 1e-9));
      expect(fixLateness(lags, 4.00, most: followLateMostRemote), followLateMostRemote, reason: 'and no more than this');
      expect(followLateMostRemote, greaterThan(followLateMost));
      expect(followLateMostRemote, lessThan(followCoastSeconds), reason: 'never carried further than a fix is carried at all');
    });

    test('FixFollower: a fix from another phone is carried forward by how late it reached this one', () {
      final start = const LatLng(3.15, 101.7);
      // A car doing 10 m/s north, a fix a second; the driver's GPS clock is
      // 37 s ahead of this phone's, and each fix takes 0.4 s to get here.
      DateTime gps(double t) => DateTime.utc(2026, 11, 22, 4, 0, 37).add(Duration(microseconds: (t * 1e6).round()));
      DateTime here(double t) => DateTime.utc(2026, 11, 22, 4).add(Duration(microseconds: (t * 1e6).round()));
      LatLng at(double t) => movedAlong(start, 10 * t, 0);
      for (final (most, carried) in [(followLateMostRemote, 1.2), (followLateMost, followLateMost)]) {
        final follower = FixFollower(lateMost: most);
        for (var k = 0; k < 4; k++) {
          follower.take(at(k.toDouble()), speed: 10, course: 0, time: gps(k.toDouble()), clock: () => here(k + 0.4));
        }
        // The fix of 4 s is held up: it arrives 1.6 s after it was taken.
        follower.take(at(4), speed: 10, course: 0, time: gps(4), clock: () => here(5.6));
        expect(follower.ageSeconds, closeTo(carried, 1e-9), reason: 'late by 1.2 s more than the others');
      }
    });

    test('FixFollower: ground lost is made up no faster than the car and a little, when told so', () {
      final start = const LatLng(3.15, 101.7);
      const dt = 1 / 60;
      double fastest(FixFollower follower) {
        // Drawn 30 m short of a car doing 10 m/s north.
        follower.shown = start;
        follower.take(movedAlong(start, 30, 0), speed: 10, course: 0, time: null);
        var most = 0.0;
        for (var i = 0; i < 240; i++) {
          final was = follower.shown!;
          follower.advance(dt);
          most = math.max(most, metresApart(was, follower.shown!) / dt);
        }
        // Either way it gets there: on the car, where it is by now.
        expect(metresApart(follower.shown!, movedAlong(start, 30 + 10 * followCoastSeconds, 0)), lessThan(0.5));
        return most;
      }

      expect(fastest(FixFollower()), greaterThan(60), reason: "a phone's own fixes: the ease closes the gap at its own pace");
      final capped = fastest(FixFollower(catchUp: followCatchUpRemote));
      expect(capped, lessThanOrEqualTo(10 + followCatchUpRemote + 1e-6));
      expect(capped, greaterThan(10 + followCatchUpRemote - 0.5), reason: 'and it does hurry');
    });

    test('FixFollower: a standing car that has ground to make up is not held to a crawl', () {
      final start = const LatLng(3.15, 101.7);
      const dt = 1 / 60;
      final follower = FixFollower(catchUp: followCatchUpRemote)..shown = start;
      // The car is 20 m on and standing there.
      follower.take(movedAlong(start, 20, 0), speed: 0, course: null, time: null);
      var seconds = 0.0;
      while (follower.advance(dt) && seconds < 10) {
        seconds += dt;
      }
      expect(metresApart(follower.shown!, movedAlong(start, 20, 0)), lessThan(0.05));
      expect(seconds, inInclusiveRange(1.0, 2.5), reason: 'at about $followCatchUpRemote m/s');
    });

    test('fixIsStill: next to no speed measured, or none and only good to tens of metres', () {
      expect(fixIsStill(speedMps: 0, accuracyMetres: 5), isTrue);
      expect(fixIsStill(speedMps: followCarryFrom, accuracyMetres: 5), isTrue);
      expect(fixIsStill(speedMps: followCarryFrom + 0.1, accuracyMetres: 5), isFalse);
      expect(fixIsStill(speedMps: null, accuracyMetres: 65), isTrue, reason: 'Wi-Fi or cell towers: it cannot say');
      expect(fixIsStill(speedMps: null, accuracyMetres: 5), isFalse, reason: 'a GPS fix without a speed is not known to be still');
      expect(fixIsStill(speedMps: null, accuracyMetres: null), isFalse);
    });

    test('FixFollower: fixes in, a point a frame at a time out', () {
      final follower = FixFollower();
      expect(follower.hasFix, isFalse);
      expect(follower.advance(0.02), isFalse, reason: 'nothing to move yet');
      DateTime now() => clock0;

      const start = LatLng(3.15, 101.71);
      final first = follower.take(start, speed: 10, course: 0, time: clock0, accuracy: 5, clock: now);
      expect(first, (gap: null, speed: 10.0, course: 0.0));
      expect(follower.shown, start);
      // A second of frames: carried north at 10 m/s, and still going.
      var more = true;
      for (var f = 0; f < 50; f++) {
        more = follower.advance(0.02);
      }
      expect(more, isTrue);
      expect(follower.ageSeconds, closeTo(1.0, 1e-9));
      expect(metresApart(start, follower.shown!), closeTo(10, 0.3));
      expect(bearingBetween(start, follower.shown!), closeTo(0, 0.01));

      // The next fix, a second on by the GPS's clock: the gap, and the speed and course it measured.
      final second = follower.take(
        movedAlong(start, 10, 0),
        speed: 10,
        course: 0,
        time: clock0.add(const Duration(seconds: 1)),
        accuracy: 5,
        clock: now,
      );
      expect(second!.gap, 1.0);
      expect(follower.speed, 10);
      expect(follower.course, 0);

      // A fix from before the one in hand: dropped, nothing changed.
      final dot = follower.shown, age = follower.ageSeconds;
      expect(follower.take(start, speed: 10, course: 0, time: clock0, accuracy: 5, clock: now), isNull);
      expect(follower.shown, dot);
      expect(follower.ageSeconds, age);
      // Unless it is so much older that the clock itself was moved: then it is the news.
      expect(
        follower.take(start, speed: 0, course: null, time: clock0.subtract(const Duration(hours: 1)), clock: now),
        isNotNull,
      );
    });

    test('FixFollower: without a speed or course from the GPS, they are worked out from the fixes', () {
      final follower = FixFollower();
      const start = LatLng(3.15, 101.71);
      follower.take(start, time: clock0, accuracy: 5, clock: () => clock0);
      final taken = follower.take(
        movedAlong(start, 9, 90),
        time: clock0.add(const Duration(seconds: 1)),
        accuracy: 5,
        clock: () => clock0,
      )!;
      expect(taken.speed, closeTo(9, 0.01));
      expect(taken.course, closeTo(90, 0.05));
      // Hardly moved: a speed, but no course to speak of.
      final crept = follower.take(
        movedAlong(start, 10, 90),
        time: clock0.add(const Duration(seconds: 2)),
        accuracy: 5,
        clock: () => clock0,
      )!;
      expect(crept.speed, closeTo(1, 0.01));
      expect(crept.course, isNull);
    });

    test('FixFollower: the fix that first says it has stopped is where it stopped; the next ones are that spot again', () {
      final follower = FixFollower();
      DateTime now() => clock0;
      const start = LatLng(3.15, 101.71);
      follower.take(start, speed: 3, course: 0, time: clock0, accuracy: 5, clock: now);
      for (var f = 0; f < 50; f++) {
        follower.advance(0.02);
      }
      // Carried 3 m up the road — but the car had stopped after 1.5 m.
      final stopped = movedAlong(start, 1.5, 0);
      follower.take(stopped, speed: 0, course: null, time: clock0.add(const Duration(seconds: 1)), accuracy: 5, clock: now);
      var more = true;
      for (var f = 0; f < 100 && more; f++) {
        more = follower.advance(0.02);
      }
      expect(more, isFalse, reason: 'at rest, the frames stop');
      expect(metresApart(follower.shown!, stopped), lessThan(0.05), reason: 'on the spot, not left past it');

      // Standing: the same spot measured a little differently does not move the dot.
      follower.take(
        movedAlong(stopped, 0.6, 200),
        speed: 0.1,
        course: null,
        time: clock0.add(const Duration(seconds: 2)),
        accuracy: 5,
        clock: now,
      );
      expect(follower.advance(0.02), isFalse);
      expect(metresApart(follower.shown!, stopped), lessThan(0.05));
    });

    test('accelerationBetween: from two speeds, within what a car can do', () {
      expect(accelerationBetween(10, 12, 1), 2);
      expect(accelerationBetween(10, 7.5, 1), -2.5);
      expect(accelerationBetween(0, 30, 1), followMaxAcceleration, reason: 'a wild reading is held');
      expect(accelerationBetween(30, 0, 1), -followMaxBraking);
      expect(accelerationBetween(null, 12, 1), 0);
      expect(accelerationBetween(10, null, 1), 0);
      expect(accelerationBetween(10, 12, null), 0);
      expect(accelerationBetween(10, 12, 0.05), 0, reason: 'two fixes at once say nothing');
      expect(accelerationBetween(10, 12, 30), 0, reason: 'nor two far apart');
    });
  });

  group('driverFixOf: only a velocity the platform measured', () {
    test('a measured speed and course pass through', () {
      final fix = driverFixOf(_position(speed: 12.5, heading: 271));
      expect(fix.at, origin);
      expect(fix.speed, 12.5);
      expect(fix.course, 271);
      expect(fix.time, clock0);
      expect(fix.accuracy, 5);
    });

    test('iOS: an unknown course is −1, an unknown speed is left out', () {
      final fix = driverFixOf(_position(heading: -1, hasSpeed: false));
      expect(fix.course, isNull);
      expect(fix.speed, isNull, reason: 'the 0.0 it arrives as is a placeholder, not a standstill');
    });

    test('Android: a bearing left out arrives as 0.0 — not due north', () {
      final fix = driverFixOf(_position(speed: 9, hasHeading: false));
      expect(fix.speed, 9);
      expect(fix.course, isNull);
    });

    test('a course the GPS itself doubts is not one to carry the driver along', () {
      expect(driverFixOf(_position(heading: 90, hasHeadingAccuracy: true, headingAccuracy: 8)).course, 90);
      expect(
        driverFixOf(
          _position(heading: 90, hasHeadingAccuracy: true, headingAccuracy: driverCourseTrustDegrees + 1),
        ).course,
        isNull,
      );
      expect(driverFixOf(_position(heading: 90, hasHeadingAccuracy: true, headingAccuracy: -1)).course, isNull);
    });
  });

  group('on the road', () {
    late StreamController<DriverFix> fixes;
    late StreamController<double> headings;

    Future<void> pump(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1600);
      addTearDown(tester.view.reset);
      fixes = StreamController<DriverFix>.broadcast();
      headings = StreamController<double>.broadcast();
      addTearDown(fixes.close);
      addTearDown(headings.close);
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => const Stream.empty()),
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            driverPositionProvider.overrideWithValue(() async => origin),
            driverPositionStreamProvider.overrideWithValue(() => fixes.stream),
            deviceHeadingProvider.overrideWith((ref) => headings.stream),
            // The clock that moves with the frames pumped, as the fixes' times do.
            driverMapClockProvider.overrideWithValue(() => tester.binding.clock.now()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    MapCamera camera(WidgetTester tester) => tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;

    Finder dot() => find
        .descendant(of: find.byKey(const ValueKey('driver-heading-arrow')), matching: find.byType(CustomPaint))
        .first;

    /// Where the dot is on the screen.
    Offset dotOnScreen(WidgetTester tester) => tester.getCenter(dot());

    /// The cone's angle on the screen, degrees clockwise from straight up; null
    /// while only the dot is drawn.
    double? coneOnScreen(WidgetTester tester) {
      final turned = find.descendant(
        of: find.byKey(const ValueKey('driver-heading-arrow')),
        matching: find.byType(Transform),
      );
      if (turned.evaluate().isEmpty) return null;
      final m = tester.widget<Transform>(turned.first).transform;
      return shortestTurn(0, math.atan2(m.entry(1, 0), m.entry(0, 0)) * 180 / math.pi);
    }

    /// Where the dot is on the ground: the point of the map under its middle.
    LatLng dotOnGround(WidgetTester tester) =>
        camera(tester).screenOffsetToLatLng(dotOnScreen(tester) - tester.getTopLeft(find.byType(FlutterMap)));

    /// Drives from [from] to [to] seconds: a fix of where the car is once a
    /// second (every 50 frames), as a phone's GPS gives them, unless [fixAt] says
    /// not that second — reaching the app [lateBy] frames after it was taken —
    /// a frame every 20 ms, and [each] after every frame with the time and where
    /// the car truly is then.
    Future<void> drive(
      WidgetTester tester,
      Truth Function(double t) truth, {
      required double from,
      required double to,
      required void Function(double t, Truth now) each,
      bool Function(int second)? fixAt,
      bool heading = true,
      bool velocity = true,
      int Function(int second)? lateBy,
    }) async {
      final first = (from / frameSeconds).round(), last = (to / frameSeconds).round();
      final onTheWay = <int, List<void Function()>>{};
      for (var f = first; f < last; f++) {
        final t = f * frameSeconds;
        if (f % 50 == 0 && (fixAt == null || fixAt(f ~/ 50))) {
          final now = truth(t);
          onTheWay.putIfAbsent(f + (lateBy?.call(f ~/ 50) ?? 0), () => []).add(() {
            fixes.add((
              at: now.at,
              speed: velocity ? now.speed : null,
              course: velocity && now.speed > 0 ? now.course : null,
              time: clock0.add(Duration(milliseconds: (t * 1000).round())),
              accuracy: 5,
            ));
            // The heading the compass provider gives while driving: the GPS course.
            if (heading && now.speed >= movingSpeed) headings.add(now.course);
          });
        }
        for (final arrive in onTheWay.remove(f) ?? const <void Function()>[]) {
          arrive();
        }
        await tester.pump(frame);
        each(t + frameSeconds, truth(t + frameSeconds));
      }
    }

    testWidgets('a straight road at a steady 36 km/h: on the car, never stopping, never jumping', (tester) async {
      await pump(tester);
      Truth truth(double t) => (at: at(0, 10 * t), speed: 10, course: 0);
      LatLng? before;
      var worst = 0.0, slowest = double.infinity, fastest = 0.0;
      final screen = <Offset>[];
      await drive(tester, truth, from: 0, to: 8, heading: false, each: (t, now) {
        final dotAt = dotOnGround(tester);
        if (t > 1.5) {
          worst = math.max(worst, metresApart(dotAt, now.at));
          final step = metresApart(before!, dotAt);
          slowest = math.min(slowest, step);
          fastest = math.max(fastest, step);
          screen.add(dotOnScreen(tester));
        }
        before = dotAt;
      });
      // 10 m/s is 0.2 m a frame.
      expect(worst, lessThan(0.6), reason: 'the dot is on the car, not a second behind it');
      expect(slowest, greaterThan(0.15), reason: 'it never stops or stalls between fixes');
      expect(fastest, lessThan(0.25), reason: 'and never jumps to catch up');
      // The map moves under the dot: the dot holds its place on the screen.
      final xs = screen.map((o) => o.dx), ys = screen.map((o) => o.dy);
      expect(xs.reduce(math.max) - xs.reduce(math.min), lessThan(1.0));
      expect(ys.reduce(math.max) - ys.reduce(math.min), lessThan(1.0));
    });

    testWidgets('a fix that is late, or missed altogether, does not stall the dot', (tester) async {
      await pump(tester);
      Truth truth(double t) => (at: at(0, 10 * t), speed: 10, course: 0);
      LatLng? before;
      var worst = 0.0, slowest = double.infinity;
      // The fix due at 4 s never comes: two seconds between the third and the fifth.
      await drive(tester, truth, from: 0, to: 8, heading: false, fixAt: (second) => second != 4, each: (t, now) {
        final dotAt = dotOnGround(tester);
        if (t > 1.5) {
          worst = math.max(worst, metresApart(dotAt, now.at));
          slowest = math.min(slowest, metresApart(before!, dotAt));
        }
        before = dotAt;
      });
      expect(slowest, greaterThan(0.04), reason: 'still moving through the gap');
      expect(worst, lessThan(1.5), reason: 'and still about where the car is');
    });

    testWidgets('fixes held up on their way — now 60 ms, now a third of a second: no hitch', (tester) async {
      await pump(tester);
      Truth truth(double t) => (at: at(0, 10 * t), speed: 10, course: 0);
      // How many frames (of 20 ms) each second's fix is late by.
      const held = [0, 3, 15, 1, 9, 0, 12, 4, 16, 2, 7, 0];
      LatLng? before;
      var worst = 0.0, slowest = double.infinity, fastest = 0.0;
      await drive(
        tester,
        truth,
        from: 0,
        to: 11,
        heading: false,
        lateBy: (second) => held[second % held.length],
        each: (t, now) {
          final dotAt = dotOnGround(tester);
          if (t > 2.5) {
            worst = math.max(worst, metresApart(dotAt, now.at));
            final step = metresApart(before!, dotAt);
            slowest = math.min(slowest, step);
            fastest = math.max(fastest, step);
          }
          before = dotAt;
        },
      );
      // 10 m/s is 0.2 m a frame. Taken as they arrive, a fix a third of a second
      // late pulls the dot back 3 m and it all but stops.
      expect(slowest, greaterThan(0.15), reason: 'it does not slow for a late fix');
      expect(fastest, lessThan(0.25), reason: 'nor spurt after it');
      expect(worst, lessThan(0.6), reason: 'and it is still on the car');
    });

    testWidgets('a fix from before the one in hand does not take the dot back', (tester) async {
      await pump(tester);
      Truth truth(double t) => (at: at(0, 10 * t), speed: 10, course: 0);
      await drive(tester, truth, from: 0, to: 4, heading: false, each: (_, _) {});
      final was = local(dotOnGround(tester)).north;
      // The stream restarts and hands over a position it had kept: three seconds old.
      fixes.add((at: at(0, 10), speed: 10.0, course: 0.0, time: clock0.add(const Duration(seconds: 1)), accuracy: 5));
      var least = was;
      for (var f = 0; f < 25; f++) {
        await tester.pump(frame);
        least = math.min(least, local(dotOnGround(tester)).north);
      }
      expect(least, greaterThanOrEqualTo(was), reason: 'it went on, not back');
    });

    testWidgets('a brisk city corner: the dot goes round with the road', (tester) async {
      await pump(tester);
      // North at 18 km/h for 3 s, a right turn of 10 m radius (a quarter circle
      // in about 3 s), then east.
      const v = 5.0, r = 10.0, turnAt = 3.0;
      const sweep = math.pi / 2 * r / v; // seconds in the bend
      Truth truth(double t) {
        if (t <= turnAt) return (at: at(0, v * t), speed: v, course: 0);
        if (t <= turnAt + sweep) {
          final a = (t - turnAt) * v / r;
          return (at: at(r - r * math.cos(a), v * turnAt + r * math.sin(a)), speed: v, course: a * 180 / math.pi);
        }
        return (at: at(r + v * (t - turnAt - sweep), v * turnAt + r), speed: v, course: 90);
      }

      // The road itself, to measure how far off it the dot strays.
      final road = [for (var t = 0.0; t < 12; t += 0.01) local(truth(t).at)];
      double offRoad(LatLng p) {
        final q = local(p);
        var best = double.infinity;
        for (final s in road) {
          final d = math.sqrt(math.pow(s.east - q.east, 2) + math.pow(s.north - q.north, 2));
          if (d < best) best = d;
        }
        return best;
      }

      var worstOffRoad = 0.0, worstBehind = 0.0;
      await drive(tester, truth, from: 0, to: 10, each: (t, now) {
        if (t < 1.5) return;
        final dotAt = dotOnGround(tester);
        worstOffRoad = math.max(worstOffRoad, offRoad(dotAt));
        worstBehind = math.max(worstBehind, metresApart(dotAt, now.at));
      });
      expect(worstOffRoad, lessThan(1.5), reason: 'it does not cut the corner or swing wide of it');
      expect(worstBehind, lessThan(2.5));
    });

    testWidgets('braking to a stop: no running on past the car, and it comes to rest', (tester) async {
      await pump(tester);
      // 36 km/h, then braking at 2.5 m/s² from 3 s: stopped at 7 s, 20 m on.
      Truth truth(double t) {
        if (t <= 3) return (at: at(0, 10 * t), speed: 10, course: 0);
        if (t <= 7) {
          final b = t - 3;
          return (at: at(0, 30 + 10 * b - 1.25 * b * b), speed: 10 - 2.5 * b, course: 0);
        }
        return (at: at(0, 50), speed: 0, course: 0);
      }

      var worst = 0.0, furthest = 0.0;
      await drive(tester, truth, from: 0, to: 10, heading: false, each: (t, now) {
        if (t < 1.5) return;
        final dotAt = dotOnGround(tester);
        worst = math.max(worst, metresApart(dotAt, now.at));
        furthest = math.max(furthest, local(dotAt).north);
      });
      // The one moment it cannot be on the car: the second after the brakes go
      // on, before any fix has said so (½ × 2.5 m/s² × 1 s² = 1.25 m, about two
      // points on the screen). From the next fix the braking is carried too.
      expect(worst, lessThan(1.3), reason: 'with the car all the way down to the stop');
      expect(furthest, lessThan(50.4), reason: 'it does not run on past where the car stopped');
      expect(metresApart(dotOnGround(tester), at(0, 50)), lessThan(0.1));
      // Parked: the follow rests (this would time out if it kept running).
      await tester.pumpAndSettle();
    });

    testWidgets('a sharp stop the GPS only hears of a second later: the dot comes back onto the car at once', (
      tester,
    ) async {
      await pump(tester);
      // Crawling at 11 km/h, then stopped dead half a second after the fix at 5 s
      // — nothing says so until the fix at 6 s.
      Truth truth(double t) {
        if (t <= 5.5) return (at: at(0, 3 * t), speed: 3, course: 0);
        return (at: at(0, 16.5), speed: 0, course: 0);
      }

      var carriedPast = 0.0, afterASecond = double.infinity;
      await drive(tester, truth, from: 0, to: 9, heading: false, each: (t, now) {
        final north = local(dotOnGround(tester)).north;
        if (t > 5.5 && t <= 6.0) carriedPast = math.max(carriedPast, north - 16.5);
        if ((t - 7.0).abs() < 0.011) afterASecond = (north - 16.5).abs();
      });
      // It could not know: it was carried on past where the car stopped…
      expect(carriedPast, greaterThan(0.8));
      // …and is back on it within a second of being told, not left creeping back for five.
      expect(afterASecond, lessThan(0.15));
      expect(metresApart(dotOnGround(tester), at(0, 16.5)), lessThan(0.1));
      await tester.pumpAndSettle();
    });

    testWidgets('pulling away from the lights: the dot leaves with the car', (tester) async {
      await pump(tester);
      // Standing for 2 s, then away at 2.5 m/s² up to 54 km/h.
      Truth truth(double t) {
        if (t <= 2) return (at: at(0, 0), speed: 0, course: 0);
        final a = t - 2;
        if (a <= 6) return (at: at(0, 1.25 * a * a), speed: 2.5 * a, course: 0);
        return (at: at(0, 45 + 15 * (a - 6)), speed: 15, course: 0);
      }

      var worst = 0.0;
      await drive(tester, truth, from: 0, to: 11, heading: false, each: (t, now) {
        worst = math.max(worst, metresApart(dotOnGround(tester), now.at));
      });
      // The first second off the line is the GPS's own: no fix has yet said the car moved.
      expect(worst, lessThan(2.0));
    });

    testWidgets('driving turns the map heading-up, in a sweep and not in jumps', (tester) async {
      await pump(tester);
      expect(camera(tester).rotation, 0, reason: 'north-up while parked');
      // East at 36 km/h.
      Truth truth(double t) => (at: at(10 * t, 0), speed: 10, course: 90);
      var biggestTurn = 0.0;
      var was = camera(tester).rotation;
      await drive(tester, truth, from: 0, to: 6, each: (t, now) {
        final r = camera(tester).rotation;
        biggestTurn = math.max(biggestTurn, shortestTurn(was, r).abs());
        was = r;
      });
      // The way they are going points up: the map is turned by −90°.
      expect(shortestTurn(camera(tester).rotation, -90).abs(), lessThan(0.5));
      expect(biggestTurn, lessThan(6), reason: 'eased a frame at a time (a jump would be 90° at once)');
      expect(find.byKey(const ValueKey('map-compass')), findsOneWidget, reason: 'turned: the compass shows');

      // The compass straightens the map, and it stays straight while they drive on.
      await tester.tap(find.byKey(const ValueKey('map-compass')));
      await tester.pump();
      expect(camera(tester).rotation, 0);
      await drive(tester, truth, from: 6, to: 8, each: (_, _) {});
      expect(camera(tester).rotation, 0, reason: 'north-up was asked for: not turned back mid-drive');
    });

    testWidgets('through a bend the map turns steadily with the road: no lurch a second, no swinging past', (
      tester,
    ) async {
      await pump(tester);
      // North at 18 km/h, then a right-hand bend of 10 m radius through a
      // quarter turn (28.6° a second for 3.1 s), then east.
      const v = 5.0, r = 10.0, turnAt = 3.0;
      const sweep = math.pi / 2 * r / v;
      Truth truth(double t) {
        if (t <= turnAt) return (at: at(0, v * t), speed: v, course: 0);
        if (t <= turnAt + sweep) {
          final a = (t - turnAt) * v / r;
          return (at: at(r - r * math.cos(a), v * turnAt + r * math.sin(a)), speed: v, course: a * 180 / math.pi);
        }
        return (at: at(r + v * (t - turnAt - sweep), v * turnAt + r), speed: v, course: 90);
      }

      var was = camera(tester).rotation;
      var slowest = double.infinity, fastest = 0.0, furthest = 0.0, coneOff = 0.0;
      await drive(tester, truth, from: 0, to: 11, each: (t, now) {
        final rotation = camera(tester).rotation;
        final step = shortestTurn(rotation, was); // degrees turned this frame, clockwise on the ground
        was = rotation;
        // The map turned by −heading: how far round it has gone.
        furthest = math.max(furthest, -rotation);
        // Well into the bend and before the last of it: the map is turning at
        // the car's own rate, 28.6° a second — 0.57° a frame.
        if (t > 4.6 && t < 6.9) {
          slowest = math.min(slowest, step);
          fastest = math.max(fastest, step);
        }
        // Heading-up: the cone points up the screen all the way round.
        if (t > 2.5) coneOff = math.max(coneOff, coneOnScreen(tester)!.abs());
      });
      expect(slowest, greaterThan(0.45), reason: 'it never stops to wait for the next fix');
      expect(fastest, lessThan(0.70), reason: 'and never lurches to catch up');
      expect(furthest, lessThan(90.5), reason: 'it does not swing past the way the road goes');
      expect(shortestTurn(camera(tester).rotation, -90).abs(), lessThan(0.5), reason: 'and ends facing down the new road');
      expect(coneOff, lessThan(1.0), reason: 'the cone stays pointing up the screen');
    });

    testWidgets('a GPS that gives no speed or course: worked out from the fixes, and still on the car', (tester) async {
      await pump(tester);
      Truth truth(double t) => (at: at(0, 10 * t), speed: 10, course: 0);
      LatLng? before;
      var worst = 0.0, slowest = double.infinity;
      await drive(tester, truth, from: 0, to: 8, heading: false, velocity: false, each: (t, now) {
        final dotAt = dotOnGround(tester);
        // From the third fix: the first has nothing to compare with.
        if (t > 2.5) {
          worst = math.max(worst, metresApart(dotAt, now.at));
          slowest = math.min(slowest, metresApart(before!, dotAt));
        }
        before = dotAt;
      });
      expect(worst, lessThan(0.6));
      expect(slowest, greaterThan(0.15));
    });

    testWidgets('a fix a long way off is jumped to, not glided across the city', (tester) async {
      await pump(tester);
      fixes.add((at: origin, speed: 0.0, course: null, time: clock0, accuracy: 5));
      await tester.pump(frame);
      await tester.pump(frame);
      // The app comes back to a fix two kilometres on.
      final far = at(0, 2000);
      fixes.add((at: far, speed: 0.0, course: null, time: clock0.add(const Duration(minutes: 5)), accuracy: 5));
      await tester.pump(frame);
      await tester.pump(frame);
      expect(metresApart(dotOnGround(tester), far), lessThan(0.1));
      await tester.pumpAndSettle();
    });

    testWidgets('parked, with the GPS wandering round the car as it does: the dot and the map keep still', (
      tester,
    ) async {
      await pump(tester);
      // Pulled up: the first fix to say so is where the car stopped.
      fixes.add((at: origin, speed: 0.0, course: null, time: clock0, accuracy: 5));
      await tester.pumpAndSettle();
      // Then a fix a second for half a minute, each up to 1.5 m off in some direction.
      final wander = math.Random(7);
      final first = dotOnGround(tester);
      final map0 = camera(tester).center;
      LatLng? before;
      var biggestStep = 0.0, furthest = 0.0, mapMoved = 0.0;
      for (var second = 1; second <= 30; second++) {
        fixes.add((
          at: movedAlong(origin, wander.nextDouble() * 1.5, wander.nextDouble() * 360),
          speed: wander.nextDouble() * 0.2,
          course: null,
          time: clock0.add(Duration(seconds: second)),
          accuracy: 5,
        ));
        for (var f = 0; f < 50; f++) {
          await tester.pump(frame);
          final dotAt = dotOnGround(tester);
          if (before != null) biggestStep = math.max(biggestStep, metresApart(before, dotAt));
          before = dotAt;
          furthest = math.max(furthest, metresApart(first, dotAt));
          mapMoved = math.max(mapMoved, metresApart(map0, camera(tester).center));
        }
      }
      // A point on the screen is 0.6 m of road at this zoom.
      expect(biggestStep, lessThan(0.03), reason: 'nothing the eye can catch in a frame');
      expect(furthest, lessThan(0.6), reason: 'it stays on the car, within a point');
      expect(mapMoved, lessThan(0.6), reason: 'and the map is not dragged about under it');
      // Nothing left running once the fixes stop.
      await tester.pumpAndSettle();
    });

    testWidgets('parked, a fix that puts the car somewhere else is believed', (tester) async {
      await pump(tester);
      fixes.add((at: origin, speed: 0.0, course: null, time: clock0, accuracy: 5));
      await tester.pumpAndSettle();
      // The GPS finds itself: thirty metres from where it first said.
      final better = at(30, 0);
      fixes.add((at: better, speed: 0.0, course: null, time: clock0.add(const Duration(seconds: 1)), accuracy: 5));
      await tester.pumpAndSettle();
      expect(metresApart(dotOnGround(tester), better), lessThan(0.1));
    });

    testWidgets('parked, the cone turns to where the phone points — eased round, the map left alone', (tester) async {
      await pump(tester);
      headings.add(40);
      await tester.pumpAndSettle();
      expect(coneOnScreen(tester), closeTo(40, 0.1));
      // Turned a quarter of the way round: the cone goes there in a sweep.
      headings.add(130);
      await tester.pump(frame);
      await tester.pump(frame);
      final partWay = coneOnScreen(tester)!;
      expect(partWay, greaterThan(40));
      expect(partWay, lessThan(130), reason: 'on its way, not jumped');
      await tester.pumpAndSettle();
      expect(coneOnScreen(tester), closeTo(130, 0.1));
      expect(camera(tester).rotation, 0);
    });

    testWidgets('a parked phone does not turn the map, wherever it is pointed', (tester) async {
      await pump(tester);
      for (final h in [40.0, 120.0, 250.0]) {
        headings.add(h);
        await tester.pump(frame);
        await tester.pump(frame);
      }
      await tester.pumpAndSettle();
      expect(camera(tester).rotation, 0);
    });
  });
}
