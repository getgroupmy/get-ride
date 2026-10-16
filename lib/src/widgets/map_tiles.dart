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

import '../core/map_profile.dart';
import 'google_js_layer.dart';
import 'google_js_map.dart' show googleJsSupported;
import 'google_native_layer.dart';
import 'maplibre_layer.dart';

const osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

const _configuredLight = String.fromEnvironment('MAP_TILE_URL');
const _configuredDark = String.fromEnvironment('MAP_TILE_URL_DARK');
const _configuredSatellite = String.fromEnvironment('MAP_TILE_URL_SATELLITE');

/// Esri World Imagery: keyless satellite tiles (note the {y}/{x} order).
const satelliteTileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// Which tiles to load, and whether they need darkening on the device.
class TileSource {
  const TileSource(
    this.url, {
    required this.darken,
    this.attribution = '',
    this.googleJsKey,
    this.maplibreKey,
    this.googleNative = false,
  });
  final String url;
  final bool darken;

  /// Google's JavaScript map with this browser key instead of tiles
  /// (migration 0204, web only); [url] then only names the map type.
  final String? googleJsKey;

  /// A MapLibre map instead of tiles (Amazon Location's, migration 0206,
  /// web only): [url] is its style, this key goes with its requests.
  final String? maplibreKey;

  /// Google's own map in the phone app instead of tiles (migration 0210).
  final bool googleNative;

  /// Drawn by the browser rather than from tiles.
  bool get isBrowserMap => googleJsKey != null || maplibreKey != null;

  /// The credit Admin → Settings → Maps sent with these tiles; empty for the
  /// app's own (worked out from the URL, see core/map_credit.dart).
  final String attribution;
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

/// The tiles Admin → Settings → Maps (migration 0200) set for this user and
/// device, for the theme or satellite; null where it keeps the app's own.
/// MapLibre maps only on the [web]; Google's JavaScript map there and where
/// a web view can draw it ([googleJs]); Google's own map where this build
/// can draw it ([googleNative]).
TileSource? profileTileSource(
  MapProfile profile, {
  required bool dark,
  bool satellite = false,
  bool web = kIsWeb,
  bool? googleJs,
  bool? googleNative,
}) {
  final spec = satellite ? profile.satellite : (dark ? profile.dark : profile.light);
  if (spec == null) return null;
  if (spec.isMapLibre && !web) return null;
  if (spec.isGoogleJs && !(web || (googleJs ?? googleJsSupported))) return null;
  if (spec.googleNative && !(googleNative ?? googleNativeSupported)) return null;
  return TileSource(
    spec.url,
    darken: spec.darken,
    attribution: spec.attribution,
    googleJsKey: spec.googleJsKey,
    maplibreKey: spec.maplibreKey,
    googleNative: spec.googleNative,
  );
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
final appTileProvider = NetworkTileProvider(httpClient: retryingTileClient());

/// The HTTP client behind every tile provider: retries a throttled (429) or
/// failing (5xx) tile and a dropped request, with [tileRetryDelay] between.
http.Client retryingTileClient() => RetryClient(
  http.Client(),
  retries: 4,
  when: (r) => retryTileResponse(r.statusCode),
  whenError: (e, _) => retryTileError(e),
  delay: tileRetryDelay,
);

/// The tiles a map in [context] draws: Admin → Settings → Maps' for this
/// user and device, else the app's own, for the theme or satellite.
TileSource currentTileSource(BuildContext context, {bool satellite = false}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return profileTileSource(activeMapProfile, dark: dark, satellite: satellite) ??
      resolveTileSource(dark: dark, satellite: satellite);
}

/// The base layer for [context]'s theme, or satellite imagery: tiles, or
/// Google's JavaScript map or a MapLibre map (with the app's own tiles
/// should it fail). Blank while the app waits for this user's map settings
/// ([mapProfileListenable]), then what they set.
Widget baseTileLayer(BuildContext context, {bool satellite = false}) => ValueListenableBuilder<MapProfile?>(
  valueListenable: mapProfileListenable,
  builder: (context, profile, _) => profile == null
      ? SizedBox.expand(
          key: const ValueKey('map-waiting'),
          child: ColoredBox(
            color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF242F3E) : const Color(0xFFE5E3DF),
          ),
        )
      : currentBaseLayer(context, satellite: satellite),
);

/// [baseTileLayer]'s layer for the profile in use now.
Widget currentBaseLayer(BuildContext context, {bool satellite = false}) {
  final source = currentTileSource(context, satellite: satellite);
  final maplibreKey = source.maplibreKey;
  if (maplibreKey != null) {
    return MapLibreBaseLayer(
      key: ValueKey(source.url),
      style: source.url,
      apiKey: maplibreKey,
      fallback: _tileLayer(fallbackTileSource(context, satellite: satellite)),
    );
  }
  if (source.googleNative) {
    return GoogleNativeBaseLayer(
      key: ValueKey(source.url),
      satellite: satellite,
      fallback: _tileLayer(fallbackTileSource(context, satellite: satellite)),
    );
  }
  final key = source.googleJsKey;
  if (key == null) return _tileLayer(source);
  return GoogleJsBaseLayer(
    key: ValueKey(source.url),
    apiKey: key,
    satellite: satellite,
    fallback: _tileLayer(fallbackTileSource(context, satellite: satellite)),
  );
}

/// The app's own tiles, under a browser-drawn map should it fail.
TileSource fallbackTileSource(BuildContext context, {bool satellite = false}) =>
    resolveTileSource(dark: Theme.of(context).brightness == Brightness.dark, satellite: satellite);

TileLayer _tileLayer(TileSource source) {
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
