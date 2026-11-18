// The confirm-map native marks' geometry: the image size and the anchor MapKit
// places them by, so the ringed dot lands on the point (pickup/drop) and a
// stop's plain square centres on it.
import 'package:flutter_test/flutter_test.dart';

import 'package:get_ride/src/widgets/map_badge_bitmap.dart';

void main() {
  group('badgeImageMetrics', () {
    test('a dotted mark anchors on the dot, with the badge above it', () {
      // square 36, gap 4, dot 14 → height 54, dot centre 36+4+7 = 47.
      final m = badgeImageMetrics(square: 36, gap: 4, dot: 14);
      expect(m.width, 36);
      expect(m.height, 54);
      expect(m.anchor.dx, 0.5);
      expect(m.anchor.dy, closeTo(47 / 54, 1e-9));
      // The anchor is above the image's middle (the badge stands over the dot).
      expect(m.anchor.dy, greaterThan(0.5));
    });

    test('a stop (no dot) is a square centred on the point', () {
      final m = badgeImageMetrics(square: 26, withDot: false);
      expect(m.width, 26);
      expect(m.height, 26);
      expect(m.anchor, const Offset(0.5, 0.5));
    });
  });
}
