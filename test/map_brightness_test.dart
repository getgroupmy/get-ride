// Admin → Settings → Maps → Map appearance: every map is light or dark as
// the admin says (follow the phone, follow the app's theme, always light,
// always dark), through one place (lib/src/widgets/map_brightness.dart).
//
// The guard below fails when a map widget decides its own look: reads the
// phone's brightness, sets the status bar itself, or (in the shared map
// widgets) goes by the theme's brightness instead of [mapBrightnessOf].
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_appearance.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/map_recenter.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

/// Shared map widgets that may still read the theme's brightness, and why.
const _themeAllowed = <String, String>{
  'lib/src/widgets/map_pick_icon.dart': 'the "Choose on map" icon sits in a list, not on a map',
  'lib/src/widgets/map_sheet_layout.dart': "the sheet over the map is the app's, in the app's theme",
};

/// Map code that may read the phone's brightness or set the status bar.
const _central = 'lib/src/widgets/map_brightness.dart';

final _mapImport = RegExp(
  r'''import\s+'(package:(flutter_map|apple_maps_flutter|google_maps_flutter)/|[^']*(maplibre_map|google_js_map)\.dart)''',
);

bool _sharedMapWidget(String path) {
  if (!path.startsWith('lib/src/widgets/')) return false;
  final name = path.split('/').last;
  return name.contains('map') || name.endsWith('_layer.dart') || name.endsWith('_layers.dart');
}

