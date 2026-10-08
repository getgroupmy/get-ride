// The side menus, the pickup pin and the chosen vehicle box follow the app's
// light / dark theme rather than being drawn dark-only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/features/ride/home_parts.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:get_ride/src/widgets/side_menu_style.dart';

Widget _app(Brightness b, Widget child) => MaterialApp(
  theme: ThemeData(brightness: b),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('side menu palette: white in light, charcoal in dark', () {
    expect(SideMenuColors.light.background, Colors.white);
    expect(SideMenuColors.dark.background, SideMenuStyle.background);
    expect(SideMenuColors.light.text, isNot(SideMenuColors.dark.text));
  });

  for (final b in Brightness.values) {
    testWidgets('side menu colours resolve from the theme ($b)', (tester) async {
      late SideMenuColors c;
      await tester.pumpWidget(
        _app(
          b,
          Builder(
            builder: (ctx) {
              c = SideMenuColors.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(c, b == Brightness.dark ? SideMenuColors.dark : SideMenuColors.light);
    });

    testWidgets('pickup pin follows the theme ($b)', (tester) async {
      await tester.pumpWidget(_app(b, const PickupPin()));
      final dark = b == Brightness.dark;
      final head = tester.widget<Container>(find.byKey(const ValueKey('pickup-pin')));
      final deco = head.decoration! as BoxDecoration;
      expect(deco.color, dark ? Colors.white : Colors.black);
      final figure = tester.widget<Icon>(find.byIcon(Icons.emoji_people));
      expect(figure.color, dark ? Colors.black : Colors.white);
      final stem = tester.widget<Container>(find.byKey(const ValueKey('pickup-pin-stem')));
      expect((stem.decoration! as BoxDecoration).color, deco.color);
    });

    testWidgets('chosen vehicle box follows the theme ($b)', (tester) async {
      const services = [RideService('Ride', '', 1, 4), RideService('Comfort', '', 1, 4)];
      await tester.pumpWidget(_app(b, VehicleTypeBar(services: services, selected: services[0], onSelect: (_) {})));
      final dark = b == Brightness.dark;
      final box = tester.widget<Material>(find.byKey(const ValueKey('vehicle-type-Ride')));
      expect(box.color, dark ? VehicleTypeBar.selectedFill : VehicleTypeBar.selectedFillLight);
      final name = tester.widget<Text>(find.text('Ride'));
      final scheme = ThemeData(brightness: b).colorScheme;
      expect(name.style?.color, dark ? Colors.white : scheme.onSurface);
    });
  }
}
