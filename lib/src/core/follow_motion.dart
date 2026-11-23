// How a map follows the device between the fixes its GPS gives.
//
// A phone's GPS reports about once a second, and each fix is about a second old
// by the time the next one lands. Drawing fixes as they come — or gliding to
// each and waiting for the next — makes a dot stop and start, trail whoever is
// carrying the phone and cut corners. A navigation app instead works out, every
// frame, where the device is *now*: the latest fix carried forward along the
// course the GPS measured, at the speed it measured, for exactly as long as the
// fix is old ([deadReckon]) — counting the time it took to reach the app
// ([fixLateness]) — with the drawn point eased onto that estimate so the small
// correction each new fix brings is a glide. A device standing still is left
// standing still ([settledFix]).
//
// [FixFollower] does that for one dot; the driver's map (driver_home_map.dart)
// puts its camera on it and the rider's home map (live_position.dart) draws its
// own dot with it. The arithmetic is pure: see test/driver_follow_test.dart.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// How long the drawn position takes to close most of the gap to where the
/// device is: short enough that the dot keeps up, long enough that the small
/// correction when a new fix lands is a glide and not a jump.
const followEaseSeconds = 0.25;

/// How long after a fix the device is still carried forward at its speed. Two
/// fixes' worth: a late or missed fix does not stall the dot, and a lost signal
/// does not send it far down a road it may not have taken.
const followCoastSeconds = 2.0;

/// The speed (m/s) below which a fix is not carried forward at all — a GPS at
/// rest reads a little speed along a random course — and the speed from which
/// it is carried in full; between the two it ramps, so nothing switches.
const followCarryFrom = 0.5;
const followCarryFully = 1.5;

/// The hardest acceleration and braking (m/s²) a fix is carried forward with:
/// about what a car does flat out. A wilder figure from two noisy speed
/// readings is held to these.
const followMaxAcceleration = 3.5;
const followMaxBraking = 5.0;

/// Standing still, a GPS goes on wandering a metre or two around the car. A
/// fix closer to the drawn dot than [followRestStill] leaves it where it is;
/// one farther than [followRestMetres] — or than the fix's own accuracy, when
/// that is looser — is somewhere new and is taken as it comes; one in between
/// moves the dot [followRestShare] of the way, so it settles on the middle of
/// where the fixes fall without being seen to move.
const followRestStill = 0.75;
const followRestMetres = 3.0;
const followRestShare = 0.2;

/// A fix no better than this (metres) is not from the GPS at all (Wi-Fi, cell
/// towers): when it comes without a speed it cannot say whether the car is
/// moving, and is treated as one that says it is not.
const followCoarseMetres = 20.0;

/// How many fixes back the follow looks to tell how late one has arrived, and
/// the most lateness (seconds) it makes up for ([fixLateness]).
const followLateWindow = 10;
const followLateMost = 0.5;

/// The most lateness (seconds) made up for in a fix that came from another
/// phone, over the network: one is held up there far longer than a phone holds
/// up its own (a poor signal, the server passing them on in batches).
const followLateMostRemote = 1.5;

/// How much faster than the car itself (m/s) a car followed from another
/// phone's fixes is drawn making up ground it has lost. Its fixes go missing
/// for seconds at a time, as a phone's own do not, and the car is then drawn
/// some way short of where it is: it makes that up as a car would, driving
/// faster for a moment, and not in a single lurch.
const followCatchUpRemote = 15.0;

/// A fix older than the one in hand by less than this (seconds) is dropped: a
/// cached position handed over when the stream restarts, or two that crossed on
/// the way. Older than that and the clock itself has been moved, so it is taken.
const followStaleSeconds = 10.0;

/// Farther than this from where the device is (metres), the drawn position
/// jumps instead of gliding: the app coming back from the background, or the
/// first real fix after a rough one.
const followSnapMetres = 150.0;

