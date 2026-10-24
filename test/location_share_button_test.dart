// The passenger's location-sharing button on the trip map: shown while the
// driver is on the way; off for this ride only or for all rides, and back on.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/location_share_button.dart';
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notice.dart';

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
    // A message from the last step is closed first, as the user would.
    await closeAnyNotice(tester);
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
    expect(find.byKey(const ValueKey('notice')), findsNothing);
  });

  testWidgets('Only this ride is kept on the phone: closing and reopening the app keeps it off', (tester) async {
    await pump(tester, 'accepted');
    await tapKey(tester, 'location-share-button');
    await tapKey(tester, 'location-share-turn-off');
    await tapKey(tester, 'location-off-this-ride');
    expect((await SharedPreferences.getInstance()).getStringList('ride_location_off'), ['r1']);

    // A fresh start of the app: a new ProviderScope reading the phone's copy.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: LocationShareButton(ride: _ride('accepted'))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('location-share-off')), findsOneWidget);

    await tapKey(tester, 'location-share-button');
    await tapKey(tester, 'location-share-keep');
    expect((await SharedPreferences.getInstance()).getStringList('ride_location_off'), isEmpty);
  });

  test('only the most recent rides are remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(rideLocationOffProvider);
    for (var i = 0; i < RideLocationOffNotifier.keep + 5; i++) {
      await c.read(rideLocationOffProvider.notifier).turnOff('r$i');
    }
    final saved = (await SharedPreferences.getInstance()).getStringList('ride_location_off')!;
    expect(saved, hasLength(RideLocationOffNotifier.keep));
    expect(saved.first, 'r5');
    expect(saved.last, 'r${RideLocationOffNotifier.keep + 4}');
  });
}
