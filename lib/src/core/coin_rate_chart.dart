/// The GET.coin price line on the trade screen (Expo `RateSparkline`): the
/// recorded rate snapshots (`get_coin_rate_history`, written by the server
/// at most every 15 minutes since 0089), with the live market rate on the end.
library;

import 'dart:math' as math;
import 'dart:ui';

/// The rates to draw, oldest first: [history] plus [current] when it differs
/// from the last recorded one. Non-positive or non-finite rates are dropped.
List<double> chartRates(List<double> history, double? current) {
  final pts = [
    for (final r in history)
      if (r.isFinite && r > 0) r,
  ];
  if (current != null && current.isFinite && current > 0 && (pts.isEmpty || pts.last != current)) {
    pts.add(current);
  }
  return pts;
}

/// Where each rate sits in a [size] box, left to right, highest at the top,
/// with [pad] above and below. Empty when there aren't two points to join.
/// A flat line (every rate equal) is drawn through the middle.
List<Offset> sparklineOffsets(List<double> rates, Size size, {double pad = 6}) {
  if (rates.length < 2 || size.width <= 0 || size.height <= 0) return const [];
  final lo = rates.reduce(math.min), hi = rates.reduce(math.max);
  final span = hi - lo;
  final usable = math.max(0.0, size.height - pad * 2);
  final step = size.width / (rates.length - 1);
  return [
    for (var i = 0; i < rates.length; i++)
      Offset(i * step, span == 0 ? size.height / 2 : pad + usable * (1 - (rates[i] - lo) / span)),
  ];
}
