// Admin → Settings → Maps (migration 0200): what this kind of user (rider or
// partner) gets on this kind of device (Android, iOS, web, desktop), as the
// `geo` function resolves it: the tile templates (keys included), and the
// order to ask providers for place search, reverse geocoding and routes.
// Anything unset keeps what the app was built with.
import 'package:flutter/foundation.dart';

/// The kinds of device the admin sets maps for.
enum MapDevice { android, ios, web, desktop }

/// This device's kind (Windows, macOS and Linux are all "desktop").
MapDevice currentMapDevice({bool web = kIsWeb, TargetPlatform? platform}) {
  if (web) return MapDevice.web;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => MapDevice.android,
    TargetPlatform.iOS => MapDevice.ios,
    _ => MapDevice.desktop,
  };
}

/// One tile source: an XYZ template, and whether to darken it on the device.
/// Or Google's JavaScript map (migration 0204, web only): no template, the
/// browser key and the map type, drawn under the app's own layers. Or a
/// MapLibre style (Amazon Location's map, migration 0206, web only), drawn
/// the same way.
@immutable
class MapTileSpec {
  const MapTileSpec({
    required this.url,
    this.darken = false,
    this.attribution = '',
    this.googleJsKey,
    this.maplibreKey,
  });

  /// A MapLibre map of [style] (its URL, which [url] then is), with [key]
  /// added to the provider's requests.
  const MapTileSpec.maplibre(String style, String key, {this.attribution = ''})
    : url = style,
      darken = false,
      googleJsKey = null,
      maplibreKey = key;

  /// Google's JavaScript map with this browser key.
  const MapTileSpec.googleJs(String key, {this.attribution = '', bool satellite = false})
    : url = satellite ? googleJsSatellite : googleJsRoadmap,
      darken = false,
      googleJsKey = key,
      maplibreKey = null;

  /// Stand-in "URLs" naming Google's JavaScript map types (never fetched).
  static const googleJsRoadmap = 'google-js:roadmap';
  static const googleJsSatellite = 'google-js:satellite';

  final String url;
  final bool darken;
  final String attribution;
  final String? googleJsKey;
  final String? maplibreKey;

  bool get isGoogleJs => googleJsKey != null;
  bool get isMapLibre => maplibreKey != null;

  /// Drawn by the browser (web only).
  bool get isBrowserMap => isGoogleJs || isMapLibre;

  static MapTileSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['engine'] == 'google_js') {
      final key = '${json['key'] ?? ''}'.trim();
      if (key.isEmpty) return null;
      return MapTileSpec.googleJs(
        key,
        attribution: '${json['attribution'] ?? ''}',
        satellite: json['mapType'] == 'satellite',
      );
    }
    if (json['engine'] == 'maplibre') {
      final style = '${json['style'] ?? ''}'.trim();
      final key = '${json['key'] ?? ''}'.trim();
      if (!style.startsWith('https://') || key.isEmpty) return null;
      return MapTileSpec.maplibre(style, key, attribution: '${json['attribution'] ?? ''}');
    }
    final url = '${json['url'] ?? ''}'.trim();
    if (!_isTemplate(url)) return null;
    return MapTileSpec(url: url, darken: json['darken'] == true, attribution: '${json['attribution'] ?? ''}');
  }

  @override
  bool operator ==(Object other) =>
      other is MapTileSpec &&
      other.url == url &&
      other.darken == darken &&
      other.attribution == attribution &&
      other.googleJsKey == googleJsKey &&
      other.maplibreKey == maplibreKey;

  @override
  int get hashCode => Object.hash(url, darken, attribution, googleJsKey, maplibreKey);
}

bool _isTemplate(String url) =>
    url.startsWith('https://') && url.contains('{z}') && url.contains('{x}') && url.contains('{y}');

/// The traffic overlay: off, a source (with an optional fallback), Google's
/// own on its JavaScript map ([google]), or the app's own when
/// [MapProfile.traffic] is null.
@immutable
class MapTrafficSpec {
  const MapTrafficSpec({this.off = false, this.url, this.fallback, this.google = false});

