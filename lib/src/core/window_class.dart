// The window's size class and fold state, for a layout that adapts to a
// foldable's outer (folded) and inner (unfolded) displays as well as ordinary
// phones, split-view panes and tablets — all from the actual window geometry
// and the reported display features, never a device name or a fixed size
// table.
//
// Everything here is pure and tested (test/window_class_test.dart); the one
// `BuildContext` reader at the foot just gathers the live MediaQuery and hands
// it to the pure functions, so it rebuilds as the device folds, unfolds or
// resizes. It is a no-op on a device that reports no fold (every current
// iPhone, a seamless display): `fold` is null and the width class is decided
// by size alone, exactly as before.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The window's width "size class", Apple-style: compact for a phone, a folded
/// outer display or a narrow split-view pane; regular for a wide, unfolded
/// inner display or a tablet, where a two-pane layout fits.
enum WindowWidthClass { compact, regular }

/// Whether the window's least height leaves room for the map's buttons and a
/// sheet over it, or is as short as a phone on its side.
enum WindowHeightClass { compact, regular }

/// How a foldable is posed, read from the display features: [flat] when it is
/// open flat or reports no fold at all, [halfOpened] in a book or tabletop
/// pose where the two halves meet at an angle.
enum FoldPosture { flat, halfOpened }

/// The least width from which a two-pane (regular-width) layout fits, and the
/// least height that width then also needs — the app's existing wide-layout
/// thresholds ([wideLayoutAt] in map_sheet_layout.dart), named here so the
/// size class and that helper never drift apart (a test pins them together).
const windowRegularMinWidth = 760.0;
const windowRegularMinHeight = 500.0;

/// The width from which the layout is regular whatever the height (a laptop, a
/// large phone on its side).
const windowAlwaysRegularWidth = 900.0;

/// The width class for a window of [size]: regular once it is wide enough for
/// two panes ([windowAlwaysRegularWidth] at any height, or
/// [windowRegularMinWidth] when also [windowRegularMinHeight] tall), else
/// compact. Mirrors `wideLayoutAt`.
WindowWidthClass widthClassOf(Size size) =>
    size.width >= windowAlwaysRegularWidth ||
        (size.width >= windowRegularMinWidth && size.height >= windowRegularMinHeight)
    ? WindowWidthClass.regular
    : WindowWidthClass.compact;

/// The height class for a window of [size]: compact below
/// [windowRegularMinHeight] (a phone on its side), else regular.
WindowHeightClass heightClassOf(Size size) =>
    size.height >= windowRegularMinHeight ? WindowHeightClass.regular : WindowHeightClass.compact;

/// A fold or hinge that may divide the window, in the window's own logical
/// coordinates.
@immutable
class WindowFold {
  const WindowFold({required this.bounds, required this.separates, required this.vertical});

  /// The fold/hinge rectangle. A fold is often zero-width (a seam); a hinge
  /// has real thickness (the gap between two panels).
  final Rect bounds;

  /// Whether it splits the window into two usable areas to lay out around — a
  /// hinge always does; a fold only in a half-opened pose. A flat fold is a
  /// seamless display and is ignorable.
  final bool separates;

  /// A seam that runs top to bottom, so the two panes sit side by side (left
  /// and right); otherwise it runs across and the panes sit top and bottom.
  final bool vertical;
}

/// The window's size class, fold and pose together.
@immutable
class WindowMetrics {
  const WindowMetrics({
    required this.size,
    required this.widthClass,
    required this.heightClass,
    required this.fold,
    required this.posture,
  });

  final Size size;
  final WindowWidthClass widthClass;
  final WindowHeightClass heightClass;

  /// The dividing fold or hinge, or null when the display is seamless or flat
  /// (every current iPhone, a tablet, a desktop window).
  final WindowFold? fold;
  final FoldPosture posture;

  /// Wide enough for a two-pane layout.
  bool get isRegularWidth => widthClass == WindowWidthClass.regular;

  /// A fold or hinge actually divides the window right now, so interactive
  /// content and the two panes should keep clear of it.
  bool get hasSeparatingFold => fold != null && fold!.separates;
}

