// The passenger's view of the car (core/car_playback.dart): a position heard
// every few seconds, drawn as a car driving. A true car is driven down a road
// here, its position sent the way a driver's phone sends it, and the car as
// drawn is checked a frame at a time against it.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/car_playback.dart';
import 'package:get_ride/src/core/follow_motion.dart';
import 'package:latlong2/latlong.dart';

const start = LatLng(3.1500, 101.7000);
final t0 = DateTime.utc(2026, 11, 22, 4);
const frame = 1 / 60;

/// A road: a line, and where a car [metres] down it is.
class Road {
  Road(this.points);
  final List<LatLng> points;

  /// North [north] metres, then east [east] metres: one right-angle bend.
  factory Road.bend({double north = 300, double east = 300}) {
    final corner = movedAlong(start, north, 0);
    return Road([start, corner, movedAlong(corner, east, 90)]);
  }

  /// Due north for [metres].
  factory Road.straight([double metres = 3000]) => Road([start, movedAlong(start, metres, 0)]);

  double get length => lineMetres(points);

  LatLng at(double metres) {
    var left = metres.clamp(0.0, length).toDouble();
    for (var i = 0; i < points.length - 1; i++) {
      final l = metresApart(points[i], points[i + 1]);
      if (left <= l) return pointBetween(points[i], points[i + 1], l == 0 ? 0 : left / l);
      left -= l;
    }
    return points.last;
  }

  double offBy(LatLng p) => nearestOnRoad(points, p)!.offBy;
  double along(LatLng p) => nearestOnRoad(points, p)!.along;
}

/// What a run saw: the car as drawn, each frame.
typedef Frame = ({double t, LatLng shown, double? heading, double step, bool busy});

/// Drives a car down [road] — [metresAt] says how far it has got at a time —
/// sending its position every [every] seconds, each heard [delay] later (by
/// its number), and plays the car back a frame at a time for [seconds].
List<Frame> run(
  CarPlayback car,
  Road road, {
  required double Function(double t) metresAt,
  double every = 5,
  double seconds = 60,
  double Function(int n)? delay,
  bool stamped = true,
  bool Function(int n)? sent,
}) {
  final frames = <Frame>[];
  final heard = <(double, int)>[];
  for (var n = 0; n * every <= seconds; n++) {
    if (sent != null && !sent(n)) continue;
    heard.add((n * every + (delay?.call(n) ?? 0.05), n));
  }
  heard.sort((a, b) => a.$1.compareTo(b.$1));
  var next = 0;
  LatLng? was;
  for (var t = 0.0; t <= seconds; t += frame) {
    while (next < heard.length && heard[next].$1 <= t) {
      final (at, n) = heard[next++];
      final sentAt = t0.add(Duration(microseconds: (n * every * 1e6).round()));
      car.take(
        road.at(metresAt(n * every)),
        sentAt: stamped ? sentAt : null,
        heardAt: t0.add(Duration(microseconds: (at * 1e6).round())),
      );
    }
    final busy = car.advance(frame);
    final shown = car.shown;
    if (shown == null) continue;
    frames.add((t: t, shown: shown, heading: car.heading, step: was == null ? 0 : metresApart(was, shown), busy: busy));
    was = shown;
  }
  return frames;
}

