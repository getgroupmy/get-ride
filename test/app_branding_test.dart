import 'dart:convert';

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
  test('the branding row parses with defaults', () {
    final b = AppBranding.fromRow({'splash_image_url': ' https://cdn/s.png ', 'splash_bg_color': '#000'});
    expect(b.splashImageUrl, 'https://cdn/s.png');
    expect(b.showsSplash, isTrue);
    expect(b.background, const Color(0xFF000000));

    final empty = AppBranding.fromRow(null);
    expect(empty.showsSplash, isFalse);
    expect(empty.splashBgColor, '#2dabe2');
    expect(AppBranding.fromRow({'splash_bg_color': 'pink'}).background, const Color(0xFF2DABE2));
    expect(AppBranding.fromRow({'splash_image_url': 'file:///x.png'}).showsSplash, isFalse);
    expect(AppBranding.fromRow(b.toJson()), b);
  });

  test('the cache round-trips and a broken one is ignored', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await BrandingCache.load(), isNull);
    SharedPreferences.setMockInitialValues({
      'app_branding_v1': jsonEncode({'splash_image_url': null, 'splash_bg_color': '#FFFFFF'}),
    });
    expect((await BrandingCache.load())!.branding, const AppBranding(splashBgColor: '#FFFFFF'));
    SharedPreferences.setMockInitialValues({'app_branding_v1': 'not json'});
    expect(await BrandingCache.load(), isNull);
  });

  Widget app(CachedBranding? cached) => MaterialApp(
    home: BrandSplash(cached: cached, child: const Text('home')),
  );

  testWidgets('the splash covers the app, then fades away', (tester) async {
    await tester.pumpWidget(app(CachedBranding(const AppBranding(splashImageUrl: 'https://cdn/s.png'), _png)));
    expect(find.byKey(const ValueKey('brand-splash')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('home'), findsOneWidget); // built underneath from the first frame
    await tester.pump(splashHold);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brand-splash')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('no image means no splash', (tester) async {
    await tester.pumpWidget(app(const CachedBranding(AppBranding(splashBgColor: '#000000'))));
    expect(find.byKey(const ValueKey('brand-splash')), findsNothing);
    await tester.pumpWidget(app(null));
    expect(find.byKey(const ValueKey('brand-splash')), findsNothing);
  });
}