/// The ease on the heading the cone is drawn at and the map is turned to (and
/// on where the dot is held on screen): only enough to round off a change of
/// pace, since the heading itself already moves steadily ([headingBetween]).
const followTurnSeconds = 0.25;

/// The fastest the cone and the map turn, degrees a second: well above any
/// turn a car makes, so it only paces the big sweeps — the map swinging round
/// from north-up when the driver sets off.
const followMaxTurnPerSecond = 240.0;

/// How long the map takes to pull in most of the way to the driving zoom.
const followZoomSeconds = 0.5;

/// The shortest and longest time (seconds) a turn from one fix's course to the
/// next is spread over: about the time between two fixes, whatever a late or a
/// doubled fix made of it.
const followTurnOverLeast = 0.5;
const followTurnOverMost = 2.0;

/// The fraction of the way to a target to move in a frame [dt] seconds long,
/// for an ease that closes about 63% of any gap every [seconds]. The same ease
/// at 60 frames a second or 120, or through a slow frame.
double easeFraction(double dt, double seconds) => seconds <= 0 ? 1 : 1 - math.exp(-dt / seconds);

/// The turn from [from] to [to] in degrees the short way round, −180 to 180:
/// `shortestTurn(350, 10) == 20`, `shortestTurn(10, 350) == -20`.
double shortestTurn(double from, double to) => ((to - from + 540) % 360) - 180;

/// The way the driver is heading [ageSeconds] after a fix: turned steadily from
/// [from] (the heading shown when the fix came in) to [to] (the course the fix
/// measured) over [overSeconds] — the time between two fixes — and held there.
///
/// The GPS measures the course once a second. Turning to each as it comes is a
/// lurch a second through every bend; guessing ahead from the last two swings
/// past the end of the bend and back. Spreading each measured turn over the
/// second until the next is steady through a bend and never turns further than
/// the car did.
double headingBetween(double from, double to, {required double ageSeconds, required double overSeconds}) {
  final part = overSeconds <= 0 ? 1.0 : (ageSeconds / overSeconds).clamp(0.0, 1.0).toDouble();
  return (from + shortestTurn(from, to) * part + 360) % 360;
}

/// How far to turn in a frame [dt] seconds long toward a heading [turn] degrees
/// away: eased ([followTurnSeconds]), and no faster than
/// [followMaxTurnPerSecond].
double turnStep(double turn, double dt) {
  final most = followMaxTurnPerSecond * dt;
  return (turn * easeFraction(dt, followTurnSeconds)).clamp(-most, most).toDouble();
}

const _earthMetres = 6378137.0;
const _radians = math.pi / 180;

/// Metres between two points near each other. Flat-earth arithmetic: exact to
/// well under a centimetre over the tens of metres the follow works with, and
/// cheap enough to run every frame.
double metresApart(LatLng a, LatLng b) {
  final east = (b.longitude - a.longitude) * _radians * math.cos((a.latitude + b.latitude) / 2 * _radians);
  final north = (b.latitude - a.latitude) * _radians;
  return math.sqrt(east * east + north * north) * _earthMetres;
}

/// The bearing from [a] to [b] in degrees clockwise from north (0–360).
double bearingBetween(LatLng a, LatLng b) {
  final east = (b.longitude - a.longitude) * math.cos((a.latitude + b.latitude) / 2 * _radians);
  final north = b.latitude - a.latitude;
  return (math.atan2(east, north) / _radians + 360) % 360;
}

/// [from] moved [metres] along [bearingDegrees] (clockwise from north).
LatLng movedAlong(LatLng from, double metres, double bearingDegrees) {
  final bearing = bearingDegrees * _radians;
  final north = metres * math.cos(bearing) / _earthMetres / _radians;
  final east = metres * math.sin(bearing) / (_earthMetres * math.cos(from.latitude * _radians)) / _radians;
  return LatLng(
    (from.latitude + north).clamp(-90.0, 90.0).toDouble(),
    (from.longitude + east + 540) % 360 - 180,
  );
}

