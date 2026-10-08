// The home vehicle bar, as inDrive's: unchosen boxes are the sheet itself,
// names in full, and the chosen one filled with a blue "i".
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/features/ride/home_parts.dart';

void main() {
  testWidgets('names in full, the sheet colour unchosen, filled with an i when chosen', (tester) async {
    const services = [
      RideService('Ride', '', 1, 4),
      RideService('Comfort', '', 1, 4),
      RideService('6-seater', 'For large groups', 1, 6),
    ];
    var chosen = services[0];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, set) => VehicleTypeBar(
              services: services,
              selected: chosen,
              onSelect: (s) => set(() => chosen = s),
            ),
          ),
        ),
      ),
    );
    Material box(String name) => tester.widget<Material>(find.byKey(ValueKey('vehicle-type-$name')));
    for (final s in services) {
      final text = tester.renderObject<RenderParagraph>(find.text(s.name));
      expect(text.didExceedMaxLines, isFalse, reason: '${s.name} in full');
    }
    expect(box('Comfort').color, Colors.transparent);
    expect(box('Ride').color, VehicleTypeBar.selectedFill);

    await tester.tap(find.text('6-seater'));
    await tester.pump();
    expect(box('6-seater').color, VehicleTypeBar.selectedFill);
    expect(box('Ride').color, Colors.transparent);
    final info = tester.widget<Icon>(
      find.descendant(of: find.byKey(const ValueKey('vehicle-info-6-seater')), matching: find.byType(Icon)),
    );
    expect((info.icon, info.color), (Icons.info_outline, VehicleTypeBar.infoBlue));
    expect(find.byKey(const ValueKey('vehicle-info-Ride')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('vehicle-info-6-seater')));
    await tester.pumpAndSettle();
    expect(find.text('For large groups'), findsOneWidget);
  });
}
