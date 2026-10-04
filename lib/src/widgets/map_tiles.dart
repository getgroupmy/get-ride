// The map's base tiles, shared by every FlutterMap in the app.
//
// By default these are OpenStreetMap's standard tiles, which need no key. In
// dark mode the same tiles are darkened on the device rather than fetched
// from a dark-style provider: the CARTO "dark matter" tiles used before
// started answering public sites with an "API KEY REQUIRED" placeholder.
//
// For production traffic point the app at a keyed provider (OSM's own
// servers are for light use only) with --dart-define:
//
//   MAP_TILE_URL       light tiles, e.g. a MapTiler / Stadia / CARTO URL
//                      with its key in the query string
//   MAP_TILE_URL_DARK  optional dark-style tiles; when unset, the light
//                      tiles are darkened instead
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

const osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

const _configuredLight = String.fromEnvironment('MAP_TILE_URL');
const _configuredDark = String.fromEnvironment('MAP_TILE_URL_DARK');

/// Which tiles to load, and whether they need darkening on the device.
class TileSource {
  const TileSource(this.url, {required this.darken});
  final String url;
  final bool darken;
}

/// Picks the tile source for the current theme from the configured URLs.
///
/// A dark-style URL is used as-is in dark mode. Without one, dark mode reuses
/// the light tiles and darkens them; light mode never darkens.
TileSource resolveTileSource({
  required bool dark,
  String light = _configuredLight,
  String darkUrl = _configuredDark,
}) {
  final lightUrl = light.trim().isEmpty ? osmTileUrl : light.trim();
  if (!dark) return TileSource(lightUrl, darken: false);
  final d = darkUrl.trim();
  return d.isNotEmpty ? TileSource(d, darken: false) : TileSource(lightUrl, darken: true);
}

/// The base tile layer for [context]'s theme.
TileLayer baseTileLayer(BuildContext context) {
  final source = resolveTileSource(dark: Theme.of(context).brightness == Brightness.dark);
  return TileLayer(
    urlTemplate: source.url,
    subdomains: const ['a', 'b', 'c', 'd'],
    userAgentPackageName: 'com.taxxee.teksi',
    // flutter_map's own dark-mode filter: inverts and hue-rotates each tile.
    tileBuilder: source.darken ? darkModeTileBuilder : null,
  );
}
