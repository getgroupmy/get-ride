// How a map draws a car it only hears from every few seconds.
//
// A passenger's map is told where their driver is by the driver's phone, which
// sends its position every few seconds (the ride's live columns). Drawn as they
// come, the car stands still and then hops: forty metres at a time in town, a
// hundred and more on a highway.
//
// [CarPlayback] plays each position back instead: the car is drawn driving from
// where it is shown to the position just heard, in about the time the real car
// took to get there — and along the road, where the route it is on is known,
// so a bend is driven round and not cut across. It never runs ahead of what it
// has been told: the car as drawn is where the real one was a few seconds ago,
// moving as it moved. Guessing where it is *now* from a position that old would
// put it past the junction it has just stopped at.
//
// The driver's own map does not need this: it has the phone's GPS itself, a
// fix a second, and follows that (follow_motion.dart).
//
// Pure, with no clock or ticker of its own: see test/car_playback_test.dart.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'follow_motion.dart';

/// The shortest and longest time (seconds) a position is played back over,
/// whatever the time between it and the one before came to: two that arrive
/// together are still driven between, and a car that crept fifteen metres in a
/// minute of traffic is not drawn taking a minute over it.
const playbackLeastSeconds = 0.5;
const playbackMostSeconds = 12.0;

/// How much longer than the time between two positions the car is given to
/// drive between them: a little, so that the next one has usually arrived
/// before it gets there and it never stands waiting on a road it is driving
/// down.
const playbackStretch = 1.1;

/// The fastest a car is taken to have driven between two positions (m/s, about
/// 250 km/h). One farther off than that is not somewhere it drove to in the
/// time: the car is put there.
const playbackTopSpeed = 70.0;

/// With nothing to say how long the car took, a position farther than this
/// (metres) from where it is drawn is a jump too.
const playbackJumpMetres = 400.0;

/// After this long with nothing heard (seconds), a position some way off
/// ([followSnapMetres]) is where the car has got to meanwhile, not a drive to
/// play back at speed.
const playbackSilenceSeconds = 30.0;

/// How close to the road (metres) a position counts as on it. A phone's GPS is
/// a few metres out on a good road and a few tens between tall buildings.
const playbackRoadMetres = 30.0;

/// How far past either end of the road (metres) a position still counts as on
/// it. Short of where the road starts, or on past where it ends (a car that
/// pulls up a little beyond the pickup), it is somewhere the road does not go:
/// drawn where it is, not held at the road's end.
const playbackRoadEndMetres = 5.0;

/// A position stamped earlier than the one before by less than this (seconds)
/// arrived out of order and is dropped; earlier than that and the driver's
/// clock has been moved, so it is taken.
const playbackStaleSeconds = 30.0;

/// The point of a road nearest somewhere: the segment it is on ([index] is the
/// segment's first point), how far off the road that somewhere is ([offBy],
/// metres), how far down the road the point is ([along], metres), and whether
/// it is one of the road's two ends ([end]: the somewhere is then off the end
/// of the road rather than beside it).
typedef RoadSpot = ({int index, LatLng point, double offBy, double along, bool end});

/// Whether [spot] is of somewhere on its road: beside it ([playbackRoadMetres])
/// and not off either end of it ([playbackRoadEndMetres]).
bool onRoad(RoadSpot spot) =>
    spot.offBy <= playbackRoadMetres && !(spot.end && spot.offBy > playbackRoadEndMetres);

const _earthMetres = 6378137.0;
const _radians = math.pi / 180;

/// Where on [road] is nearest [at]; null when [road] is not a line.
///
/// Flat-earth arithmetic about [at], which is exact where it matters (the
/// segments near it) and cheap enough for a road of thousands of points.
RoadSpot? nearestOnRoad(List<LatLng> road, LatLng at) {
  if (road.length < 2) return null;
  final shrink = math.cos(at.latitude * _radians);
  double x(LatLng p) => (p.longitude - at.longitude) * _radians * shrink * _earthMetres;
  double y(LatLng p) => (p.latitude - at.latitude) * _radians * _earthMetres;
  var best = double.infinity, bestPart = 0.0, bestAlong = 0.0, along = 0.0;
  var bestIndex = 0;
  var ax = x(road.first), ay = y(road.first);
  for (var i = 0; i < road.length - 1; i++) {
    final bx = x(road[i + 1]), by = y(road[i + 1]);
    final dx = bx - ax, dy = by - ay;
    final squared = dx * dx + dy * dy;
    final length = math.sqrt(squared);
    final part = squared == 0 ? 0.0 : ((-ax * dx - ay * dy) / squared).clamp(0.0, 1.0).toDouble();
    final px = ax + dx * part, py = ay + dy * part;
    final off = math.sqrt(px * px + py * py);
    if (off < best) {
      best = off;
      bestIndex = i;
      bestPart = part;
      bestAlong = along + length * part;
    }
    along += length;
    ax = bx;
    ay = by;
  }
  return (
    index: bestIndex,
    point: pointBetween(road[bestIndex], road[bestIndex + 1], bestPart),
    offBy: best,
    along: bestAlong,
    end: (bestIndex == 0 && bestPart <= 0) || (bestIndex == road.length - 2 && bestPart >= 1),
  );
}