void main() {
  group('the road', () {
    test('the nearest point of a road, how far off it and how far down it', () {
      final road = Road.bend();
      final beside = movedAlong(movedAlong(start, 120, 0), 8, 90);
      final spot = nearestOnRoad(road.points, beside)!;
      expect(spot.index, 0);
      expect(spot.offBy, closeTo(8, 0.05));
      expect(spot.along, closeTo(120, 0.05));
      final past = movedAlong(road.points[1], 40, 90);
      expect(nearestOnRoad(road.points, past)!.index, 1);
      expect(nearestOnRoad(road.points, past)!.along, closeTo(340, 0.05));
      expect(nearestOnRoad([start], start), isNull);
    });

    test('off the end of a road is not on it', () {
      final road = Road.bend();
      expect(onRoad(nearestOnRoad(road.points, movedAlong(road.at(120), 20, 90))!), isTrue, reason: 'beside it');
      expect(onRoad(nearestOnRoad(road.points, movedAlong(road.at(120), 45, 90))!), isFalse, reason: 'too far to the side');
      // Eleven metres short of where it starts, and as far on past where it ends.
      final short = nearestOnRoad(road.points, movedAlong(start, 11, 180))!;
      expect(short.end, isTrue);
      expect(onRoad(short), isFalse);
      expect(onRoad(nearestOnRoad(road.points, movedAlong(road.points.last, 11, 90))!), isFalse);
      // A couple of metres past an end is the GPS, not the car.
      expect(onRoad(nearestOnRoad(road.points, movedAlong(road.points.last, 2, 90))!), isTrue);
      expect(onRoad(nearestOnRoad(road.points, start)!), isTrue);
    });

    test('a car that drives on past the end of its road is drawn where it stops', () {
      final road = Road.straight(300);
      final car = CarPlayback()..road = road.points;
      car.take(road.at(250), sentAt: t0, heardAt: t0);
      final past = movedAlong(road.points.last, 14, 0);
      car.take(past, sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5)));
      while (car.advance(frame)) {}
      expect(metresApart(car.shown!, past), lessThan(0.05), reason: 'not held at the end of the road');
    });

    test('the stretch of a road between two spots on it', () {
      final road = Road.bend();
      final a = nearestOnRoad(road.points, road.at(250))!, b = nearestOnRoad(road.points, road.at(380))!;
      final between = roadBetween(road.points, a, b);
      expect(between, hasLength(3), reason: 'through the corner');
      expect(lineMetres(between), closeTo(130, 0.1));
    });
  });

  group('driving', () {
    test('at a steady speed the car never stops or jumps, a few seconds behind the real one', () {
      const v = 14.0;
      final road = Road.straight();
      final frames = run(CarPlayback(), road, metresAt: (t) => v * t);
      final settled = frames.where((f) => f.t > 12).toList();
      for (final f in settled) {
        expect(f.step / frame, inInclusiveRange(v * 0.85, v * 1.15), reason: 'at ${f.t.toStringAsFixed(2)} s');
        final behind = (v * f.t - road.along(f.shown)) / v;
        expect(behind, inInclusiveRange(4.9, 6.2), reason: 'a position and a bit behind, at ${f.t.toStringAsFixed(2)} s');
      }
    });

    test('positions that come unevenly are still one drive', () {
      const v = 11.0;
      final road = Road.straight();
      // Each heard up to 0.4 s late or early of the last.
      final frames = run(
        CarPlayback(),
        road,
        metresAt: (t) => v * t,
        delay: (n) => 0.1 + 0.4 * ((n * 7919) % 10) / 10,
      );
      var along = 0.0;
      for (final f in frames.where((f) => f.t > 12)) {
        expect(f.step, greaterThan(0), reason: 'never standing, at ${f.t.toStringAsFixed(2)} s');
        expect(f.step / frame, lessThan(v * 1.35));
        final now = road.along(f.shown);
        expect(now, greaterThanOrEqualTo(along - 1e-6), reason: 'never back');
        along = now;
      }
    });

    test('speeding up and slowing down are played as they were driven', () {
      final road = Road.straight();
      // 8 m/s, speeding up to 20 over 20 s from the tenth second.
      double metresAt(double t) {
        if (t <= 10) return 8 * t;
        final s = math.min(t - 10, 20.0);
        return 80 + 8 * s + 0.3 * s * s + (t > 30 ? 20 * (t - 30) : 0);
      }

      final frames = run(CarPlayback(), road, metresAt: metresAt);
      for (final f in frames.where((f) => f.t > 12)) {
        // Where the real car was 5.5 s earlier, give or take a position's worth.
        final real = metresAt(f.t - 5.5);
        expect(road.along(f.shown), closeTo(real, 14), reason: 'at ${f.t.toStringAsFixed(2)} s');
        expect(f.step, greaterThan(0));
      }
    });
  });

  group('the road it is on', () {
    test('a bend is driven round, not cut across', () {
      const v = 14.0;
      final road = Road.bend();
      final car = CarPlayback()..road = road.points;
      final frames = run(car, road, metresAt: (t) => v * t);
      for (final f in frames) {
        expect(road.offBy(f.shown), lessThan(0.05), reason: 'on the road at ${f.t.toStringAsFixed(2)} s');
      }
      expect(metresApart(frames.last.shown, road.points.last), lessThan(0.05), reason: 'and to the end of it');
    });

    test('without a road, a bend is cut: the road is what keeps it on', () {
      const v = 14.0;
      final road = Road.bend();
      final frames = run(CarPlayback(), road, metresAt: (t) => v * t, seconds: 50);
      expect(frames.map((f) => road.offBy(f.shown)).reduce(math.max), greaterThan(10));
    });

    test('it faces the way it drives, and turns steadily through the bend', () {
      const v = 14.0;
      final road = Road.bend();
      final car = CarPlayback()..road = road.points;
      final frames = run(car, road, metresAt: (t) => v * t, seconds: 50);
      double? was;
      for (final f in frames.where((f) => f.heading != null)) {
        if (was != null) {
          expect(shortestTurn(was, f.heading!).abs(), lessThanOrEqualTo(followMaxTurnPerSecond * frame + 1e-9));
        }
        was = f.heading;
      }
      final north = frames.firstWhere((f) => road.along(f.shown) > 150);
      final east = frames.firstWhere((f) => road.along(f.shown) > 400);
      expect(shortestTurn(north.heading!, 0).abs(), lessThan(0.5));
      expect(shortestTurn(east.heading!, 90).abs(), lessThan(0.5));
    });

    test('a position beside the road is drawn on it; one well off it is drawn where it is', () {
      final road = Road.straight();
      final car = CarPlayback()..road = road.points;
      car.take(road.at(0), sentAt: t0, heardAt: t0);
      // 12 m to the side, 70 m on: the GPS a little out.
      car.take(movedAlong(road.at(70), 12, 90), sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5)));
      for (var i = 0; i < 600; i++) {
        car.advance(frame);
        expect(road.offBy(car.shown!), lessThan(0.05));
      }
      expect(road.along(car.shown!), closeTo(70, 0.1));
      // 80 m to the side: it has left the road.
      final off = movedAlong(road.at(140), 80, 90);
      car.take(off, sentAt: t0.add(const Duration(seconds: 10)), heardAt: t0.add(const Duration(seconds: 10)));
      for (var i = 0; i < 600; i++) {
        car.advance(frame);
      }
      expect(metresApart(car.shown!, off), lessThan(0.05));
    });

    test('a new route is taken up once the drawn car has reached it', () {
      const v = 14.0;
      final whole = Road.bend(north: 400, east: 400);
      final car = CarPlayback()..road = whole.points;
      final frames = <LatLng>[];
      for (var t = 0.0, n = 0; t <= 50; t += frame) {
        if (t >= n * 5) {
          final at = whole.at(v * n * 5);
          final when = t0.add(Duration(seconds: n * 5));
          car.take(at, sentAt: when, heardAt: when);
          // As the map does: a route asked for again from where the car is,
          // which the drawn car is still some way short of.
          if (n == 3 || n == 6) car.road = [at, ...whole.points.where((p) => whole.along(p) > whole.along(at) + 1)];
          n++;
        }
        car.advance(frame);
        frames.add(car.shown!);
      }
      for (final p in frames) {
        expect(whole.offBy(p), lessThan(0.05), reason: 'never off the road, whichever route says where it runs');
      }
      // A position behind the real car, less the little it is always still short of it.
      expect(whole.along(frames.last), inInclusiveRange(v * 45 - 9, v * 45 + 0.5));
    });
  });

  group('what is heard', () {
    test('a late position: the car waits where it was last heard, and never goes back', () {
      const v = 14.0;
      final road = Road.straight();
      // The third is 4 s late.
      final frames = run(CarPlayback(), road, metresAt: (t) => v * t, delay: (n) => n == 3 ? 4 : 0.05, seconds: 40);
      var along = 0.0;
      var stood = 0;
      for (final f in frames) {
        final now = road.along(f.shown);
        expect(now, greaterThanOrEqualTo(along - 1e-6));
        along = now;
        if (f.t > 6 && f.step == 0) stood++;
      }
      expect(stood, greaterThan(0), reason: 'it had nowhere to go until it was heard from');
      expect(road.along(frames.last.shown), greaterThan(v * 33));
    });

    test('two heard together are both driven through', () {
      final a = movedAlong(start, 60, 0), b = movedAlong(a, 60, 90);
      final car = CarPlayback()..take(start, sentAt: t0, heardAt: t0);
      // Held up on the way and delivered at once.
      final heard = t0.add(const Duration(seconds: 10));
      car.take(a, sentAt: t0.add(const Duration(seconds: 5)), heardAt: heard);
      car.take(b, sentAt: t0.add(const Duration(seconds: 10)), heardAt: heard);
      var nearest = double.infinity;
      for (var i = 0; i < 900; i++) {
        car.advance(frame);
        nearest = math.min(nearest, metresApart(car.shown!, a));
      }
      expect(nearest, lessThan(0.3), reason: 'through the first, not straight to the second');
      expect(metresApart(car.shown!, b), lessThan(0.05));
    });

    test('a car that stops is drawn stopping there, and the frames end', () {
      const v = 12.0;
      final road = Road.straight();
      // Drives 20 s and stops: nothing is sent from a car that is not moving.
      final frames = run(
        CarPlayback(),
        road,
        metresAt: (t) => v * math.min(t, 20),
        sent: (n) => n * 5 <= 20,
        seconds: 40,
      );
      expect(road.along(frames.last.shown), closeTo(v * 20, 0.05));
      expect(frames.last.busy, isFalse);
      expect(frames.where((f) => f.t > 30).every((f) => f.step == 0 && !f.busy), isTrue);
    });

    test('too far to have driven is a jump, there at once', () {
      final car = CarPlayback()..take(start, sentAt: t0, heardAt: t0);
      final far = movedAlong(start, 2000, 45);
      car.take(far, sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5)));
      expect(car.shown, far);
      expect(car.advance(frame), isFalse);
    });

    test('after a long silence a far position is a jump, a near one a drive', () {
      final car = CarPlayback()..take(start, sentAt: t0, heardAt: t0);
      final near = movedAlong(start, 15, 0);
      car.take(near, sentAt: t0.add(const Duration(seconds: 60)), heardAt: t0.add(const Duration(seconds: 60)));
      expect(car.shown, start, reason: 'fifteen metres is driven');
      var frames = 0;
      while (car.advance(frame)) {
        frames++;
      }
      expect(frames * frame, closeTo(playbackMostSeconds * playbackStretch, 0.1), reason: 'not a minute over it');
      expect(metresApart(car.shown!, near), lessThan(0.05));
      final far = movedAlong(near, 600, 0);
      car.take(far, sentAt: t0.add(const Duration(seconds: 120)), heardAt: t0.add(const Duration(seconds: 120)));
      expect(car.shown, far);
    });

    test('with no time on them, positions are spaced by when they are heard', () {
      const v = 14.0;
      final road = Road.straight();
      final frames = run(CarPlayback(), road, metresAt: (t) => v * t, stamped: false);
      for (final f in frames.where((f) => f.t > 12)) {
        expect(f.step / frame, inInclusiveRange(v * 0.85, v * 1.15));
      }
    });

    test('heard at the same moment with no time on them: driven in the shortest time, not jumped', () {
      final car = CarPlayback()..take(start, heardAt: t0);
      final next = movedAlong(start, 150, 30);
      car.take(next, heardAt: t0);
      expect(car.shown, start);
      var frames = 0;
      while (car.advance(frame)) {
        frames++;
      }
      expect(frames * frame, closeTo(playbackLeastSeconds * playbackStretch, 0.05));
      expect(metresApart(car.shown!, next), lessThan(0.05));
      // And a single long frame gets it there just the same.
      final again = movedAlong(next, 150, 30);
      car.take(again, heardAt: t0);
      car.advance(1);
      expect(metresApart(car.shown!, again), lessThan(0.05));
    });

    test('one from before the latest is dropped; one from long before means the clock moved', () {
      final car = CarPlayback()..take(start, sentAt: t0, heardAt: t0);
      final on = movedAlong(start, 60, 0);
      expect(car.take(on, sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5))), isTrue);
      final stale = movedAlong(start, 30, 0);
      expect(car.take(stale, sentAt: t0.add(const Duration(seconds: 2)), heardAt: t0.add(const Duration(seconds: 6))), isFalse);
      expect(car.latest, on);
      expect(car.take(stale, sentAt: t0.subtract(const Duration(minutes: 5)), heardAt: t0.add(const Duration(seconds: 9))), isTrue);
      expect(car.latest, stale);
    });

    test('a heading with nowhere new turns the car on the spot and leaves its drive alone', () {
      final car = CarPlayback()..take(start, heading: 0, sentAt: t0, heardAt: t0);
      expect(car.heading, 0);
      final on = movedAlong(start, 70, 0);
      car.take(on, heading: 0, sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5)));
      for (var i = 0; i < 60; i++) {
        car.advance(frame);
      }
      final halfway = car.shown!;
      // The same place again a second later, now said to face east.
      car.take(on, heading: 90, sentAt: t0.add(const Duration(seconds: 6)), heardAt: t0.add(const Duration(seconds: 6)));
      car.advance(frame);
      expect(metresApart(halfway, car.shown!), closeTo(70 / (5 * playbackStretch) * frame, 0.01), reason: 'the same speed');
      expect(shortestTurn(car.heading!, 0).abs(), lessThan(0.5), reason: 'facing the way it drives while it drives');
      while (car.advance(frame)) {}
      expect(metresApart(car.shown!, on), lessThan(0.05));
      expect(car.heading, 90, reason: 'and round to where it was said to face once it is there');
    });

    test('the way still to drive starts at the car, for the line on the map', () {
      final road = Road.bend();
      final car = CarPlayback()..road = road.points;
      car.take(road.at(250), sentAt: t0, heardAt: t0);
      expect(car.ahead, isEmpty);
      car.take(road.at(380), sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5)));
      for (var i = 0; i < 60; i++) {
        car.advance(frame);
      }
      final ahead = car.ahead;
      expect(ahead.first, car.shown);
      expect(metresApart(ahead.last, road.at(380)), lessThan(0.05));
      expect(lineMetres(ahead), closeTo(130 - 130 / (5 * playbackStretch), 0.5));
      while (car.advance(frame)) {}
      expect(car.ahead, isEmpty);
    });

    test('cleared, there is no car until one is heard from again', () {
      final car = CarPlayback()..take(start, heading: 10, sentAt: t0, heardAt: t0);
      car.clear();
      expect(car.shown, isNull);
      expect(car.heading, isNull);
      expect(car.advance(frame), isFalse);
      final at = movedAlong(start, 900, 0);
      car.take(at, sentAt: t0.add(const Duration(seconds: 1)), heardAt: t0.add(const Duration(seconds: 1)));
      expect(car.shown, at, reason: 'the first position is where it is, not a drive from the old one');
    });

    test('put somewhere by whatever was drawing it before, it is played back on from there', () {
      // It was being followed live and drawn here, heard from four seconds ago
      // by its driver's clock.
      final was = movedAlong(start, 40, 0);
      final car = CarPlayback()..take(start, heading: 0, sentAt: t0, heardAt: t0);
      // On its way somewhere else, a second into a drive of two hundred metres.
      car.take(movedAlong(start, 200, 90), sentAt: t0.add(const Duration(seconds: 5)), heardAt: t0.add(const Duration(seconds: 5)));
      expect(car.advance(1), isTrue);
      expect(car.ahead, isNotEmpty);
      car.startAt(was, heading: 12, sentAt: t0.add(const Duration(seconds: 20)), heardAt: t0.add(const Duration(seconds: 21)));
      expect(car.shown, was);
      expect(car.heading, 12);
      expect(car.latest, was);
      expect(car.ahead, isEmpty, reason: 'the drive it was on is forgotten');
      expect(car.advance(frame), isFalse, reason: 'and it has nowhere to go until it is heard from');
      expect(car.shown, was);
      // The next position is driven to from there, in the time since.
      final next = movedAlong(start, 100, 0);
      expect(car.take(next, sentAt: t0.add(const Duration(seconds: 24)), heardAt: t0.add(const Duration(seconds: 25))), isTrue);
      var seconds = 0.0;
      while (car.advance(frame)) {
        seconds += frame;
        expect(metresApart(car.shown!, start), inInclusiveRange(40 - 1e-6, 100 + 1e-6), reason: 'straight on from where it was');
      }
      expect(car.shown, next);
      expect(seconds, closeTo(4 * playbackStretch, 0.05), reason: 'four seconds by its driver\'s clock');
      // One stamped before it was put there is from before: dropped.
      expect(car.take(start, sentAt: t0.add(const Duration(seconds: 19)), heardAt: t0.add(const Duration(seconds: 26))), isFalse);
    });

    test('put somewhere with no time from its driver, the next position is spaced by when each was heard', () {
      final car = CarPlayback()..startAt(start, heading: 0, heardAt: t0);
      final next = movedAlong(start, 60, 0);
      // Stamped by another clock altogether: only when it was heard counts.
      expect(car.take(next, sentAt: null, heardAt: t0.add(const Duration(seconds: 6))), isTrue);
      var seconds = 0.0;
      while (car.advance(frame)) {
        seconds += frame;
      }
      expect(car.shown, next);
      expect(seconds, closeTo(6 * playbackStretch, 0.05));
    });
  });
}
