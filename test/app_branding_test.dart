import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_branding.dart';
import 'package:get_ride/src/data/branding_cache.dart';
import 'package:get_ride/src/features/shell/brand_splash.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A 1×1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  group('how long is left', () {
    final start = DateTime(2026, 10, 6, 8);

    test('five seconds, all of it at process start', () {
      expect(splashHold, const Duration(seconds: 5));
      expect(splashRemaining(start, started: start), splashHold);
    });

    test('less once start-up has taken a while, and never negative', () {
      expect(splashRemaining(start.add(const Duration(seconds: 2)), started: start), const Duration(seconds: 3));
      expect(splashRemaining(start.add(const Duration(seconds: 9)), started: start), Duration.zero);
    });
  });

  test('the apps hold a splash; web and desktop do not', () {
    expect(splashHeld(isWeb: false, platform: TargetPlatform.android), isTrue);
    expect(splashHeld(isWeb: false, platform: TargetPlatform.iOS), isTrue);
    expect(splashHeld(isWeb: true, platform: TargetPlatform.android), isFalse);
    expect(splashHeld(isWeb: false, platform: TargetPlatform.macOS), isFalse);
  });

  test('white with black ink in light mode, the reverse in dark', () {
    expect(splashBackground(dark: false), const Color(0xFFFFFFFF));
    expect(splashBackground(dark: true), const Color(0xFF000000));
    expect(splashInk(dark: false), const Color(0xFF000000));
    expect(splashInk(dark: true), const Color(0xFFFFFFFF));
  });

  test('the branding row: a blank or non-web picture is none', () {
    expect(AppBranding.fromRow({'splash_image_url': ' https://cdn/s.png '}).splashImageUrl, 'https://cdn/s.png');
    expect(AppBranding.fromRow(null).splashImageUrl, isNull);
    expect(AppBranding.fromRow({'splash_image_url': ''}).splashImageUrl, isNull);
    expect(AppBranding.fromRow({'splash_image_url': 'file:///x.png'}).splashImageUrl, isNull);
  });

  test('the cache round-trips and a broken one is ignored', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await BrandingCache.load(), isNull);
    SharedPreferences.setMockInitialValues({
      'app_branding_v1': jsonEncode({'splash_image_url': null}),
    });
    expect((await BrandingCache.load())!.branding, const AppBranding());
    SharedPreferences.setMockInitialValues({'app_branding_v1': 'not json'});
    expect(await BrandingCache.load(), isNull);
  });

  Widget gate({CachedBranding? cached, ValueListenable<AppBranding?>? live, bool held = true, DateTime? now}) =>
      MaterialApp(
        home: SplashGate(
          cached: cached,
          live: live,
          held: held,
          now: () => now ?? splashStarted,
          child: const Text('home'),
        ),
      );

  testWidgets('holds the app behind the splash for the rest of the five seconds', (tester) async {
    await tester.pumpWidget(gate(cached: CachedBranding(const AppBranding(splashImageUrl: 'https://cdn/s.png'), _png)));
    expect(find.byKey(const ValueKey('splash')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-image')), findsOneWidget);
    expect(find.text('home'), findsNothing); // not built until the splash is done
    await tester.pump(splashHold);
    expect(find.byKey(const ValueKey('splash')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('without a picture it shows the logo', (tester) async {
    await tester.pumpWidget(gate());
    expect(find.byKey(const ValueKey('splash-logo')), findsOneWidget);
    await tester.pump(splashHold);
  });

  testWidgets('a picture fetched by this launch replaces the cached one', (tester) async {
    final live = ValueNotifier<AppBranding?>(null);
    await tester.pumpWidget(gate(live: live));
    expect(find.byKey(const ValueKey('splash-logo')), findsOneWidget);
    live.value = const AppBranding(splashImageUrl: 'https://cdn/new.png');
    await tester.pump();
    expect(find.byKey(const ValueKey('splash-image')), findsOneWidget);
    await tester.pump(splashHold);
  });

  testWidgets('no splash on the web or after a start that used the whole hold', (tester) async {
    await tester.pumpWidget(gate(held: false));
    expect(find.byKey(const ValueKey('splash')), findsNothing);
    expect(find.text('home'), findsOneWidget);
    await tester.pumpWidget(Container());
    await tester.pumpWidget(gate(now: splashStarted.add(const Duration(seconds: 6))));
    expect(find.byKey(const ValueKey('splash')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('dark mode draws on black', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const SplashView(dark: true)));
    final box = tester.widget<Container>(find.byKey(const ValueKey('splash')));
    expect(box.color, const Color(0xFF000000));
  });
}
