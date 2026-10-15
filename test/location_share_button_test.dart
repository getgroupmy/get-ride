// The passenger's location-sharing button on the trip map: shown while the
// driver is on the way; off for this ride only or for all rides, and back on.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/location_share_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

RideRequest _ride(String status) => RideRequest({'id': 'r1', 'status': status});

void main() {
  Future<void> pump(
    WidgetTester tester,
    String status, {
    ThemeData? theme,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(child: LocationShareButton(ride: _ride(status))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('only while the driver is on the way', (tester) async {
    for (final s in ['open', 'on_trip', 'completed']) {
      await pump(tester, s);
      expect(find.byKey(const ValueKey('location-share-button')), findsNothing, reason: s);
    }
    await pump(tester, 'arrived');
    expect(find.byKey(const ValueKey('location-share-button')), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('off for this ride only, then back on (${dark ? 'dark' : 'light'})', (tester) async {
      await pump(tester, 'accepted', theme: dark ? ThemeData.dark() : ThemeData.light());
      expect(find.byKey(const ValueKey('location-share-on')), findsOneWidget);

      await tapKey(tester, 'location-share-button');
      expect(find.text('Smoother pickups with location sharing'), findsOneWidget);
      await tapKey(tester, 'location-share-turn-off');
      expect(find.text('Turn off location sharing for this ride only?'), findsOneWidget);
      await tapKey(tester, 'location-off-this-ride');
      expect(find.byKey(const ValueKey('location-share-off')), findsOneWidget);
      expect(find.text('Your driver can no longer see your location on this ride.'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool('show_location_to_driver'),
        isNull,
        reason: 'the setting is untouched',
      );

      await tapKey(tester, 'location-share-button');
      expect(find.text('Share my location'), findsOneWidget);
      await tapKey(tester, 'location-share-keep');
      expect(find.byKey(const ValueKey('location-share-on')), findsOneWidget);
      expect(find.text('Your driver can see your location now.'), findsOneWidget);
    });
  }

  testWidgets('off for all rides turns the setting off; sharing again turns it on', (tester) async {
    await pump(tester, 'accepted');
    await tapKey(tester, 'location-share-button');
    await tapKey(tester, 'location-share-turn-off');
    await tapKey(tester, 'location-off-all-rides');
    expect(find.byKey(const ValueKey('location-share-off')), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('show_location_to_driver'), isFalse);

    await tapKey(tester, 'location-share-button');
    await tapKey(tester, 'location-share-keep');
    expect((await SharedPreferences.getInstance()).getBool('show_location_to_driver'), isTrue);
  });

  testWidgets('closing the sheets, or Not now, changes nothing', (tester) async {
    await pump(tester, 'accepted', prefs: {'show_location_to_driver': false});
    expect(find.byKey(const ValueKey('location-share-off')), findsOneWidget);
    await tapKey(tester, 'location-share-button');
    await tapKey(tester, 'location-share-turn-off'); // "Not now"
    expect(find.byKey(const ValueKey('location-share-off')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
