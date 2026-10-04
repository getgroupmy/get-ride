// The base map tiles: keyless OpenStreetMap by default, darkened on the
// device in dark mode, and a configured provider when one is set.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';

void main() {
  test('defaults to OpenStreetMap, darkened only in dark mode', () {
    final light = resolveTileSource(dark: false, light: '', darkUrl: '');
    expect(light.url, osmTileUrl);
    expect(light.darken, isFalse);

    final dark = resolveTileSource(dark: true, light: '', darkUrl: '');
    expect(dark.url, osmTileUrl);
    expect(dark.darken, isTrue);
  });

  test('a configured light URL is used in both modes, darkened in dark mode', () {
    const url = 'https://tiles.example.com/{z}/{x}/{y}.png?key=k';
    expect(resolveTileSource(dark: false, light: url, darkUrl: '').url, url);
    final dark = resolveTileSource(dark: true, light: url, darkUrl: '');
    expect(dark.url, url);
    expect(dark.darken, isTrue);
  });

  test('a configured dark URL is used as-is in dark mode', () {
    const darkUrl = 'https://tiles.example.com/dark/{z}/{x}/{y}.png?key=k';
    final s = resolveTileSource(dark: true, light: '', darkUrl: darkUrl);
    expect(s.url, darkUrl);
    expect(s.darken, isFalse);
    expect(resolveTileSource(dark: false, light: '', darkUrl: darkUrl).url, osmTileUrl);
  });

  test('the default build no longer uses the keyed CARTO tiles', () {
    expect(resolveTileSource(dark: true).url, isNot(contains('cartocdn')));
  });
}
