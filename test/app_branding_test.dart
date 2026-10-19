import 'dart:async';
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

    test('a moment, not five seconds (PERF-19), all of it at process start', () {
      expect(splashMinHold <= const Duration(milliseconds: 600), isTrue);
      expect(splashMaxHold < const Duration(seconds: 5), isTrue);
      expect(splashRemaining(start, started: start), splashMinHold);
      expect(splashRemaining(start, started: start, hold: splashMaxHold), splashMaxHold);
    });

    test('less once start-up has taken a while, and never negative', () {
      expect(
        splashRemaining(start.add(const Duration(milliseconds: 200)), started: start),
        splashMinHold - const Duration(milliseconds: 200),
      );
      expect(splashRemaining(start.add(const Duration(seconds: 9)), started: start), Duration.zero);
    });
  });

  test('the apps hold a splash; web and desktop do not', () {
    expect(splashHeld(isWeb: false, platform: TargetPlatform.android), isTrue);
    expect(splashHeld(isWeb: false, platform: TargetPlatform.iOS), isTrue);
    expect(splashHeld(isWeb: true, platform: TargetPlatform.android), isFalse);
    expect(splashHeld(isWeb: false, platform: TargetPlatform.macOS), isFalse);
  });

  test('white in light mode, black in dark', () {
    expect(splashBackground(dark: false), const Color(0xFFFFFFFF));
    expect(splashBackground(dark: true), const Color(0xFF000000));
    // "GET." is the brand blue on either.
    expect(splashInk(dark: false), const Color(0xFF2DABE2));
    expect(splashInk(dark: true), const Color(0xFF2DABE2));
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

  Widget gate({
    CachedBranding? cached,
    ValueListenable<AppBranding?>? live,
    Future<void>? ready,
    bool held = true,
    DateTime? now,
  }) =>
      MaterialApp(
        home: SplashGate(
          cached: cached,
          live: live,
          ready: ready,
          held: held,
          now: () => now ?? splashStarted,
          child: const Text('home'),
        ),
      );

  testWidgets('holds the app behind the splash only for the least hold when ready', (tester) async {
    await tester.pumpWidget(gate(cached: CachedBranding(const AppBranding(splashImageUrl: 'https://cdn/s.png'), _png)));
    expect(find.byKey(const ValueKey('splash')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-image')), findsOneWidget);
    expect(find.text('home'), findsNothing); // not built until the splash is done
    await tester.pump(splashMinHold);
    expect(find.byKey(const ValueKey('splash')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('without a picture it shows "GET." in the brand blue', (tester) async {
    await tester.pumpWidget(gate());
    expect(find.byKey(const ValueKey('splash-wordmark')), findsOneWidget);
    expect(find.text('GET.'), findsOneWidget);
    expect(tester.widget<Text>(find.text('GET.')).style!.color, const Color(0xFF2DABE2));
    await tester.pump(splashMaxHold);
  });

  testWidgets('a picture fetched by this launch replaces the cached one', (tester) async {
    final live = ValueNotifier<AppBranding?>(null);
    await tester.pumpWidget(gate(live: live));
    expect(find.byKey(const ValueKey('splash-wordmark')), findsOneWidget);
    live.value = const AppBranding(splashImageUrl: 'https://cdn/new.png');
    await tester.pump();
    expect(find.byKey(const ValueKey('splash-image')), findsOneWidget);
    await tester.pump(splashMaxHold);
  });

  testWidgets('waits for the app to be ready, but no longer than the most hold', (tester) async {
    final ready = Completer<void>();
    await tester.pumpWidget(gate(ready: ready.future));
    await tester.pump(splashMinHold);
    expect(find.byKey(const ValueKey('splash')), findsOneWidget); // still checking for updates
    ready.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('home'), findsOneWidget);
    expect(splashGone.isCompleted, isTrue);

    await tester.pumpWidget(Container());
    await tester.pumpWidget(gate(ready: Completer<void>().future)); // never answers
    await tester.pump(splashMaxHold - const Duration(milliseconds: 1));
    expect(find.text('home'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('home'), findsOneWidget);

    await tester.pumpWidget(Container());
    final failing = Completer<void>();
    await tester.pumpWidget(gate(ready: failing.future));
    failing.completeError('offline'); // an error counts as ready
    await tester.pump(splashMinHold);
    expect(find.text('home'), findsOneWidget);
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