/// The point [t] of the way from [a] to [b].
LatLng pointBetween(LatLng a, LatLng b, double t) =>
    LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);

/// How much of a fix's speed to carry it forward by: none while it is as good
/// as stopped ([followCarryFrom]), all of it once clearly moving
/// ([followCarryFully]).
double carryWeight(double speedMps) =>
    ((speedMps - followCarryFrom) / (followCarryFully - followCarryFrom)).clamp(0.0, 1.0).toDouble();

/// Where the device is [ageSeconds] after [fix] was taken: the fix carried
/// forward along the course the GPS measured, at the speed it measured and
/// speeding up or slowing down as it was ([accelMps2], from the change in speed
/// since the fix before) — what a navigation app draws, since a fix is about a
/// second old by the time the next one lands. A braking car is carried no
/// further than where it stops. Stays on the fix without a course or below
/// [followCarryFrom], and stops carrying after [followCoastSeconds].
LatLng deadReckon(
  LatLng fix, {
  required double speedMps,
  required double? courseDegrees,
  required double ageSeconds,
  double accelMps2 = 0,
}) {
  final weight = carryWeight(speedMps);
  if (courseDegrees == null || weight <= 0 || ageSeconds <= 0) return fix;
  var seconds = math.min(ageSeconds, followCoastSeconds);
  if (accelMps2 < 0) seconds = math.min(seconds, speedMps / -accelMps2);
  final metres = speedMps * seconds + accelMps2 * seconds * seconds / 2;
  return movedAlong(fix, weight * math.max(0, metres), courseDegrees);
}

/// Whether a fix says the device is standing still: the GPS measured next to
/// no speed ([followCarryFrom]), or could measure none and is itself only good
/// to tens of metres ([followCoarseMetres]) — a fix that cannot say is treated
/// as one that says it is not moving.
bool fixIsStill({required double? speedMps, required double? accuracyMetres}) =>
    speedMps != null ? carryWeight(speedMps) <= 0 : (accuracyMetres ?? 0) > followCoarseMetres;

/// Where to take a fix as putting the device, given where the dot is [drawn].
///
/// On the move that is the fix. Standing still ([fixIsStill]), a fix that
/// agrees with where the dot already is (inside its own accuracy, and within
/// [followRestMetres] at the least) is the same place measured again: the dot
/// stays put, or drifts a little toward it (see [followRestStill]). Only a fix
/// that puts the car somewhere else moves it. Otherwise a parked car's dot
/// creeps about with every fix, now that there is one a second.
///
/// This is for a device already standing: the fix that first says it has
/// stopped is where it stopped, and is taken as it comes ([FixFollower.take]).
LatLng settledFix(LatLng? drawn, LatLng fix, {required double? speedMps, required double? accuracyMetres}) {
  if (drawn == null) return fix;
  if (!fixIsStill(speedMps: speedMps, accuracyMetres: accuracyMetres)) return fix;
  final apart = metresApart(drawn, fix);
  if (apart > math.max(followRestMetres, accuracyMetres ?? 0)) return fix;
  return apart < followRestStill ? drawn : pointBetween(drawn, fix, followRestShare);
}

/// How late a fix has reached the map, in seconds, so it can be carried
/// forward by that much from the start: the car went on moving while the fix
/// was on its way.
///
/// [lag] is the time on the app's clock when the fix arrived, less the time the
/// GPS stamped on it. The two clocks need not agree — only how this fix's lag
/// compares with the smallest of the last few ([lags], kept by the caller and
/// brought up to date here): a fix that took 0.3 s longer than the promptest of
/// them is 0.3 s late. Without this a fix held up for a moment (a busy phone,
/// Android batching them) pulled the dot back and then let it catch up — a
/// hitch each time. Never more than [most] ([followLateMost] for a phone's own
/// fixes).
double fixLateness(List<double> lags, double lag, {double most = followLateMost}) {
  lags.add(lag);
  if (lags.length > followLateWindow) lags.removeAt(0);
  return (lag - lags.reduce(math.min)).clamp(0.0, most).toDouble();
}

