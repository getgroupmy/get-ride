// The home map keeps its pickup pin (or the rider) in the middle of the map
// left showing above the sheet when it is all the way down (inDrive's),
// rather than in the middle of the whole map behind the sheet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:get_ride/src/widgets/map_sheet_layout.dart';
import 'package:get_ride/src/widgets/ride_map.dart';

void main() {
  testWidgets('the pickup stands halfway between the top and the lowest sheet', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MapSheetLayout(
            min: 0.25,
            initial: 0.25,
            map: RideMap(pickup: LatLng(2.95, 101.80), me: LatLng(2.96, 101.81), focusPickup: true),
            sheet: SizedBox(height: 300),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The pin's foot (its point) halfway down the 600 px above the sheet.
    final foot = tester.getBottomLeft(find.byKey(const ValueKey('pickup-pin-stem'))).dy;
    expect(foot, closeTo((800 - 800 * 0.25) / 2, 1));
  });

  testWidgets('focusOffset is up by half the lowest sheet, and nothing without one', (tester) async {
    late Offset inside, outside;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            outside = MapBottomInset.focusOffset(c);
            return MapBottomInset(
              extent: ValueNotifier(0.5),
              height: 800,
              cap: 480,
              rest: 200,
              child: Builder(
                builder: (c) {
                  inside = MapBottomInset.focusOffset(c);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );
    expect(inside, const Offset(0, -100));
    expect(outside, Offset.zero);
  });
}
