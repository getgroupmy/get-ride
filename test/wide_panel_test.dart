import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/map_sheet_layout.dart';

void main() {
  group('wideBookingPanelWidth', () {
    test('iPhone Duo landscape (956 wide, 62pt side inset): content stays at least a phone wide', () {
      final w = wideBookingPanelWidth(956, 62);
      // The panel loses the 62pt inset to its own SafeArea; the content left
      // over must never be narrower than a phone (which squeezed to ~296 before).
      expect(w - 62, greaterThanOrEqualTo(400));
      expect(w - 62, lessThanOrEqualTo(500));
    });

    test('adds the side inset back so the inset never eats the content', () {
      expect(wideBookingPanelWidth(956, 62), closeTo(956 * 0.42 + 62, 0.001));
      expect(wideBookingPanelWidth(1000, 0), closeTo(420, 0.001)); // 0.42*1000 = 420, in range
    });

    test('floors the content at 400 on a just-wide screen', () {
      expect(wideBookingPanelWidth(900, 0), 400); // 0.42*900 = 378 -> 400
    });

    test('caps the content at 500 on a big tablet so the map keeps the larger share', () {
      expect(wideBookingPanelWidth(1600, 0), 500); // 0.42*1600 = 672 -> 500
    });
  });

  group('cappedBookingPanelWidth', () {
    test('near-square foldable inner: ~50/50, so the map gets half', () {
      // natural 460 would leave the map under half of 900; cap to 450.
      expect(cappedBookingPanelWidth(460, 900, 0), 450);
    });

    test('roomy screen: panel keeps its natural width, map gets more than half', () {
      expect(cappedBookingPanelWidth(500, 1400, 0), 500); // half (700) > natural
    });

    test('narrow wide screen (iPad portrait): panel stays readable, not below its floor', () {
      // available 678, half 339 < 400 floor: keep 400 so the panel does not truncate.
      expect(cappedBookingPanelWidth(400, 678, 0), 400);
    });

    test('the floor includes the side inset so content never truncates', () {
      // Duo landscape: inset 62, floor 462; half (433) is below it, so keep 462.
      expect(cappedBookingPanelWidth(462, 866, 62), 462);
    });
  });
}