/// The acceleration (m/s², braking negative) between a fix at [earlierMps] and
/// one [gapSeconds] later at [laterMps], held to what a car can do; 0 when
/// either speed is unknown or the fixes are too close together or too far apart
/// for the change to mean anything.
double accelerationBetween(double? earlierMps, double? laterMps, double? gapSeconds) {
  if (earlierMps == null || laterMps == null || gapSeconds == null || gapSeconds < 0.3 || gapSeconds > 3) return 0;
  return ((laterMps - earlierMps) / gapSeconds).clamp(-followMaxBraking, followMaxAcceleration).toDouble();
}

/// What [FixFollower.take] made of a fix: the seconds since the fix before it
/// (by the GPS's own clock), and the speed (m/s) and course (degrees clockwise
/// from north) to carry it forward by — the GPS's own where it measured them,
/// else what the move from the fix before amounts to. Each is null when it is
/// not known.
typedef FixTaken = ({double? gap, double? speed, double? course});

/// Where a device is, a frame at a time, from the fixes its GPS gives (see the
/// top of this file). Give it each fix as it comes ([take]) and the length of
/// each frame ([advance]); [shown] is where to draw it.
///
/// It keeps no clock or ticker of its own, so whatever draws the dot decides
/// when frames run — and a test can run them one at a time.
class FixFollower {
  /// [lateMost] is the most lateness (seconds) a fix is carried forward for
  /// from the start ([fixLateness]): [followLateMost] for the phone's own GPS,
  /// more for fixes that come from another phone ([followLateMostRemote]).
  ///
  /// [catchUp] is how much faster than the device itself (m/s) the drawn point
  /// may move to close on where the device is; null leaves the ease to close
  /// any gap at its own pace, as for the phone's own GPS, where there is never
  /// much of one ([followCatchUpRemote] for another phone's fixes).
  FixFollower({this.lateMost = followLateMost, this.catchUp});

  final double lateMost;
  final double? catchUp;

  /// Where the latest fix is taken as putting the device ([settledFix]), and
  /// the fix as the GPS gave it.
  LatLng? _fix, _lastFix;
  DateTime? _time; // when the GPS took it
  double? _speedKnown; // m/s as measured; null when the fix gave none
  double _speed = 0; // m/s to carry it forward at; 0 when not known
  double _accel = 0; // m/s², braking negative
  double? _course; // degrees clockwise from north; null when not known
  double _age = 0; // seconds
  bool _still = false; // the latest fix said the device was standing still
  final _lags = <double>[]; // arrival less GPS time, the last few ([fixLateness])

  /// Where the device is drawn; null until the first fix.
  LatLng? shown;

  /// Whether a fix has been taken.
  bool get hasFix => _fix != null;

  /// How long ago the latest fix was taken, in frames' time (seconds),
  /// starting from how late it arrived.
  double get ageSeconds => _age;

  /// The speed (m/s) and course (degrees) the latest fix is carried forward
  /// by; the course is null when it is not known.
  double get speed => _speed;
  double? get course => _course;

