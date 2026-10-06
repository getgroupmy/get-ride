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
//   MAP_TILE_URL_SATELLITE  imagery for the satellite view (Expo's
//                      map-type toggle); defaults to Esri World Imagery,
//                      the same keyless source the Expo web map uses
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

const osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

const _configuredLight = String.fromEnvironment('MAP_TILE_URL');
const _configuredDark = String.fromEnvironment('MAP_TILE_URL_DARK');
const _configuredSatellite = String.fromEnvironment('MAP_TILE_URL_SATELLITE');

/// Esri World Imagery: keyless satellite tiles (note the {y}/{x} order).
const satelliteTileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// Which tiles to load, and whether they need darkening on the device.
class TileSource {
  const TileSource(this.url, {required this.darken});
  final String url;
  final bool darken;
}

/// Picks the tile source for the current theme from the configured URLs.
///
/// A dark-style URL is used as-is in dark mode. Without one, dark mode reuses
/// the light tiles and darkens them; light mode never darkens. Satellite
/// imagery is the same in both modes and never darkened (an inverted photo
/// of the ground is not a map).
TileSource resolveTileSource({
  required bool dark,
  bool satellite = false,
  String light = _configuredLight,
  String darkUrl = _configuredDark,
  String satelliteUrl = _configuredSatellite,
}) {
  if (satellite) {
    final s = satelliteUrl.trim();
    return TileSource(s.isEmpty ? satelliteTileUrl : s, darken: false);
  }
  final lightUrl = light.trim().isEmpty ? osmTileUrl : light.trim();
  if (!dark) return TileSource(lightUrl, darken: false);
  final d = darkUrl.trim();
  return d.isNotEmpty ? TileSource(d, darken: false) : TileSource(lightUrl, darken: true);
}

/// Whether a failed tile request is worth asking again: the server
/// throttling (429) or failing (5xx). Anything else (a 404, a block page)
/// would fail the same way again.
bool retryTileResponse(int statusCode) => statusCode == 429 || statusCode >= 500;

/// Whether a request that never got an answer is worth asking again: a
/// dropped connection is, a request the map cancelled itself is not.
bool retryTileError(Object error) => error is http.ClientException && error is! http.RequestAbortedException;

/// How long to wait before retry [attempt] (0-based): 0.5 s, 1 s, 2 s, 4 s,
/// so a throttled burst spreads itself out instead of failing at once.
Duration tileRetryDelay(int attempt) => Duration(milliseconds: 500 * (1 << attempt));

/// One tile provider for every map in the app. flutter_map's default retries
/// only a 503 and never a dropped request, so on the web a map that opens
/// with a burst of 20–30 tile requests to OSM's throttled server kept the
/// few that got through and showed grey for the rest, for good. It is also
/// built once rather than on every rebuild, each of which used to open (and
/// never close) its own HTTP client.
final appTileProvider = NetworkTileProvider(
  httpClient: RetryClient(
    http.Client(),
    retries: 4,
    when: (r) => retryTileResponse(r.statusCode),
    whenError: (e, _) => retryTileError(e),
    delay: tileRetryDelay,
  ),
);

/// The base tile layer for [context]'s theme, or satellite imagery.
TileLayer baseTileLayer(BuildContext context, {bool satellite = false}) {
  final source = resolveTileSource(dark: Theme.of(context).brightness == Brightness.dark, satellite: satellite);
  return TileLayer(
    // A new layer, not the old one re-pointed, so the street tiles already
    // drawn are not kept under the imagery while it loads (or vice versa).
    key: ValueKey(source.url),
    urlTemplate: source.url,
    // Only a configured URL with an {s} placeholder spreads over subdomains;
    // OSM's own server is a single host.
    subdomains: source.url.contains('{s}') ? const ['a', 'b', 'c', 'd'] : const [],
    userAgentPackageName: 'com.taxxee.teksi',
    tileProvider: appTileProvider,
    // A tile that still fails names itself and the reason in the console
    // (the browser's, on the web), which is how a grey map gets diagnosed.
    errorTileCallback: (tile, error, _) => debugPrint('Map tile ${tile.coordinates} failed: $error'),
    // OSM's public server throttles heavy users, and a browser cannot name
    // the app in its requests. On the web, skip prefetching the ring of
    // tiles just off screen: it multiplies the requests for every view.
    panBuffer: kIsWeb ? 0 : 1,
    // A tile the server refused or throttled is dropped once it is off
    // screen, so it is fetched again when scrolled back rather than staying
    // blank for good.
    evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
    // flutter_map's own dark-mode filter: inverts and hue-rotates each tile.
    tileBuilder: source.darken ? darkModeTileBuilder : null,
  );
}
