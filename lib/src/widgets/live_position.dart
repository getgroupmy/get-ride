// A dot that keeps up with the device on a map that is not following it.
//
// The rider's home map shows where the rider is with a blue dot. The map does
// not follow them — the camera, the pickup pin and its address stay where the
// rider put them — but the dot does, the way the driver's map follows the car
// (core/follow_motion.dart): each fix carried forward by the GPS's own speed
// and course a frame at a time, so the dot moves steadily rather than hopping
// once a second, and stands still when the rider does.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:latlong2/latlong.dart';

import '../core/follow_motion.dart';
import '../data/live_fix.dart';

/// Where the device is, a frame at a time, from the fixes given to [take].
/// [shown] is where to draw it; it changes every frame while the device is
/// moving and not at all while it is standing still, so whatever listens
/// redraws no more than it has to.
class LivePosition {
  LivePosition({required TickerProvider vsync, this.clock = DateTime.now}) {
    _ticker = vsync.createTicker(_onTick);
  }

  /// The time now, by which a fix's arrival is timed (a test's own clock,
  /// which moves with the frames it pumps).
  final DateTime Function() clock;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  var _follower = FixFollower();
  final _shown = ValueNotifier<LatLng?>(null);
  LatLng? _latest;

  /// Where to draw the device; null until the first fix (and after [clear]).
  ValueListenable<LatLng?> get shown => _shown;

  /// The latest fix as the GPS gave it; null until the first.
  LatLng? get latest => _latest;

  /// A fix has come in.
  void take(LiveFix fix) {
    final taken = _follower.take(
      fix.at,
      speed: fix.speed,
      course: fix.course,
      time: fix.time,
      accuracy: fix.accuracy,
      clock: clock,
    );
    if (taken == null) return; // from before the one in hand: not news
    _latest = fix.at;
    _shown.value = _follower.shown;
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    // A long frame (a hitch, the app coming back) is not that much travel.
    final dt = math.min((elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond, 0.25);
    _lastTick = elapsed;
    final more = _follower.advance(dt);
    _shown.value = _follower.shown;
    if (!more) _ticker.stop();
  }

  /// Forgets where the device was: the fixes have stopped coming (location
  /// switched off), so the last one is no longer where it is.
  void clear() {
    _ticker.stop();
    _follower = FixFollower();
    _latest = null;
    _shown.value = null;
  }

  void dispose() {
    _ticker.dispose();
    _shown.dispose();
  }
}
