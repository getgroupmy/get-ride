import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_branding.dart';
import 'package:get_ride/src/data/branding_cache.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/shell/brand_splash.dart';
import 'package:get_ride/src/widgets/app_icon_changed.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('the branding row', () {
    test('reads every App Settings column, and a bad value as unset', () {
      final b = AppBranding.fromRow({
        'splash_image_url': 'https://cdn/s.png',
        'splash_bg_light': '#2DABE2',
        'splash_bg_dark': 'black',
        'app_icon_url': 'https://cdn/i.png',
        'icon_changed_at': '2026-10-09T05:00:00Z',
        'theme': {
          'light': {'accent': '#ff0000', 'nope': '#000', 'text': 'blue'},
          'dark': {'background': '#101010'},
        },
        'start_lat': 1.5,
        'start_lng': '103.7',
      });
      expect(b.splashBgLight, '#2DABE2');
      expect(b.splashBgDark, isNull);
      expect(b.appIconUrl, 'https://cdn/i.png');
      expect(b.iconChangedAt, DateTime.utc(2026, 10, 9, 5));
      expect(b.lightColors, {'accent': '#ff0000'});
      expect(b.darkColors, {'background': '#101010'});
      expect((b.startLat, b.startLng), (1.5, 103.7));
    });

    test('a database without the columns reads as nothing overridden', () {
      final b = AppBranding.fromRow({'id': 'global', 'splash_bg_color': '#ff007f'});
      expect(b, const AppBranding());
      expect(AppBranding.fromRow({'start_lat': 3.1}).startLat, isNull); // half a position is none
      expect(AppBranding.fromRow({'start_lat': 0, 'start_lng': 0}).startLat, isNull);
    });

    test('round-trips through the device cache', () {
      final b = AppBranding.fromRow({
        'splash_bg_dark': '#111111',
        'theme': {
          'dark': {'primary': '#00ff00'},
        },
        'start_lat': 2,
        'start_lng': 102,
        'icon_changed_at': '2026-10-09T05:00:00Z',
      });
      expect(AppBranding.fromRow(b.toJson()), b);
    });
  });

  group('the splash', () {
    test('white / black unless the admin picked backgrounds', () {
      const custom = AppBranding(splashBgLight: '#2DABE2', splashBgDark: '#222222');
      expect(splashBackground(dark: false), const Color(0xFFFFFFFF));
      expect(splashBackground(dark: false, branding: custom), const Color(0xFF2DABE2));
      expect(splashBackground(dark: true, branding: custom), const Color(0xFF222222));
    });

    test('"GET." stays legible: not blue on blue', () {
      expect(splashInk(dark: false), const Color(0xFF2DABE2));
      expect(splashInk(dark: true), const Color(0xFF2DABE2));
      expect(splashInk(dark: false, branding: const AppBranding(splashBgLight: '#2DABE2')), const Color(0xFFFFFFFF));
      expect(splashInk(dark: false, branding: const AppBranding(splashBgLight: '#7DD3FC')), const Color(0xFF000000));
    });

    testWidgets('draws on the admin\'s background', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SplashView(dark: true, latest: AppBranding(splashBgDark: '#123456')),
        ),
      );
      expect(tester.widget<Container>(find.byKey(const ValueKey('splash'))).color, const Color(0xFF123456));
    });
  });

  group('the theme', () {
    test('no overrides is the app\'s own theme', () {
      final light = appTheme(Brightness.light);
      final dark = appTheme(Brightness.dark);
      expect(light.colorScheme.primary, const Color(0xFF111827));
      expect(light.colorScheme.onPrimary, Colors.white);
      expect(light.scaffoldBackgroundColor, Colors.white);
      expect(dark.colorScheme.primary, const Color(0xFF2DABE2));
      expect(dark.colorScheme.onPrimary, Colors.black);
      expect(dark.scaffoldBackgroundColor, const Color(0xFF0B0F17));
    });

    test('the admin\'s colours land where the page says', () {
      final t = appTheme(
        Brightness.light,
        colors: {
          'primary': '#FFEB3B',
          'background': '#FAFAFA',
          'text': '#222222',
          'textSecondary': '#555555',
          'border': '#DDDDDD',
          'error': '#B00020',
        },
      );
      expect(t.colorScheme.primary, const Color(0xFFFFEB3B));
      expect(t.colorScheme.onPrimary, Colors.black); // legible on yellow
      expect(t.scaffoldBackgroundColor, const Color(0xFFFAFAFA));
      expect(t.colorScheme.onSurface, const Color(0xFF222222));
      expect(t.colorScheme.onSurfaceVariant, const Color(0xFF555555));
      expect(t.colorScheme.outlineVariant, const Color(0xFFDDDDDD));
      expect(t.colorScheme.error, const Color(0xFFB00020));
    });
  });

  test('maps open at the admin\'s start location, else Kuala Lumpur', () {
    applyBrandingGlobals(const AppBranding(startLat: 1.5, startLng: 103.7));
    expect(defaultCenter, const LatLng(1.5, 103.7));
    applyBrandingGlobals(const AppBranding());
    expect(defaultCenter, klCenter);
    applyBrandingGlobals(null);
    expect(defaultCenter, klCenter);
  });

  group('the app icon popup', () {
    final changed = DateTime.utc(2026, 10, 9, 5);

    test('once per change, never on a device\'s first look', () {
      expect(iconChangeUnseen(changed, null, firstLook: true), isFalse);
      expect(iconChangeUnseen(changed, null, firstLook: false), isTrue);
      expect(iconChangeUnseen(changed, changed, firstLook: false), isFalse);
      expect(iconChangeUnseen(changed, changed.subtract(const Duration(hours: 1)), firstLook: false), isTrue);
      expect(iconChangeUnseen(null, null, firstLook: false), isFalse);
    });

    test('a fresh install records the icon; the next change is told once', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await takeIconChange(AppBranding(iconChangedAt: changed)), isFalse);
      expect(await takeIconChange(AppBranding(iconChangedAt: changed)), isFalse);
      final later = AppBranding(iconChangedAt: changed.add(const Duration(days: 1)));
      expect(await takeIconChange(later), isTrue);
      expect(await takeIconChange(later), isFalse);
    });

    test('a device that had no icon published yet is told about the first one', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await takeIconChange(const AppBranding()), isFalse);
      expect(await takeIconChange(AppBranding(iconChangedAt: changed)), isTrue);
    });
  });
}
