// The geometry of Meter Digital's landscape stage, ported from the Expo app's
// `utils/fixedLandscape.ts`.
//
// A meter is read off a dash mount, so the console is always laid out
// landscape. The orientation lock turns the *device* where the platform
// allows it; where it does not (a browser, an iPad in split view, a rotation
// lock left on) the viewport stays portrait, and the stage turns the
// *content* a quarter turn instead, so the instrument is still read
// sideways rather than reflowing into a tall column.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

typedef StageGeometry = ({int quarterTurns, Size size, EdgeInsets padding});

/// What the console is handed for a [viewport] with safe-area [padding]: a
/// landscape box, and the insets as the turned content meets them.
///
/// A quarter turn clockwise puts the content's top against the glass's right
/// edge, so the insets roll round with it: the content's top inset is the
/// screen's right, its right the screen's bottom, and so on.
StageGeometry resolveLandscapeStage(Size viewport, EdgeInsets padding) {
  if (viewport.width >= viewport.height) return (quarterTurns: 0, size: viewport, padding: padding);
  return (
    quarterTurns: 1,
    size: Size(viewport.height, viewport.width),
    padding: EdgeInsets.fromLTRB(padding.top, padding.right, padding.bottom, padding.left),
  );
}

/// The width the console is laid out at before it is scaled to fit.
const meterConsoleWidth = 820.0;

/// The console's layout box for the space it is given: a fixed width, and a
/// height that follows the space's shape within what the layout can use, so
/// it fills a wide phone and a squarer tablet alike and is then scaled to fit
/// without scrolling.
Size meterConsoleLayout(Size available) {
  if (available.width <= 0 || available.height <= 0) return const Size(meterConsoleWidth, 360);
  final height = meterConsoleWidth * available.height / available.width;
  return Size(meterConsoleWidth, math.min(math.max(height, 360), 600));
}
