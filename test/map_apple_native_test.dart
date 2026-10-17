// Apple's own map on iPhones (Admin → Settings → Maps, migration 0214): read
// from the profile, iOS only, the iPhone's built-in map and its fallback.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/maps/maps_logic.dart';
import 'package:get_ride/src/core/map_credit.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';

void main() {
  test("Apple's map from the profile: no key, no tiles, its map type", () {
    final light = MapTileSpec.fromJson({'url': '', 'engine': 'apple_native', 'mapType': 'roadmap'})!;
    final satellite = MapTileSpec.fromJson({'url': '', 'engine': 'apple_native', 'mapType': 'hybrid'})!;
    expect(light.appleNative, isTrue);
    expect(light.googleNative || light.isBrowserMap, isFalse);
    expect(googleMapTypeOf(light.url), 'roadmap');
    expect(googleMapTypeOf(satellite.url), 'hybrid');
  });

  test('only where Apple\'s map can be drawn', () {
    const spec = MapTileSpec.appleNative();
    const profile = MapProfile(light: spec, dark: spec);
    expect(profileTileSource(profile, dark: false, appleNative: true)!.appleNative, isTrue);
    expect(profileTileSource(profile, dark: false, appleNative: false), isNull, reason: 'Android: the app\'s own');
  });

  test("the iPhone's built-in map is Apple's; elsewhere the build's tiles", () {
    expect(builtInTileSource(dark: true, apple: true).appleNative, isTrue);
    expect(builtInTileSource(dark: false, satellite: true, apple: true).url, 'apple-native:satellite');
    expect(builtInTileSource(dark: false, apple: false).appleNative, isFalse);
    expect(mapBrandFor('apple-native:roadmap'), '', reason: 'Apple draws its own logo');
  });

  test('Admin → Maps: Apple Maps on the iOS rows only, no key', () {
    expect(tileOptionsFor('light', 'ios'), contains('apple_native'));
    expect(tileOptionsFor('satellite', 'ios'), contains('apple_native'));
    for (final device in ['android', 'web', 'desktop']) {
      expect(tileOptionsFor('light', device), isNot(contains('apple_native')), reason: device);
    }
    expect(freeProviders, contains('apple_native'));
    expect(mapProviderLabel('apple_native'), 'Apple Maps (native)');
    expect(mapProviderLabel('app', slot: 'light', device: 'ios'), 'Built in (Apple Maps)');
    expect(mapProviderLabel('app', slot: 'traffic', device: 'ios'), 'Built in (TomTom, then HERE)');
    expect(mapProviderLabel('app', slot: 'light', device: 'android'), "Built in (this build's map: TomTom)");
  });
}
