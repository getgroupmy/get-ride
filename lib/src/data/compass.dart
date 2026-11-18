// The device heading for the driver's idle map (the heading-up map while
// waiting for a request). It follows the direction of TRAVEL while the driver
// is moving — the GPS course over ground, so the map points where they are
// going, not where the phone happens to face — and falls back to the phone's
// magnetometer compass while they are stopped (a parked phone's GPS course is
// random). This is what Google/Apple Maps do; using the magnetometer alone made
// the heading point where the phone was held, not the way the driver drove.
import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// The map re-rotates only once the heading has turned at least this far, so a
/// jittery sensor never shakes it.
const headingStep = 3.0;

/// Above this ground speed (m/s, ~9 km/h) the GPS course over ground is a
/// meaningful direction of travel and is trusted over the compass; below it the
/// course is random (a parked or crawling phone), so the compass is used.
const movingSpeed = 2.5;

/// The smallest turn between two headings in degrees (0–180), across the
/// 360° → 0° wrap: `angleGap(350, 10) == 20`. Pure.
double angleGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// A heading reading cleaned up: null (no compass / no fix) dropped, brought
/// into 0–360, and held back unless it has moved at least [headingStep] from
/// [last]. Returns the heading to emit, or null to skip this reading. Pure, so
/// the smoothing is tested without the plugin.
double? nextHeading(double? reading, double? last) {
  if (reading == null || reading.isNaN || reading.isInfinite || reading < 0) return null;
  final h = reading % 360;
  if (last != null && angleGap(last, h) < headingStep) return null;
  return h;
}

/// The GPS [course] over ground as a heading, but only while [speedMps] is fast
/// enough ([movingSpeed]) for the course to mean the direction of travel; else
/// null (the caller then uses the compass). Drops an unknown course (null, NaN,
/// or iOS's -1). Pure; see test/compass_test.dart.
double? courseWhenMoving(double? course, double? speedMps) {
  if (course == null || course.isNaN || course.isInfinite || course < 0) return null;
  if (speedMps == null || speedMps.isNaN || speedMps < movingSpeed) return null;
  return course % 360;
}

/// The heading to show: the direction of travel ([course]) when it is known
/// (moving), else where the phone faces ([compass]). Pure; see compass_test.dart.
double? preferredHeading(double? course, double? compass) => course ?? compass;

/// The device heading in degrees clockwise from north (0 = north, 90 = east),
/// the travel direction while moving and the compass while stopped, smoothed by
/// [nextHeading]; a stream that never emits where the phone has neither sensor.
/// Auto-disposed, so the sensors stop when no map is listening.
final deviceHeadingProvider = StreamProvider.autoDispose<double>((ref) {
  final out = StreamController<double>();
  double? last; // last emitted heading, for the smoothing
  double? course; // latest usable GPS course (travel direction), null when stopped
  double? compass; // latest compass reading (where the phone faces)

  void emit() {
    final h = nextHeading(preferredHeading(course, compass), last);
    if (h == null) return;
    last = h;
    out.add(h);
  }

  // The phone's magnetometer: where it points. Right while the driver is parked.
  final events = FlutterCompass.events;
  final compassSub = events?.listen((e) {
    final c = e.heading;
    compass = (c == null || c.isNaN || c.isInfinite || c < 0) ? null : c % 360;
    emit();
  });

  // The GPS course over ground: the direction of travel, trusted over the
  // compass while moving (so the map points the way the driver is going).
  StreamSubscription<Position>? gpsSub;
  try {
    gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 4),
    ).listen(
      (p) {
        course = courseWhenMoving(p.heading, p.speed);
        emit();
      },
      onError: (_) {},
    );
  } catch (_) {}

  if (compassSub == null && gpsSub == null) {
    out.close();
    return const Stream<double>.empty();
  }
  ref.onDispose(() {
    compassSub?.cancel();
    gpsSub?.cancel();
    out.close();
  });
  return out.stream;
});