  final bool off;
  final String? url;
  final String? fallback;
  final bool google;

  static MapTrafficSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['off'] == true) return const MapTrafficSpec(off: true);
    if (json['google'] == true) return const MapTrafficSpec(google: true);
    final url = '${json['url'] ?? ''}'.trim();
    if (!_isTemplate(url)) return null;
    final fb = '${json['fallback'] ?? ''}'.trim();
    return MapTrafficSpec(url: url, fallback: _isTemplate(fb) && fb != url ? fb : null);
  }
}

/// Providers the device calls itself, and `straight`, which it works out;
/// every other one goes through `geo`.
const directGeoProviders = {'nominatim', 'osrm', 'straight'};

@immutable
class MapProfile {
  const MapProfile({
    this.light,
    this.dark,
    this.satellite,
    this.traffic,
    this.search = const ['nominatim'],
    this.reverse = const ['nominatim'],
    this.routing = const ['osrm'],
    this.distance = const ['osrm'],
    this.smartAddress = 'normal',
    this.googleAutocomplete = false,
    this.nominatimUrl,
    this.osrmUrl,
  });

  /// Nothing set: the app as it was built.
  static const builtIn = MapProfile();

  /// Null keeps the app's own tiles for that style.
  final MapTileSpec? light;
  final MapTileSpec? dark;
  final MapTileSpec? satellite;
  final MapTrafficSpec? traffic;

  /// Providers to ask, in order, until one answers.
  final List<String> search;
  final List<String> reverse;
  final List<String> routing;

  /// Who measures each place search result's distance from the user.
  final List<String> distance;

  /// Admin → Settings → Maps (migration 0207): 'normal', 'a' (clean
  /// two-line results), 'b' (places first, saved and recent on top),
  /// 'c' (Google checks a picked street address) or 'all'.
  final String smartAddress;

  /// Google's place search suggests as the rider types (Autocomplete).
  final bool googleAutocomplete;

  /// A self-hosted Nominatim or OSRM from Admin → API Keys; null for the
  /// app's own.
  final String? nominatimUrl;
  final String? osrmUrl;

  factory MapProfile.fromJson(Object? json) {
    final p = json is Map ? (json['profile'] is Map ? json['profile'] as Map : json) : const {};
    final tiles = p['tiles'] is Map ? p['tiles'] as Map : const {};
    final direct = p['direct'] is Map ? p['direct'] as Map : const {};
    List<String> list(Object? v, List<String> d) {
      final out = [
        for (final e in v is List ? v : const [])
          if (e is String && e.trim().isNotEmpty) e.trim(),
      ];
      return out.isEmpty ? d : out;
    }

    String? url(Object? v) {
      final s = '${v ?? ''}'.trim();
      return s.startsWith('https://') ? s.replaceAll(RegExp(r'/+$'), '') : null;
    }

    return MapProfile(
      light: MapTileSpec.fromJson(tiles['light']),
      dark: MapTileSpec.fromJson(tiles['dark']),
      satellite: MapTileSpec.fromJson(tiles['satellite']),
      traffic: MapTrafficSpec.fromJson(tiles['traffic']),
      search: list(p['search'], const ['nominatim']),
      reverse: list(p['reverse'], const ['nominatim']),
      routing: list(p['routing'], const ['osrm']),
      distance: list(p['distance'], const ['osrm']),
      smartAddress: const ['a', 'b', 'c', 'all'].contains(p['smartAddress']) ? p['smartAddress'] as String : 'normal',
      googleAutocomplete: p['googleSearch'] == 'autocomplete',
      nominatimUrl: url(direct['nominatim']),
      osrmUrl: url(direct['osrm']),
    );
  }
}

/// The map profile in use, set as it arrives (see `mapProfileProvider`);
/// read by the tile layers and [GeoService]. [MapProfile.builtIn] until then.
MapProfile activeMapProfile = MapProfile.builtIn;
