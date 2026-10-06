import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/coin_rate_chart.dart';

void main() {
  test('the live rate is added on the end when it moved', () {
    expect(chartRates([0.01, 0.011], 0.012), [0.01, 0.011, 0.012]);
    expect(chartRates([0.01, 0.011], 0.011), [0.01, 0.011]);
    expect(chartRates([], 0.01), [0.01]);
    expect(chartRates([0.01, double.nan, -1, 0], null), [0.01]);
  });

  test('points span the width, highest rate at the top', () {
    final pts = sparklineOffsets([1, 3, 2], const Size(100, 64));
    expect(pts.map((p) => p.dx), [0, 50, 100]);
    expect(pts[1].dy, 6, reason: 'the highest rate sits at the top padding');
    expect(pts[0].dy, 58, reason: 'the lowest at the bottom padding');
    expect(pts[2].dy, 32);
  });

  test('a flat line runs through the middle; one point draws nothing', () {
    expect(sparklineOffsets([2, 2, 2], const Size(90, 64)).map((p) => p.dy), [32, 32, 32]);
    expect(sparklineOffsets([2], const Size(90, 64)), isEmpty);
    expect(sparklineOffsets([1, 2], Size.zero), isEmpty);
  });
}