/// The stretch of [road] from [from] to [to], a spot farther down it.
List<LatLng> roadBetween(List<LatLng> road, RoadSpot from, RoadSpot to) => [
  from.point,
  for (var i = from.index + 1; i <= to.index; i++) road[i],
  to.point,
];

/// The length of a line, in metres.
double lineMetres(List<LatLng> line) {
  var metres = 0.0;
  for (var i = 0; i < line.length - 1; i++) {
    metres += metresApart(line[i], line[i + 1]);
  }
  return metres;
}

/// Where a car is drawn, a frame at a time, from positions heard every few
/// seconds (see the top of this file). Give it each as it comes ([take]), the
/// road the car is on when that is known ([road]) and the length of each frame
/// ([advance]); [shown] is where to draw it and [heading] the way it faces.
class CarPlayback {
  /// Where the car is drawn; null until the first position.
  LatLng? shown;

  /// The way the car is drawn facing, degrees clockwise from north: the way
  /// it is driving, or where its driver's phone said it pointed before it had
  /// moved. Null until either is known.
  double? heading;

  /// The latest position heard, as it came; null until the first.
  LatLng? get latest => _latest;
  LatLng? _latest;
  DateTime? _sentAt, _heardAt;

  /// The way still to drive to the latest position, from where the car was
  /// drawn when it was heard ([_done] metres of its [_length] driven so far),
  /// and the speed it is driven at (m/s).
  List<LatLng> _path = const [];
  double _length = 0, _done = 0, _speed = 0;

  /// A heading to turn to on the spot: a position that moved the car nowhere
  /// came with one.
  double? _turnTo;

  /// The road the car is on, and one it has been put on since but has not been
  /// drawn reaching yet (a new route starts where the real car is, which the
  /// drawn one gets to a few seconds later).
  List<LatLng>? _road, _nextRoad;

  /// The road the car is driving, as its route has it: a position near it is
  /// driven to along it. Null when there is none (no route, or none any more).
  set road(List<LatLng>? road) {
    if (road == null || road.length < 2) {
      _road = _nextRoad = null;
    } else if (_road == null) {
      _road = road;
    } else if (!identical(road, _road)) {
      _nextRoad = road;
    }
  }

  /// The way the car still has to drive to the latest position, starting where
  /// it is drawn: for a line on the map that reaches the car. Empty when it is
  /// there.
  List<LatLng> get ahead {
    final at = shown;
    if (at == null || _done >= _length) return const [];
    return [at, ..._rest(_done)];
  }

  /// A position has been heard: where the car was [sentAt] by its driver's
  /// clock (null when it came without a time), [heardAt] by this phone's, and
  /// the [heading] its driver's phone reported with it.
  ///
  /// Returns false when it was dropped (one from before the latest: not news).
  bool take(LatLng at, {double? heading, DateTime? sentAt, required DateTime heardAt}) {
    final sentBefore = _sentAt;
    if (sentAt != null && sentBefore != null) {
      final back = sentBefore.difference(sentAt).inMicroseconds / Duration.microsecondsPerSecond;
      if (back > 0 && back < playbackStaleSeconds) return false;
    }
    final from = shown, before = _latest;
    // Nowhere new: only the way it faces can have changed. The drive to where
    // it was last heard carries on as it was, and the time to the next
    // position is still counted from when it got there.
    if (from != null && before != null && metresApart(before, at) < 0.05) {
      _turnTo = heading;
      return true;
    }
    final gap = _since(sentAt, heardAt);
    _latest = at;
    _sentAt = sentAt;
    _heardAt = heardAt;
    if (from == null) {
      shown = at;
      this.heading = heading;
      return true;
    }
    final path = _pathTo(from, at);
    final length = lineMetres(path);
    final jumped = gap == null
        ? length > playbackJumpMetres
        : length > playbackTopSpeed * math.max(gap, 1) ||
              (gap > playbackSilenceSeconds && length > followSnapMetres);
    if (jumped) {
      shown = path.last;
      _path = const [];
      _length = _done = _speed = 0;
      if (heading != null) this.heading = heading;
      _turnTo = null;
      return true;
    }
    final seconds = (gap ?? 0).clamp(playbackLeastSeconds, playbackMostSeconds) * playbackStretch;
    _path = path;
    _length = length;
    _done = 0;
    _speed = length / seconds;
    _turnTo = null;
    return true;
  }

