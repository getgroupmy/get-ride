// Settings → Show location to your driver: on unless turned off, remembered
// on the phone, light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/settings/show_location_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('on by default; turned off, it stays off (${dark ? 'dark' : 'light'})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: const Scaffold(
              body: Column(
                children: [
                  ShowLocationTile(),
                  Expanded(child: ShowLocationScreen()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('show-location-explanation')), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('show-location-switch'))).value, isTrue);
      expect(find.text('On'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('show-location-switch')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('show-location-switch'))).value, isFalse);
      expect(find.text('Off'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getBool('show_location_to_driver'), isFalse);
    });
  }

  testWidgets('a saved Off is read back', (tester) async {
    SharedPreferences.setMockInitialValues({'show_location_to_driver': false});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ShowLocationTile())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsOneWidget);
  });
}
