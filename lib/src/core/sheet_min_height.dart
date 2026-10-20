// Admin → Display Settings → "Bottom sheet minimum height": how low the
// home, ride-confirm and ride-tracking sheets rest when pulled all the way
// down. The phone measures what the shown items need (the automatic part);
// the admin stores only an adjustment in px on top of it, so turning an
// item on or off moves the figure by that item and keeps the adjustment.
// Pure.
import 'dart:math' as math;

/// The display settings keys, one per sheet.
const homeSheetMinAdjustKey = 'homeSheetMinAdjust';
const confirmSheetMinAdjustKey = 'confirmSheetMinAdjust';
const trackingSheetMinAdjustKey = 'trackingSheetMinAdjust';

/// The adjustment's range and step, in px.
const sheetMinAdjustMin = -60;
const sheetMinAdjustMax = 300;
const sheetMinAdjustStep = 10;

/// The ride-confirm sheet may rest as low as this, in px with the Find a
/// driver bar under it; the vehicles above it are a pull away.
const confirmSheetMinFloor = 140;

/// The lowest adjustment for the sheet at [key]: the ride-confirm one goes
/// far enough to reach [confirmSheetMinFloor].
int sheetMinAdjustMinFor(String key) => key == confirmSheetMinAdjustKey ? -400 : sheetMinAdjustMin;

/// The admin's adjustment at [key] (0 when unset or unreadable), kept in
/// range.
double sheetMinAdjust(Map<String, dynamic>? settings, String key) {
  final v = settings?[key];
  final n = v is num ? v : num.tryParse('${v ?? ''}'.trim());
  if (n == null || !n.isFinite) return 0;
  return n.toDouble().clamp(sheetMinAdjustMinFor(key).toDouble(), sheetMinAdjustMax.toDouble());
}

/// The sheet's least height in px: what its shown items need ([auto]) plus
/// the admin's [adjust], never less than [floor] (the handle and the first
/// always-shown item whole) and never more than [max] (the sheet's
/// highest). Where the floor itself is above the highest, the highest wins.
double effectiveSheetMin({
  required double auto,
  required double adjust,
  required double floor,
  required double max,
}) {
  final low = math.min(math.max(0.0, floor), max);
  return (auto + adjust).clamp(low, max).toDouble();
}