/// The first fold or hinge among [features] that could divide the window, or
/// null when there is none. A hinge separates whatever the pose; a fold only
/// when the device is half-opened (a flat fold is a seamless display).
WindowFold? foldOf(List<ui.DisplayFeature> features) {
  for (final f in features) {
    if (f.type != ui.DisplayFeatureType.fold && f.type != ui.DisplayFeatureType.hinge) continue;
    final b = f.bounds;
    return WindowFold(
      bounds: b,
      separates: f.type == ui.DisplayFeatureType.hinge || f.state == ui.DisplayFeatureState.postureHalfOpened,
      // A seam taller than it is wide runs top-to-bottom; a square (zero-area)
      // fold is treated as vertical, the common book-fold case.
      vertical: b.height >= b.width,
    );
  }
  return null;
}

/// The device's pose from [features]: [FoldPosture.halfOpened] when a fold or
/// hinge reports a half-opened state, else [FoldPosture.flat].
FoldPosture postureOf(List<ui.DisplayFeature> features) {
  for (final f in features) {
    final folding = f.type == ui.DisplayFeatureType.fold || f.type == ui.DisplayFeatureType.hinge;
    if (folding && f.state == ui.DisplayFeatureState.postureHalfOpened) return FoldPosture.halfOpened;
  }
  return FoldPosture.flat;
}

/// The [WindowMetrics] for a window of [size] with these [features].
WindowMetrics windowMetricsOf(Size size, List<ui.DisplayFeature> features) => WindowMetrics(
  size: size,
  widthClass: widthClassOf(size),
  heightClass: heightClassOf(size),
  fold: foldOf(features),
  posture: postureOf(features),
);

/// Whether [item] (a widget's rectangle in window coordinates) overlaps the
/// separating fold or hinge, so the caller should move it clear. False when
/// nothing separates the window.
bool hitsFold(Rect item, WindowFold? fold) => fold != null && fold.separates && item.overlaps(fold.bounds);

/// The two panes a separating [fold] divides [area] into — left and right for
/// a vertical seam, top and bottom for a horizontal one — or null when the
/// fold does not separate or falls outside [area] (so the caller uses [area]
/// whole). The panes stop at the fold's edges, leaving its thickness empty.
(Rect, Rect)? panesAround(Rect area, WindowFold? fold) {
  if (fold == null || !fold.separates) return null;
  final b = fold.bounds;
  if (fold.vertical) {
    if (b.left <= area.left || b.right >= area.right) return null;
    return (
      Rect.fromLTRB(area.left, area.top, b.left, area.bottom),
      Rect.fromLTRB(b.right, area.top, area.right, area.bottom),
    );
  }
  if (b.top <= area.top || b.bottom >= area.bottom) return null;
  return (
    Rect.fromLTRB(area.left, area.top, area.right, b.top),
    Rect.fromLTRB(area.left, b.bottom, area.right, area.bottom),
  );
}

/// For a left-panel / right-map split (the home screen's wide layout): the
/// panel width and the seam gap so the divider falls on a vertical book-fold,
/// instead of an arbitrary fixed width that could land content in the crease.
/// Null to keep the default single split — when there is no separating
/// vertical fold, or the two panes it would make are too narrow to use
/// ([minLeft] for the panel, [minRight] for the map).
({double panelWidth, double gap})? verticalSplitFor(WindowMetrics m, {double minLeft = 360, double minRight = 300}) {
  final f = m.fold;
  if (f == null || !f.separates || !f.vertical) return null;
  final left = f.bounds.left;
  final right = m.size.width - f.bounds.right;
  if (left < minLeft || right < minRight) return null;
  return (panelWidth: left, gap: f.bounds.width);
}

/// The window's size class, fold and pose for [context], read from the live
/// MediaQuery so it follows folding, unfolding and resizing. Depends only on
/// the window size and its display features, not the whole MediaQuery.
WindowMetrics windowMetricsFor(BuildContext context) =>
    windowMetricsOf(MediaQuery.sizeOf(context), MediaQuery.displayFeaturesOf(context));
