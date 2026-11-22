// The passenger's trip map with the driver's phone's fixes, a frame at a time
// (features/ride/live_ride_map.dart, migration 0426).
//
// A car is driven down a road here. The driver's phone shares where it is on
// the ride row every five seconds, as it always has, and now sends each GPS
// fix as well, about one a second, which reaches the passenger's phone a
// fraction of a second later — or late, or not at all. Each frame the car as
// the passenger's map draws it is checked against where the car really is.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/car_playback.dart';
import 'package:get_ride/src/core/follow_motion.dart';
import 'package:get_ride/src/data/live_fix.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import 'support/trip_road.dart';

/// A fix on its way: when it is heard, and whether it is.
typedef Sent = ({double heard, LiveFix fix});

/// How far a second's worth of delay spreads over the fixes: each reaches the
/// passenger between 0.30 and 0.75 s after it was taken, in no order.
double uneven(int k) => 0.30 + ((k * 7919) % 100) / 100 * 0.45;

void main() {
  late Road road;
  late RoadGeo geo;
  late DateTime clock;

  /// The stream the map was last given, and how often it asked for one.
  late StreamController<LiveFix> fixes;
  late int asked;

  setUp(() {
    road = Road();
    geo = RoadGeo(road);
    clock = t0;
    asked = 0;
    fixes = StreamController<LiveFix>();
  });

  Stream<LiveFix> open() {
    asked++;
    // Not waited for: a stream nobody listened to never finishes closing.
    unawaited(fixes.close());
    fixes = StreamController<LiveFix>();
    return fixes.stream;
  }

  Future<void> show(WidgetTester tester, RideRequest r, {LatLng? driverAt}) => tester.pumpWidget(
    ProviderScope(
      overrides: [geoServiceProvider.overrideWithValue(geo)],
      child: MaterialApp(
        home: Scaffold(body: LiveRideMap(ride: r, now: () => clock, carFixes: open, driverAt: driverAt)),
      ),
    ),
  );

  /// Drives the real car, [where] metres down the road at each moment, for
  /// [seconds], and returns what each frame showed.
  ///
  /// The driver's phone takes a fix every second and sends it unless [sends]
  /// says not ([wander] metres out, a different way each time); it is heard
  /// [late] seconds after it was taken. The ride row is shared every
  /// [rowEvery] seconds once the car has moved fifteen metres, and heard 0.4 s
  /// later — or, with [rows], at the moments and places given there.
  ///
  /// The three clocks do not agree: the GPS's is [gpsAhead] of the
  /// passenger's phone's and the driver's phone's own [rowAhead] of it.
  Future<List<Seen>> drive(
    WidgetTester tester, {
    required double Function(double t) where,
    double seconds = 45,
    double rowEvery = 5,
    List<({double heard, double metres})>? rows,
    double Function(int k)? late,
    bool Function(double taken)? sends,
    double wander = 0,
    Duration gpsAhead = const Duration(seconds: 37),
    Duration rowAhead = const Duration(seconds: -4),
    void Function(double t)? each,
  }) async {
    double speedAt(double t) => t < 0.02 ? (where(0.02) - where(0)) / 0.02 : (where(t + 0.01) - where(t - 0.01)) / 0.02;
    final due = <Sent>[];
    for (var k = 0; k <= seconds; k++) {
      final taken = k.toDouble();
      if (sends != null && !sends(taken)) continue;
      final spot = road.spot(where(taken));
      final speed = speedAt(taken);
      // Out by up to [wander] metres, in a direction that changes with each.
      final at = wander == 0 ? spot.at : movedAlong(spot.at, wander * (0.4 + 0.6 * ((k * 31) % 7) / 6), (k * 137) % 360);
      due.add((
        heard: taken + (late?.call(k) ?? 0.35),
        fix: (
          at: at,
          speed: speed < 0.05 ? 0.0 : speed,
          course: speed >= 0.5 ? spot.bearing : null,
          time: t0.add(gpsAhead).add(Duration(microseconds: (taken * 1e6).round())),
          accuracy: 5.0,
        ),
      ));
    }
    due.sort((a, b) => a.heard.compareTo(b.heard));
    final seen = <Seen>[];
    var nextFix = 0, nextRow = 0;
    double? sharedAt;
    for (var f = 0; f * frameSeconds <= seconds; f++) {
      final t = f * frameSeconds;
      clock = t0.add(Duration(microseconds: (t * 1e6).round()));
      if (rows != null) {
        while (nextRow < rows.length && rows[nextRow].heard <= t) {
          final spot = road.spot(rows[nextRow].metres);
          await show(tester, ride(road, car: spot.at, heading: spot.bearing, sent: clock.add(rowAhead)));
          nextRow++;
        }
      } else if (t >= nextRow * rowEvery + 0.4) {
        final taken = nextRow * rowEvery;
        final metres = where(taken);
        // The driver's phone shares the row only when it has moved 15 m.
        if (sharedAt == null || (metres - sharedAt).abs() >= 15) {
          sharedAt = metres;
          final spot = road.spot(metres);
          await show(
            tester,
            ride(road, car: spot.at, heading: spot.bearing, sent: t0.add(rowAhead).add(Duration(microseconds: (taken * 1e6).round()))),
          );
        }
        nextRow++;
      }
      while (nextFix < due.length && due[nextFix].heard <= t) {
        fixes.add(due[nextFix].fix);
        nextFix++;
      }
      await tester.pump(frame);
      each?.call(t);
      // Nothing is on screen until the car is first heard from.
      if (find.byType(RideMap).evaluate().isEmpty) continue;
      final car = rideMap(tester).driverLive!.value;
      if (car == null) continue;
      final line = rideMap(tester).route;
      seen.add((t: t, car: car, camera: cameraOf(tester), lineStart: line.isEmpty ? null : line.first, real: where(t)));
    }
    return seen;
  }

  /// How far behind the real car the drawn one is, in metres down the road.
  double behind(Seen s) => s.real - road.along(s.car.at);

  /// The fastest and slowest the car is drawn moving over [part] (m/s), and
  /// the farthest it is drawn going back the way it came (metres).
  ({double slowest, double fastest, double back}) motion(Iterable<Seen> part) {
    var slowest = double.infinity, fastest = 0.0, back = 0.0;
    Seen? was;
    for (final s in part) {
      if (was != null) {
        final speed = metresApart(was.car.at, s.car.at) / frameSeconds;
        slowest = math.min(slowest, speed);
        fastest = math.max(fastest, speed);
        back = math.max(back, road.along(was.car.at) - road.along(s.car.at));
      }
      was = s;
    }
    return (slowest: slowest, fastest: fastest, back: back);
  }

  Iterable<Seen> between(List<Seen> seen, double from, [double to = double.infinity]) =>
      seen.where((s) => s.t >= from && s.t <= to);

  double steady(double t) => 14 * t;

  group('a fix a second', () {
    testWidgets('the car is drawn where it is now, not seconds behind', (tester) async {
      const speed = 14.0;
      final seen = await drive(tester, where: steady, late: uneven);
      expect(seen.length, greaterThan(2000));
      for (final s in between(seen, 8)) {
        final when = 'at ${s.t.toStringAsFixed(2)} s';
        // Within about half a second of the real car — the time a fix takes to
        // get here, which nothing can tell it — and never out in front of it.
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'behind the real car $when');
        expect(road.offBy(s.car.at), lessThan(6), reason: 'on the road $when');
        // The camera is on the car, north up, at street zoom.
        expect(metresApart(s.camera.center, s.car.at), lessThan(0.5), reason: 'the camera $when');
        expect(s.camera.rotation, 0);
        expect(s.camera.zoom, followZoom);
      }
      // On the straight it is drawn doing the car's own speed, on its road.
      final straight = motion(between(seen, 8, 26));
      expect(straight.slowest, greaterThan(speed * 0.9));
      expect(straight.fastest, lessThan(speed * 1.15));
      expect(between(seen, 8, 26).map((s) => road.offBy(s.car.at)).reduce(math.max), lessThan(0.5));
      // Round the bend it is carried a little wide and pulled back in: never
      // standing, never leaping, never back the way it came.
      final all = motion(between(seen, 8));
      expect(all.slowest, greaterThan(speed * 0.6));
      expect(all.fastest, lessThan(speed * 1.8));
      expect(all.back, lessThan(0.05));
    });

    testWidgets("a driver's phone that sends none: the ride row is played back, as before", (tester) async {
      const speed = 14.0;
      final seen = await drive(tester, where: steady, sends: (_) => false);
      for (final s in between(seen, 11)) {
        // A position and a little behind the real car.
        expect(behind(s) / speed, inInclusiveRange(4.9, 6.4), reason: 'at ${s.t.toStringAsFixed(2)} s');
        expect(road.offBy(s.car.at), lessThan(0.5));
      }
    });

    testWidgets('whatever the three clocks say', (tester) async {
      // The GPS's clock hours behind the passenger's phone's, the driver's
      // phone's own days ahead of it.
      final seen = await drive(
        tester,
        where: steady,
        late: uneven,
        seconds: 30,
        gpsAhead: const Duration(hours: -3, seconds: -11),
        rowAhead: const Duration(days: 2, seconds: 5),
      );
      for (final s in between(seen, 8)) {
        expect(behind(s), inInclusiveRange(-1.0, 14 * 0.6), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
      expect(motion(between(seen, 8)).back, lessThan(0.05));
    });

    testWidgets('it faces the way it is driving, and the road line starts under it', (tester) async {
      final seen = await drive(tester, where: steady, late: uneven);
      double? was;
      for (final s in between(seen, 8)) {
        final when = 'at ${s.t.toStringAsFixed(2)} s';
        final heading = s.car.heading!;
        if (was != null) expect(shortestTurn(was, heading).abs(), lessThan(followMaxTurnPerSecond * frameSeconds + 1e-6));
        was = heading;
        // The way the road runs where it is drawn: on the straights to the
        // degree; round the bend (twenty degrees a second, far tighter than a
        // car takes at this speed) a second or so of turn behind it, which is
        // how old the course it was last told is.
        expect(shortestTurn(heading, road.spot(road.along(s.car.at)).bearing).abs(), lessThan(35), reason: 'facing $when');
        if (s.lineStart != null) {
          expect(metresApart(s.lineStart!, s.car.at), lessThan(carLineStepMetres + 6), reason: 'the line and the car $when');
        }
      }
      for (final s in between(seen, 8, 26)) {
        expect(shortestTurn(s.car.heading!, 0).abs(), lessThan(1), reason: 'north up the straight');
      }
      expect(shortestTurn(seen.last.car.heading!, 90).abs(), lessThan(1), reason: 'east, once round the bend');
    });
  });

  group('fixes that go missing or come late', () {
    testWidgets('one lost: the car eases off and drives on; two lost: it makes the ground up as a car would', (tester) async {
      const speed = 14.0;
      final seen = await drive(
        tester,
        where: steady,
        seconds: 30,
        sends: (taken) => taken != 12 && taken != 20 && taken != 21,
      );
      // One lost: it never stands.
      final one = motion(between(seen, 11, 16));
      expect(one.slowest, greaterThan(3), reason: 'still moving while a fix is missed');
      expect(one.fastest, lessThan(speed + followCatchUpRemote + 0.5));
      for (final s in between(seen, 11, 16)) {
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6));
      }
      // Two lost: carried on for two seconds it stands for a moment, and is
      // then drawn catching up — faster than the car, not in one lurch.
      final two = motion(between(seen, 19, 26));
      expect(two.fastest, lessThan(speed + followCatchUpRemote + 0.5), reason: 'no lurch');
      expect(two.fastest, greaterThan(speed + 5), reason: 'it does hurry');
      expect(between(seen, 19, 26).map(behind).reduce(math.max), lessThan(speed * 1.6));
      for (final s in between(seen, 24.5, 26)) {
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'caught up by ${s.t.toStringAsFixed(2)} s');
      }
      expect(motion(seen).back, lessThan(0.05), reason: 'never back the way it came');
    });

    testWidgets('held up and then all at once: each is carried forward by how late it was', (tester) async {
      const speed = 14.0;
      // The fixes of 12, 13 and 14 s are held up and all arrive at 14.6; the
      // fix of 20 s is held up on its own, and arrives 1.2 s after it was
      // taken, a moment before the one after it.
      final seen = await drive(
        tester,
        where: steady,
        seconds: 30,
        late: (k) => k >= 12 && k <= 14 ? 14.6 - k : (k == 20 ? 1.2 : 0.35),
      );
      expect(motion(seen).back, lessThan(0.05), reason: 'a stale one does not pull the car back');
      expect(motion(between(seen, 11, 20)).fastest, lessThan(speed + followCatchUpRemote + 0.5));
      for (final s in between(seen, 17.5, 30)) {
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
    });

    // Nothing from the driver's phone between 15 and 41 s; the ride row goes on
    // being heard (it is also read again every few seconds without realtime).
    // By 41 s the real car is round the bend and the drawn one, a row's worth
    // behind, still in it.
    for (final (name, gpsAhead, rowAhead) in [
      ('', const Duration(seconds: 37), const Duration(seconds: -4)),
      // A row stamped a little before the last fix was (by another clock) is
      // not one that arrived out of order.
      (' (clocks a few seconds apart)', const Duration(seconds: 12), Duration.zero),
    ]) {
      testWidgets('they stop: the car stands, then follows the ride row; they come back: it is driven up to them and followed live again$name', (
        tester,
      ) async {
        const speed = 12.0;
        double where(double t) => speed * t;
        final seen = await drive(
          tester,
          where: where,
          seconds: 52,
          late: uneven,
          sends: (taken) => taken <= 15 || taken >= 41,
          gpsAhead: gpsAhead,
          rowAhead: rowAhead,
        );
        expect(motion(seen).back, lessThan(0.05), reason: 'never back the way it came, whichever it is following');
        // Live until they stop.
        for (final s in between(seen, 8, 15)) {
          expect(behind(s), inInclusiveRange(-1.0, speed * 0.6));
        }
        // Carried on for a couple of seconds, it then stands: nothing says
        // where the car is, and the row already there is from before.
        expect(motion(between(seen, 18.5, 20.2)).fastest, lessThan(0.01), reason: 'standing while nothing is known');
        // The next row to turn up is taken, and the car driven on from where
        // it stands: a few seconds behind the real one, as a row's positions
        // are, and round the bend on the road.
        final after = motion(between(seen, 22, 41));
        expect(after.slowest, greaterThan(4), reason: 'moving again');
        for (final s in between(seen, 24, 41)) {
          expect(behind(s) / speed, inInclusiveRange(3.5, 6.5), reason: 'at ${s.t.toStringAsFixed(2)} s');
          expect(road.offBy(s.car.at), lessThan(0.5));
        }
        // They come back, with the car some sixty metres and half a bend
        // behind: it is driven up the road to them, no faster than a car can
        // be taken to go, and then followed live.
        final back = between(seen, 41.3, 46).toList();
        expect(metresApart(back.first.car.at, road.at(where(back.first.t))), greaterThan(carFixJoinMetres));
        expect(motion(back).fastest, lessThan(playbackTopSpeed + 1));
        expect(back.map((s) => road.offBy(s.car.at)).reduce(math.max), lessThan(1.5), reason: 'round the bend, not across it');
        for (final s in between(seen, 46.5)) {
          expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'live again at ${s.t.toStringAsFixed(2)} s');
        }
      });
    }

    testWidgets('fixes that only come every few seconds are played back: the car drives on, a little behind, and does not stop and start', (
      tester,
    ) async {
      const speed = 12.0;
      double where(double t) => speed * t;
      // A poor connection: one fix in four gets through.
      final seen = await drive(tester, where: where, seconds: 45, sends: (taken) => taken % 4 == 0);
      final run = between(seen, 14).toList();
      final moving = motion(run);
      expect(moving.slowest, greaterThan(speed * 0.6), reason: 'never standing waiting for the next');
      expect(moving.fastest, lessThan(speed * 1.6));
      expect(moving.back, lessThan(0.05));
      for (final s in run) {
        // A fix and a little behind: closer than the ride row's five seconds
        // would have it.
        expect(behind(s) / speed, inInclusiveRange(2.5, 5.0), reason: 'at ${s.t.toStringAsFixed(2)} s');
        expect(road.offBy(s.car.at), lessThan(0.5));
      }
    });

    testWidgets('followed live, then the fixes thin out: after two late ones it is played back, and drives on steadily', (
      tester,
    ) async {
      const speed = 12.0;
      double where(double t) => speed * t;
      // A fix a second for fifteen seconds; from then on one in four.
      final seen = await drive(tester, where: where, seconds: 50, sends: (taken) => taken <= 15 || taken % 4 == 0);
      for (final s in between(seen, 8, 15)) {
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'live while they come');
      }
      // Carried forward from fixes four seconds apart, a car is drawn driving
      // for two seconds and standing for two. Once it is clear they are not
      // coming steadily, they are played back instead.
      final thin = between(seen, 30).toList();
      final moving = motion(thin);
      expect(moving.slowest, greaterThan(speed * 0.6), reason: 'no stopping and starting');
      expect(moving.fastest, lessThan(speed * 1.6));
      expect(motion(seen).back, lessThan(0.05));
      for (final s in thin) {
        expect(behind(s) / speed, inInclusiveRange(2.5, 5.0), reason: 'at ${s.t.toStringAsFixed(2)} s');
        expect(road.offBy(s.car.at), lessThan(0.5));
      }
    });

    testWidgets('back after a silence, steady at once but with the car a bend behind: driven round it, not slid across', (
      tester,
    ) async {
      const speed = 12.0;
      double where(double t) => speed * t;
      // The driver's phone loses its connection after 35 s: no fixes, and no
      // rows either. It is back at 40 s. By then the real car is round the
      // bend (which runs from 400 to 463 m) and the drawn one is still in it,
      // played back from the last row — and the first fix back is taken as
      // slowly as that row was, so the second finds the car well behind.
      final seen = await drive(
        tester,
        where: where,
        seconds: 50,
        late: uneven,
        sends: (taken) => taken <= 15 || taken >= 40,
        rows: [for (var k = 0; k <= 7; k++) (heard: k * 5 + 0.4, metres: where(k * 5.0))],
      );
      final back = between(seen, 40.2, 46).toList();
      final gap = metresApart(back.first.car.at, road.at(where(back.first.t)));
      expect(gap, greaterThan(carFixJoinMetres), reason: 'well behind when they come back');
      expect(road.along(back.first.car.at), inInclusiveRange(400, 463), reason: 'and still in the bend');
      expect(back.map((s) => road.offBy(s.car.at)).reduce(math.max), lessThan(1.5), reason: 'round the bend, on the road');
      expect(motion(back).fastest, lessThan(playbackTopSpeed + 1));
      expect(motion(seen).back, lessThan(0.05));
      for (final s in between(seen, 46.5)) {
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'live again at ${s.t.toStringAsFixed(2)} s');
      }
    });

    testWidgets("the passenger's own phone was away for ten seconds, and the car went round a bend: back, it is put on the road where it is, not slid across the map", (
      tester,
    ) async {
      const speed = 12.0;
      double where(double t) => speed * t;
      // Nothing is heard between 28 and 38 s, fixes or rows. The car was last
      // drawn about 40 m short of the bend; it is now at the far end of it,
      // some 90 m away as the crow flies.
      final seen = await drive(
        tester,
        where: where,
        seconds: 48,
        late: uneven,
        sends: (taken) => taken <= 28 || taken >= 38,
        rows: [
          for (var k = 0; k <= 5; k++) (heard: k * 5 + 0.4, metres: where(k * 5.0)),
          (heard: 40.4, metres: where(40)),
          (heard: 45.4, metres: where(45)),
        ],
      );
      // Carried on for two seconds past the last fix and eased to a stop.
      final away = between(seen, 32.5, 38).toList();
      expect(motion(away).fastest, lessThan(0.01), reason: 'standing while nothing is heard');
      final back = between(seen, 38.2, 44).toList();
      final gap = metresApart(back.first.car.at, road.at(where(back.first.t)));
      expect(gap, inInclusiveRange(carFixJoinMetres, followSnapMetres), reason: 'too far to glide to, too near to be a jump of the follower\'s own');
      expect(back.map((s) => road.offBy(s.car.at)).reduce(math.max), lessThan(1.5), reason: 'on the road all the way');
      expect(motion(seen).back, lessThan(0.05));
      for (final s in between(seen, 40.5)) {
        expect(behind(s), inInclusiveRange(-1.0, speed * 0.6), reason: 'live again at ${s.t.toStringAsFixed(2)} s');
      }
    });

    testWidgets('a row that would put the car behind where it is drawn is not driven back to', (tester) async {
      // The fixes stop after 12 s: by then the car has been drawn on to about
      // 196 m. A row from 13 s (182 m), held up, turns up five seconds later.
      final seen = await drive(
        tester,
        where: steady,
        seconds: 37,
        sends: (taken) => taken <= 12,
        rows: [(heard: 0.4, metres: 0), (heard: 5.4, metres: 70), (heard: 10.4, metres: 140), (heard: 17.5, metres: 182), (heard: 23, metres: 320)],
      );
      final stood = between(seen, 16, 22.9).toList();
      expect(road.along(stood.first.car.at), greaterThan(190));
      expect(motion(stood).fastest, lessThan(0.01), reason: 'the row from behind it moves it nowhere');
      expect(motion(seen).back, lessThan(0.05));
      // The next one, from farther down the road, is driven to: in about the
      // time since the car was last heard from.
      expect(motion(between(seen, 23.5, 33)).slowest, greaterThan(5));
      expect(road.along(seen.last.car.at), closeTo(320, 1));
    });
  });

  group('a car that stops', () {
    // 12 m/s, braking from 10 s (to a stop at 144 m, at 14 s), standing until
    // [until], pulling away at 2 m/s² for six seconds and on at 12 m/s.
    double Function(double) stopAndGo(double until) => (t) {
      if (t <= 10) return 12 * t;
      if (t <= 14) return 120 + 12 * (t - 10) - 1.5 * (t - 10) * (t - 10);
      if (t <= until) return 144;
      if (t <= until + 6) return 144 + (t - until) * (t - until);
      return 180 + 12 * (t - until - 6);
    };

    testWidgets('stands still however its GPS wanders, and pulls away with the real one', (tester) async {
      final where = stopAndGo(22);
      var idle = 0;
      final seen = await drive(
        tester,
        where: where,
        seconds: 40,
        late: uneven,
        // Two metres out, a different way each second.
        wander: 2,
        each: (t) {
          if (t > 17 && t < 22 && !tester.binding.hasScheduledFrame) idle++;
        },
      );
      // Braking: drawn slowing with it, never run on past where it stops.
      for (final s in between(seen, 10, 15)) {
        expect(behind(s), inInclusiveRange(-3.0, 12 * 0.6), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
      // Standing: it stays where it stopped, give or take the GPS's wander,
      // and does not creep about with each fix.
      final standing = between(seen, 16, 22).toList();
      for (final s in standing) {
        expect(metresApart(s.car.at, road.at(144)), lessThan(3), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
      expect(motion(standing).fastest, lessThan(2), reason: 'no darting about');
      expect(lineMetres([for (final s in standing) s.car.at]), lessThan(3), reason: 'nor wandering: this is six seconds of it');
      expect(idle, greaterThan(100), reason: 'and most frames there is nothing to draw: the frames stop');
      // Pulling away: with the real car.
      for (final s in between(seen, 23.5, 40)) {
        expect(behind(s), inInclusiveRange(-3.0, 12 * 0.6), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
      expect(motion(between(seen, 10, 40)).back, lessThan(2.1), reason: 'only as far as the GPS wandered');
    });

    testWidgets('heard from only now and then while it stands, it is followed at once when it pulls away', (tester) async {
      // A phone reports little while it is not moving: here once in ten
      // seconds, through a stop of nearly half a minute.
      final where = stopAndGo(40);
      final seen = await drive(
        tester,
        where: where,
        seconds: 55,
        sends: (taken) => taken <= 15 || taken == 25 || taken == 35 || taken >= 41,
      );
      for (final s in between(seen, 16, 40)) {
        expect(metresApart(s.car.at, road.at(144)), lessThan(1), reason: 'standing at ${s.t.toStringAsFixed(2)} s');
      }
      // The first fix of it moving (taken at 41 s, heard at 41.35) is carried
      // forward at once: the car is drawn pulling away within a moment of it,
      // not left for a second fix to confirm.
      expect(motion(between(seen, 41.5, 42.3)).slowest, greaterThan(0.5), reason: 'moving at once');
      for (final s in between(seen, 43, 55)) {
        expect(behind(s), inInclusiveRange(-1.0, 12 * 0.6), reason: 'at ${s.t.toStringAsFixed(2)} s');
      }
      expect(motion(seen).back, lessThan(0.05));
    });
  });

  testWidgets('a standing car heard from only now and then, its GPS wandering: played back, it does not creep about', (
    tester,
  ) async {
    // Never two fixes close together, so never followed live: each is a
    // position to play back to. 12 m/s to a stop at 144 m (14 s), and standing
    // there, its fixes two metres out a different way each time.
    double where(double t) {
      if (t <= 10) return 12 * t;
      if (t <= 14) return 120 + 12 * (t - 10) - 1.5 * (t - 10) * (t - 10);
      return 144;
    }

    final seen = await drive(tester, where: where, seconds: 60, wander: 2, sends: (taken) => taken % 4 == 0);
    final standing = between(seen, 30).toList();
    for (final s in standing) {
      expect(metresApart(s.car.at, road.at(144)), lessThan(4), reason: 'at ${s.t.toStringAsFixed(2)} s');
    }
    expect(lineMetres([for (final s in standing) s.car.at]), lessThan(0.5), reason: 'still, for half a minute of wandering fixes');
  });

  group('when it listens', () {
    testWidgets('only while the ride has a car under way', (tester) async {
      await show(tester, ride(road, status: 'open'));
      await tester.pump();
      expect(asked, 0, reason: 'no driver yet: nothing to listen for');
      await show(tester, ride(road, car: road.at(0), sent: t0));
      await tester.pump();
      expect(asked, 1);
      expect(fixes.hasListener, isTrue);
      // Through the trip, the same listening.
      await show(tester, ride(road, car: road.at(0), sent: t0, status: 'arrived'));
      await show(tester, ride(road, car: road.at(0), sent: t0, status: 'on_trip'));
      await tester.pump();
      expect(asked, 1);
      expect(fixes.hasListener, isTrue);
      // The trip is over: it is let go of.
      await show(tester, ride(road, car: road.at(0), sent: t0, status: 'completed'));
      await tester.pump();
      expect(fixes.hasListener, isFalse);
      expect(asked, 1);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a cancelled ride has no car, whatever was being heard', (tester) async {
      await show(tester, ride(road, car: road.at(0), sent: t0));
      await tester.pump();
      for (var f = 0; f < 5 * 60; f++) {
        clock = t0.add(frame * f);
        if (f % 60 == 0) fixes.add((at: road.at(14.0 * f / 60), speed: 14, course: 0, time: clock, accuracy: 5));
        await tester.pump(frame);
      }
      expect(metresApart(rideMap(tester).driverLive!.value!.at, road.at(14.0 * 5)), lessThan(3), reason: 'followed live');
      final was = fixes;
      await show(tester, ride(road, car: road.at(0), sent: t0, status: 'cancelled'));
      await tester.pump(const Duration(seconds: 1));
      expect(was.hasListener, isFalse);
      expect(rideMap(tester).driverLive!.value, isNull);
      expect(find.byKey(const ValueKey('driver-car')), findsNothing);
    });

    testWidgets('given back and taken by another driver: listened to afresh', (tester) async {
      await show(tester, ride(road, car: road.at(0), sent: t0));
      await tester.pump();
      expect(asked, 1);
      await show(tester, ride(road, status: 'open'));
      await tester.pump();
      expect(rideMap(tester).driverLive!.value, isNull);
      await show(tester, ride(road, car: road.at(100), sent: t0.add(const Duration(seconds: 30))));
      await tester.pump();
      expect(asked, 2);
      expect(fixes.hasListener, isTrue);
      expect(rideMap(tester).driverLive!.value!.at, road.at(100));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets("the driver's own map follows its own phone, and listens for none of this", (tester) async {
      await show(tester, ride(road, car: road.at(0), sent: t0, status: 'on_trip'), driverAt: road.at(0));
      await tester.pump(const Duration(seconds: 1));
      expect(asked, 0);
    });
  });
}