void main() {
  group('guard', () {
    final files = {
      for (final f in Directory('lib/src').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart')) f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
    };
    final mapFiles = {
      for (final e in files.entries)
        if (_sharedMapWidget(e.key) || _mapImport.hasMatch(e.value)) e.key: e.value,
    };

    test('finds the map widgets', () {
      for (final f in [
        'lib/src/widgets/apple_native_layer.dart',
        'lib/src/widgets/google_native_layer.dart',
        'lib/src/widgets/google_js_layer.dart',
        'lib/src/widgets/maplibre_layer.dart',
        'lib/src/widgets/map_tiles.dart',
        'lib/src/widgets/ride_map.dart',
        'lib/src/features/ride/live_ride_map.dart',
        'lib/src/features/ride/map_place_picker.dart',
      ]) {
        expect(mapFiles.keys, contains(f));
      }
    });

    test("no map reads the phone's brightness or sets the status bar itself", () {
      final offenders = <String>[];
      for (final e in mapFiles.entries) {
        if (e.key == _central) continue;
        final lines = e.value.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('//')) continue;
          if (l.contains('platformBrightness') || l.contains('AnnotatedRegion<SystemUiOverlayStyle>')) {
            offenders.add('${e.key}:${i + 1}: ${l.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'A map goes by Admin → Maps → Map appearance: use mapBrightnessOf / mapIsDark and '
            'MapStatusBarRegion (lib/src/widgets/map_brightness.dart).',
      );
    });

    test("the shared map widgets don't go by the theme's brightness", () {
      final offenders = <String>[];
      for (final e in mapFiles.entries) {
        if (!_sharedMapWidget(e.key) || e.key == _central || _themeAllowed.containsKey(e.key)) continue;
        final lines = e.value.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('//')) continue;
          if (RegExp(r'\.brightness\b').hasMatch(l)) offenders.add('${e.key}:${i + 1}: ${l.trim()}');
        }
      }
      for (final f in _themeAllowed.keys) {
        if (!(files[f] ?? '').contains('.brightness')) offenders.add('$f: allowed but reads no brightness; take it off');
      }
      expect(offenders, isEmpty, reason: 'Use mapBrightnessOf / mapIsDark (lib/src/widgets/map_brightness.dart).');
    });

    test('every base layer asks the central setting', () {
      for (final f in [
        'lib/src/widgets/apple_native_layer.dart',
        'lib/src/widgets/google_native_layer.dart',
        'lib/src/widgets/google_js_layer.dart',
        'lib/src/widgets/map_tiles.dart',
      ]) {
        expect(files[f], contains('mapIsDark('), reason: f);
      }
    });

    test('the app hands the setting to every route', () {
      final app = files['lib/src/app.dart']!;
      expect(app, contains('MapAppearanceScope('));
      expect(app, contains('mapAppearanceProvider'));
    });
  });

  group('the setting', () {
    test('read back, anything else is Follow phone', () {
      for (final m in MapAppearance.values) {
        expect(MapAppearance.fromJson(m.toJson()), m);
        expect(MapAppearance.fromJson(m.name), m);
      }
      expect(MapAppearance.fromJson(null), MapAppearance.phone);
      expect(MapAppearance.fromJson({'mode': 'purple'}), MapAppearance.phone);
      expect(MapAppearance.values.map((m) => m.label), [
        'Follow phone',
        'Follow app theme',
        'Always light',
        'Always dark',
      ]);
    });

    test('resolves against the phone and the app', () {
      for (final phone in Brightness.values) {
        for (final app in Brightness.values) {
          expect(MapAppearance.phone.resolve(phone: phone, app: app), phone);
          expect(MapAppearance.app.resolve(phone: phone, app: app), app);
          expect(MapAppearance.light.resolve(phone: phone, app: app), Brightness.light);
          expect(MapAppearance.dark.resolve(phone: phone, app: app), Brightness.dark);
        }
      }
    });
  });

  group('every map follows it', () {
    tearDown(() => applyMapProfile(MapProfile.builtIn));

    for (final mode in MapAppearance.values) {
      for (final app in Brightness.values) {
        for (final phone in Brightness.values) {
          final expected = mode.resolve(phone: phone, app: app);
          testWidgets('${mode.label}, app ${app.name}, phone ${phone.name}: ${expected.name} map', (tester) async {
            tester.platformDispatcher.platformBrightnessTestValue = phone;
            addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
            applyMapProfile(MapProfile.builtIn);
            await tester.pumpWidget(_map(mode, app));
            await tester.pump();
            final dark = expected == Brightness.dark;

            final ctx = tester.element(find.byType(PickupPin));
            expect(mapBrightnessOf(ctx), expected);
            expect(Theme.of(ctx).brightness, app, reason: "the rest of the page keeps the app's theme");

            // The tiles: the app's own, darkened on the device for a dark map.
            final tiles = tester.widget<TileLayer>(find.byType(TileLayer));
            expect(tiles.tileBuilder != null, dark);

            // The marks over it.
            final pin = tester.widget<Container>(find.byKey(const ValueKey('pickup-pin')));
            expect((pin.decoration! as BoxDecoration).color, dark ? Colors.white : Colors.black);
            final button = tester.widget<Material>(find.byKey(const ValueKey('map-recenter')));
            expect(button.color, dark ? RecenterButton.darkFill : RecenterButton.lightFill);

            // The status bar over the map.
            final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.byWidgetPredicate((w) => w is AnnotatedRegion<SystemUiOverlayStyle>),
            );
            expect(region.value, dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
          });
        }
      }
    }

    testWidgets("an admin's change reaches an open map without a restart", (tester) async {
      applyMapProfile(MapProfile.builtIn);
      await tester.pumpWidget(_map(MapAppearance.light, Brightness.light));
      await tester.pump();
      expect(tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder, isNull);

      await tester.pumpWidget(_map(MapAppearance.dark, Brightness.light));
      await tester.pump();
      expect(tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder, isNotNull);
      final pin = tester.widget<Container>(find.byKey(const ValueKey('pickup-pin')));
      expect((pin.decoration! as BoxDecoration).color, Colors.white);
    });

    testWidgets('satellite keeps light status icons on a light map', (tester) async {
      applyMapProfile(MapProfile.builtIn);
      await tester.pumpWidget(_map(MapAppearance.light, Brightness.light, satellite: true));
      await tester.pump();
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byWidgetPredicate((w) => w is AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(region.value, SystemUiOverlayStyle.light);
    });

    testWidgets('the admin dark map set for the dark slot is the one drawn', (tester) async {
      applyMapProfile(
        MapProfile.fromJson({
          'profile': {
            'tiles': {
              'light': {'url': 'https://set.example/light/{z}/{x}/{y}.png'},
              'dark': {'url': 'https://set.example/dark/{z}/{x}/{y}.png'},
            },
          },
        }),
      );
      await tester.pumpWidget(_map(MapAppearance.dark, Brightness.light));
      await tester.pump();
      expect(tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate, contains('/dark/'));

      await tester.pumpWidget(_map(MapAppearance.light, Brightness.dark));
      await tester.pump();
      expect(tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate, contains('/light/'));
    });
  });
}

Widget _map(MapAppearance mode, Brightness app, {bool satellite = false}) => MaterialApp(
  theme: ThemeData(brightness: app),
  builder: (_, child) => MapAppearanceScope(appearance: mode, child: child!),
  home: Scaffold(
    body: FlutterMap(
      options: const MapOptions(initialCenter: LatLng(3.139, 101.6869), initialZoom: 13),
      children: [
        Builder(builder: (context) => baseTileLayer(context, satellite: satellite)),
        const MarkerLayer(
          markers: [Marker(point: LatLng(3.139, 101.6869), width: 40, height: 54, child: PickupPin())],
        ),
        Align(
          alignment: Alignment.bottomRight,
          child: RecenterButton(onPressed: () {}),
        ),
      ],
    ),
  ),
);
