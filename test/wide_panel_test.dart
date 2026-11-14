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
    test('map gets half the whole screen; the rail comes out of the panel side', () {
      // Full screen 1000; a ~90pt rail leaves 910 of content. The panel is
      // capped so the map is 500 — half the whole screen, not half the 910 of
      // content — so the slim rail is taken off the panel's share, not the map's.
      expect(cappedBookingPanelWidth(600, 910, 1000, 0), 410);
      expect(910 - 410, 1000 * 0.5);
    });

    test('iPad mini landscape: the map ends up at least half the full screen', () {
      // 1133 wide, a compact rail (~90) leaves 1043 of content; the natural
      // content-fitting panel is clamped so the map keeps half of 1133.
      final panel = cappedBookingPanelWidth(wideBookingPanelWidth(1133, 0), 1043, 1133, 0);
      expect(1043 - panel, greaterThanOrEqualTo(1133 * 0.5));
    });

    test('roomy screen: panel keeps its natural width, map gets more than half', () {
      // available 1510 (rail ~90 off 1600); target 710 > natural 500.
      expect(cappedBookingPanelWidth(500, 1510, 1600, 0), 500);
    });

    test('narrow wide screen (iPad portrait): panel stays readable, not below its floor', () {
      // 768 wide, rail ~90 leaves 678; the half-screen target (294) is below
      // the 400 floor, so keep 400 and let the map take the smaller share.
      expect(cappedBookingPanelWidth(400, 678, 768, 0), 400);
    });

    test('the floor includes the side inset so content never truncates', () {
      // Duo landscape: full 956, inset 62, floor 462; the half-screen target
      // (388) is below it, so keep 462.
      expect(cappedBookingPanelWidth(462, 866, 956, 62), 462);
    });
  });
}
