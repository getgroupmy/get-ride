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
}
