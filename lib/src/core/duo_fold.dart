// A fold signal from the iOS native side, and its translation into an
// ordinary Flutter display feature.
//
// Flutter fills MediaQuery.displayFeatures from Android's window manager, but
// does not surface an iPhone Duo's crease on iOS. So a small native plugin
// reads it there the way pvinis/duo-demo's WindowProbe does — a
// UIHingeInteraction for the pose and UIView.reservedRegions(kind:.division/
// .occlusion) for the crease and camera cut-outs — and sends it over a method
// channel. This turns that message into a synthesized ui.DisplayFeature, so
// the rest of the app sees the Duo's fold through the same
// MediaQuery.displayFeatures path as an Android foldable (window_class.dart),
// with no iOS-specific branches downstream.
//
// All pure and tested (test/duo_fold_test.dart). UIKit points are the same
// unit as Flutter's logical pixels, so a region frame maps across with no
// device-pixel-ratio conversion.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The hinge pose, as `UIHinge.Status` (duo-demo): [none] when the device has
/// no hinge at all, [closed] on the cover display, part/fully open on the
/// inner one.
enum DuoHinge { none, unknown, closed, partiallyOpen, fullyOpen }

DuoHinge duoHingeFromName(Object? v) => switch ('${v ?? ''}') {
  'closed' => DuoHinge.closed,
  'partiallyOpen' => DuoHinge.partiallyOpen,
  'fullyOpen' => DuoHinge.fullyOpen,
  'none' => DuoHinge.none,
  _ => DuoHinge.unknown,
};

/// The iPhone Duo hinge pose the bridge last reported (or a simulated one),
/// kept in step by [DuoFoldScope] for code that must react to the fold beyond
/// `MediaQuery.displayFeatures`. The orientation lock reads it: the folded
/// cover's portrait pin can otherwise trap the app, since the pin stops iOS
/// handing the window the unfolded inner display's larger size (see
/// `orientation.dart`). It stays [DuoHinge.none] on every device with no Duo
/// bridge (an Android foldable reports its fold through `displayFeatures` and
/// resizes honestly, so it never needs this).
final duoHingeNow = ValueNotifier<DuoHinge>(DuoHinge.none);

/// What the native side reports about the fold: the pose, the crease
/// (`.division`) rectangle and whether it is currently dividing the window,
/// and any camera cut-outs (`.occlusion`).
@immutable
class DuoFoldSignal {
  const DuoFoldSignal({
    required this.hinge,
    this.angleDegrees,
    this.division,
    this.divisionActive = false,
    this.occlusions = const [],
  });

  final DuoHinge hinge;

  /// The fold angle in degrees, if the hinge reports one.
  final double? angleDegrees;

  /// The crease rectangle in logical pixels (window coordinates), or null.
  final Rect? division;

  /// Whether the crease is actively dividing the window now (content must keep
  /// clear). An inactive crease — reported on a window's hinge-facing edge for
  /// the left/right cross-check — does not divide.
  final bool divisionActive;

  /// Camera cut-out rectangles, in logical pixels.
  final List<Rect> occlusions;

  /// Whether the crease splits the window into two usable areas right now.
  bool get separates => division != null && divisionActive;

  @override
  bool operator ==(Object other) =>
      other is DuoFoldSignal &&
      other.hinge == hinge &&
      other.angleDegrees == angleDegrees &&
      other.division == division &&
      other.divisionActive == divisionActive &&
      listEquals(other.occlusions, occlusions);

  @override
  int get hashCode => Object.hash(hinge, angleDegrees, division, divisionActive, Object.hashAll(occlusions));
}

Rect? _rect(Object? v) {
  if (v is! Map) return null;
  double? n(Object? x) => x is num ? x.toDouble() : double.tryParse('${x ?? ''}');
  final x = n(v['x']), y = n(v['y']), w = n(v['w']), h = n(v['h']);
  if (x == null || y == null || w == null || h == null || w < 0 || h < 0) return null;
  return Rect.fromLTWH(x, y, w, h);
}

/// Parses the native channel message (a string-keyed map) into a signal; a
/// malformed or empty message reads as no hinge.
DuoFoldSignal duoFoldFromNative(Map<Object?, Object?>? m) {
  if (m == null) return const DuoFoldSignal(hinge: DuoHinge.none);
  final angle = m['angle'];
  return DuoFoldSignal(
    hinge: duoHingeFromName(m['hinge']),
    angleDegrees: angle is num ? angle.toDouble() : double.tryParse('${angle ?? ''}'),
    division: _rect(m['division']),
    divisionActive: m['divisionActive'] == true,
    occlusions: [
      for (final o in (m['occlusions'] as List? ?? const [])) ?_rect(o),
    ],
  );
}

/// The display feature equivalent to [signal]'s dividing crease, so the rest
/// of the app sees the Duo fold through MediaQuery.displayFeatures. Null when
/// no crease is dividing the window (closed, flat-and-seamless, or inactive).
/// A dividing crease is reported half-opened — the state window_class treats
/// as a separating fold — whatever the exact angle.
ui.DisplayFeature? displayFeatureFor(DuoFoldSignal signal) {
  final d = signal.division;
  if (d == null || !signal.separates) return null;
  return ui.DisplayFeature(
    bounds: d,
    type: ui.DisplayFeatureType.fold,
    state: ui.DisplayFeatureState.postureHalfOpened,
  );
}

/// The display features to hand MediaQuery: whatever the platform already
/// reports ([existing], e.g. an Android foldable), plus [synthesized] only
/// when the platform reports no fold or hinge of its own, so iOS is filled in
/// without ever doubling a real feature.
List<ui.DisplayFeature> mergeFoldFeatures(List<ui.DisplayFeature> existing, ui.DisplayFeature? synthesized) {
  if (synthesized == null) return existing;
  final hasFold = existing.any(
    (f) => f.type == ui.DisplayFeatureType.fold || f.type == ui.DisplayFeatureType.hinge,
  );
  return hasFold ? existing : [...existing, synthesized];
}

/// A simulated crease for exercising the fold layout on an ordinary phone (a
/// dev harness, as DuoKit ships): a vertical book-fold down the middle of a
/// [window] of this size, as a half-opened signal.
DuoFoldSignal simulatedBookFold(Size window, {double seam = 14}) => DuoFoldSignal(
  hinge: DuoHinge.partiallyOpen,
  angleDegrees: 110,
  division: Rect.fromLTWH((window.width - seam) / 2, 0, seam, window.height),
  divisionActive: true,
);

/// A simulated horizontal crease across the middle (tabletop / laptop pose).
DuoFoldSignal simulatedTabletopFold(Size window, {double seam = 14}) => DuoFoldSignal(
  hinge: DuoHinge.partiallyOpen,
  angleDegrees: 110,
  division: Rect.fromLTWH(0, (window.height - seam) / 2, window.width, seam),
  divisionActive: true,
);
