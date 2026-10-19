import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/navigation_app.dart';
import 'package:get_ride/src/features/settings/navigation_app_card.dart';
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('each app gets a driving link to the destination', () {
    expect(
      navigationUri(NavigationApp.google, 3.1, 101.6).toString(),
      'https://www.google.com/maps/dir/?api=1&destination=3.1,101.6&travelmode=driving',
    );
    expect(navigationUri(NavigationApp.waze, 3.1, 101.6).toString(), 'https://waze.com/ul?ll=3.1,101.6&navigate=yes');
    expect(
      navigationUri(NavigationApp.apple, 3.1, 101.6).toString(),
      'https://maps.apple.com/?daddr=3.1,101.6&dirflg=d',
    );
  });

  test('Apple Maps is offered only on Apple platforms; unknown names fall back to Google', () {
    expect(navigationAppsFor(apple: false), isNot(contains(NavigationApp.apple)));
    expect(navigationAppsFor(apple: true), contains(NavigationApp.apple));
    expect(NavigationApp.fromName('waze'), NavigationApp.waze);
    expect(NavigationApp.fromName('bogus'), NavigationApp.google);
    expect(NavigationApp.fromName(null), NavigationApp.google);
  });

  testWidgets('choosing an app is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: NavigationAppCard(apple: false))),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-app-apple')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-app-waze')));
    await tester.pump();
    expect(container.read(navigationAppProvider), NavigationApp.waze);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('navigation_app'), 'waze');
  });

  for (final dark in [false, true]) {
    for (final installed in <bool?>[null, true, false]) {
      testWidgets('Waze: the hint always; greyed "Not installed" only where the phone says so '
          '(${installed ?? 'web'}, ${dark ? 'dark' : 'light'})', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer(overrides: [wazeInstalledProvider.overrideWith((ref) async => installed)]);
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              home: const Scaffold(body: NavigationAppCard(apple: false)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tile = tester.widget<ListTile>(find.byKey(const ValueKey('nav-app-waze')));
        final hint = tester.widget<Text>(find.byKey(const ValueKey('nav-app-waze-hint')));
        expect(hint.data, contains(wazeHint));
        if (installed == false) {
          expect(tile.enabled, isFalse);
          expect(hint.data, startsWith(wazeNotInstalled));
          await tester.tap(find.byKey(const ValueKey('nav-app-waze')), warnIfMissed: false);
          await tester.pump();
          expect(container.read(navigationAppProvider), NavigationApp.google, reason: 'a missing app is not picked');
        } else {
          expect(tile.enabled, isTrue);
          expect(hint.data, isNot(contains(wazeNotInstalled)));
        }
        // Google Maps carries no hint.
        expect(
          find.descendant(of: find.byKey(const ValueKey('nav-app-google')), matching: find.textContaining('Opens')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