  /// A fix has come in: what is carried forward from now on ([advance]).
  ///
  /// [speed] and [course] are the velocity the GPS measured with it (Doppler:
  /// clean even at a crawl), null where it gave none; [time] is when the GPS
  /// took it and [accuracy] how far out it may be (metres), each null when not
  /// known. [clock] is the time now, to tell how late the fix has arrived.
  ///
  /// Returns what was made of it, or null when it was dropped: a fix from
  /// before the one in hand is not news.
  FixTaken? take(
    LatLng at, {
    double? speed,
    double? course,
    DateTime? time,
    double? accuracy,
    DateTime Function() clock = DateTime.now,
  }) {
    final previous = _lastFix;
    final before = _time;
    // By the GPS's own clock, so a fix that was slow to reach the app does not
    // stretch the time between two.
    final gap = time == null || before == null
        ? null
        : time.difference(before).inMicroseconds / Duration.microsecondsPerSecond;
    // Never back in time.
    if (gap != null && gap < 0 && gap > -followStaleSeconds) return null;
    // How long this one took to get here, beyond what they usually take: it is
    // carried forward by that from the start.
    final late = time == null
        ? 0.0
        : fixLateness(
            _lags,
            clock().difference(time).inMicroseconds / Duration.microsecondsPerSecond,
            most: lateMost,
          );
    // A fix that comes without a velocity — a platform or a moment that gives
    // none — gets what the move from the last fix amounts to, so the motion is
    // still continuous.
    final measured = speed;
    var carriedSpeed = measured;
    var carriedCourse = course;
    if ((carriedSpeed == null || carriedCourse == null) && previous != null && gap != null && gap >= 0.2 && gap <= 5) {
      final moved = metresApart(previous, at);
      carriedSpeed ??= moved / gap;
      if (moved >= 2) carriedCourse ??= bearingBetween(previous, at);
    }
    // Speeding up or slowing down between the last two fixes: the fix is
    // carried forward doing the same, so a car pulling away is not left behind
    // and one braking is not run past where it stops.
    _accel = accelerationBetween(_speedKnown, measured, gap);
    _speedKnown = measured;
    // Where the fix puts the device: itself — and the first fix to say it has
    // stopped is where it stopped, however far the dot had been carried on
    // before the GPS knew (a sharp stop is news only a second later). The
    // fixes after that, while it stands, are the same spot measured again
    // ([settledFix]). The velocity above is worked out from the fixes as they
    // came, not from this.
    final still = fixIsStill(speedMps: measured, accuracyMetres: accuracy);
    _lastFix = at;
    _fix = still && _still ? settledFix(shown, at, speedMps: measured, accuracyMetres: accuracy) : at;
    _still = still;
    _time = time;
    _speed = carriedSpeed ?? 0;
    _course = carriedCourse;
    _age = late;
    shown ??= at;
    return (gap: gap, speed: carriedSpeed, course: carriedCourse);
  }

  /// One frame, [dt] seconds long: where the device is now, and [shown] eased
  /// onto it. Returns whether there is more to come — false once the device is
  /// standing still and the drawn point has settled, so frames can stop.
  bool advance(double dt) {
    final fix = _fix;
    if (fix == null) return false;
    _age += dt;
    // Where it is now. The estimate runs [followEaseSeconds] ahead of the
    // fix's age, which is exactly how far behind it the eased point trails at a
    // steady speed: the two cancel, and the dot sits on the device.
    final ahead = _age + followEaseSeconds;
    final now = deadReckon(fix, speedMps: _speed, courseDegrees: _course, ageSeconds: ahead, accelMps2: _accel);
    final carrying = _course != null && carryWeight(_speed) > 0 && ahead < followCoastSeconds;
    final was = shown;
    final LatLng next;
    if (was == null) {
      next = now;
    } else {
      final off = metresApart(was, now);
      if (off > followSnapMetres || off < 0.03) {
        // A big gap jumps; a hair's breadth is there.
        next = now;
      } else {
        var part = easeFraction(dt, followEaseSeconds);
        final faster = catchUp;
        if (faster != null) {
          // No faster than the device is going, and [catchUp] over.
          final going = carrying ? carryWeight(_speed) * math.max(0.0, _speed + _accel * ahead) : 0.0;
          part = math.min(part, (going + faster) * dt / off);
        }
        next = pointBetween(was, now, part);
      }
    }
    shown = next;
    return carrying || next != now;
  }
}
