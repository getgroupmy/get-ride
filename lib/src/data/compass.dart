// The device's compass heading, for the driver's idle map (Expo's heading-up
// map while waiting for a request). The phone's magnetometer, not the GPS
// course, so it works while the driver is standing still.
import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The map re-rotates only once the heading has turned at least this far, so a
/// jittery magnetometer never shakes it.
const headingStep = 3.0;

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

/// The device heading in degrees clockwise from north (0 = north, 90 = east),
/// smoothed by [nextHeading]; a stream that never emits where the phone has no
/// compass. Auto-disposed, so the sensor stops when no map is listening.
final deviceHeadingProvider = StreamProvider.autoDispose<double>((ref) {
  final events = FlutterCompass.events;
  if (events == null) return const Stream<double>.empty();
  final out = StreamController<double>();
  double? last;
  final sub = events.listen((e) {
    final h = nextHeading(e.heading, last);
    if (h == null) return;
    last = h;
    out.add(h);
  });
  ref.onDispose(() {
    sub.cancel();
    out.close();
  });
  return out.stream;
});