  /// One frame, [dt] seconds long. Returns whether there is more to come —
  /// false once the car has reached the latest position and faces the way it
  /// should, so frames can stop.
  bool advance(double dt) {
    if (shown == null) return false;
    var busy = false;
    // On the move it faces the way the road runs; once there, the way it was
    // last said to face, if it was.
    var facing = _turnTo;
    if (_done < _length) {
      _done = math.min(_length, _done + _speed * dt);
      final at = _at(_done);
      shown = at.point;
      facing = at.bearing ?? heading;
      // There, with a turn on the spot still to make: not done yet.
      busy = _done < _length || _turnTo != null;
    }
    final faced = heading;
    if (facing != null) {
      if (faced == null) {
        heading = facing;
      } else {
        final turn = shortestTurn(faced, facing);
        if (turn.abs() < 0.05) {
          heading = facing;
        } else {
          heading = (faced + turnStep(turn, dt) + 360) % 360;
          busy = true;
        }
      }
    }
    return busy;
  }

  /// Puts the car at [at], facing [heading], with nowhere to drive to: it was
  /// being drawn there by something else (the driver's fixes followed live,
  /// live_ride_map.dart), and is played back from there on. [sentAt] and
  /// [heardAt] are when it was last heard from, by its driver's clock and by
  /// this phone's, for the time the next position took.
  void startAt(LatLng at, {double? heading, DateTime? sentAt, DateTime? heardAt}) {
    shown = _latest = at;
    this.heading = heading;
    _sentAt = sentAt;
    _heardAt = heardAt;
    _turnTo = null;
    _path = const [];
    _length = _done = _speed = 0;
  }

  /// Forgets the car: there is none on the map any more.
  void clear() {
    shown = heading = _latest = _sentAt = _heardAt = _turnTo = null;
    _path = const [];
    _length = _done = _speed = 0;
  }

  /// Seconds between the position before and this one: by the driver's clock,
  /// which a slow network does not stretch; else by when each was heard. Null
  /// when neither says.
  double? _since(DateTime? sentAt, DateTime heardAt) {
    double? between(DateTime? earlier, DateTime? later) => earlier == null || later == null
        ? null
        : later.difference(earlier).inMicroseconds / Duration.microsecondsPerSecond;
    final sent = between(_sentAt, sentAt);
    if (sent != null && sent > 0) return sent;
    final heard = between(_heardAt, heardAt);
    return heard != null && heard > 0 ? heard : null;
  }

  /// The way from where the car is drawn ([from]) to [at]: down the road when
  /// both are on it and [at] is farther along, else what is left of the way it
  /// was already driving and straight on from there — so a position heard
  /// before the last was reached is still driven through, not past.
  List<LatLng> _pathTo(LatLng from, LatLng at) {
    // The drawn car has reached the road it was put on since: that is the road
    // it is on from here.
    final next = _nextRoad;
    if (next != null) {
      final spot = nearestOnRoad(next, from);
      if (spot != null && onRoad(spot) && spot.along > 1) {
        _road = next;
        _nextRoad = null;
      }
    }
    final chord = metresApart(from, at);
    for (final road in [_road, _nextRoad]) {
      if (road == null) continue;
      final a = nearestOnRoad(road, from), b = nearestOnRoad(road, at);
      if (a == null || b == null) continue;
      if (!onRoad(a) || !onRoad(b)) continue;
      // Back down the road is not the way the route goes.
      if (b.along < a.along - 1) continue;
      final between = roadBetween(road, a, b);
      // A road that doubles back on itself is nearest in two places: the long
      // way round between them is not the way the car came.
      if (lineMetres(between) > chord * 4 + 100) continue;
      if (!identical(road, _road)) {
        _road = road;
        _nextRoad = null;
      }
      return [from, ...between];
    }
    return [from, ..._rest(_done), at];
  }

  /// The points of [_path] past [done] metres along it.
  List<LatLng> _rest(double done) {
    var left = done;
    for (var i = 0; i < _path.length - 1; i++) {
      final length = metresApart(_path[i], _path[i + 1]);
      if (left < length) return _path.sublist(i + 1);
      left -= length;
    }
    return const [];
  }

  /// The point [done] metres along [_path], and the way the road runs there
  /// (null on a stretch too short to say).
  ({LatLng point, double? bearing}) _at(double done) {
    var left = done;
    double? bearing;
    for (var i = 0; i < _path.length - 1; i++) {
      final a = _path[i], b = _path[i + 1];
      final length = metresApart(a, b);
      if (length >= 0.5) bearing = bearingBetween(a, b);
      if (left <= length) {
        return (point: length <= 0 ? b : pointBetween(a, b, (left / length).clamp(0.0, 1.0).toDouble()), bearing: bearing);
      }
      left -= length;
    }
    return (point: _path.last, bearing: bearing);
  }
}
