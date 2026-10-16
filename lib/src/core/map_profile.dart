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
/// Or Google's JavaScript map (migration 0204; the web, and Windows and
/// macOS in a web view since 0210): no template, the browser key and the map
/// type, drawn under the app's own layers. Or Google's own map in the phone
/// app (0210), drawn the same way. Or a MapLibre style (Amazon Location's
/// map, migration 0206, web only).
@immutable
class MapTileSpec {
  const MapTileSpec({
    required this.url,
    this.darken = false,
    this.attribution = '',
    this.googleJsKey,
    this.maplibreKey,
    this.googleNative = false,
  });

  /// A MapLibre map of [style] (its URL, which [url] then is), with [key]
  /// added to the provider's requests.
  const MapTileSpec.maplibre(String style, String key, {this.attribution = ''})
    : url = style,
      darken = false,
      googleJsKey = null,
      maplibreKey = key,
      googleNative = false;

  /// Google's JavaScript map with this browser key, as [mapType] (one of
  /// [googleMapTypes]; by default the roadmap, or satellite when [satellite]).
  const MapTileSpec.googleJs(String key, {this.attribution = '', bool satellite = false, String? mapType})
    : url = 'google-js:${mapType ?? (satellite ? 'satellite' : 'roadmap')}',
      darken = false,
      googleJsKey = key,
      maplibreKey = null,
      googleNative = false;

  /// Google's own map in the phone app (migration 0210): the Maps SDK, with
  /// the key the release build carries.
  const MapTileSpec.googleNative({this.attribution = '', bool satellite = false, String? mapType})
    : url = 'google-native:${mapType ?? (satellite ? 'satellite' : 'roadmap')}',
      darken = false,
      googleJsKey = null,
      maplibreKey = null,
      googleNative = true;

  static const googleNativeRoadmap = 'google-native:roadmap';
  static const googleNativeSatellite = 'google-native:satellite';

  /// Stand-in "URLs" naming Google's JavaScript map types (never fetched).
  static const googleJsRoadmap = 'google-js:roadmap';
  static const googleJsSatellite = 'google-js:satellite';

  /// Google's map types: hybrid (satellite with roads and names) and terrain
  /// since migration 0211.
  static const googleMapTypes = {'roadmap', 'satellite', 'hybrid', 'terrain'};

  final String url;
  final bool darken;
  final String attribution;
  final String? googleJsKey;
  final String? maplibreKey;
  final bool googleNative;

  bool get isGoogleJs => googleJsKey != null;
  bool get isMapLibre => maplibreKey != null;

  /// Drawn by the browser (web only).
  bool get isBrowserMap => isGoogleJs || isMapLibre;

  static MapTileSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['engine'] == 'google_js') {
      final key = '${json['key'] ?? ''}'.trim();
      if (key.isEmpty) return null;
      return MapTileSpec.googleJs(key, attribution: '${json['attribution'] ?? ''}', mapType: _googleType(json));
    }
    if (json['engine'] == 'google_native') {
      return MapTileSpec.googleNative(attribution: '${json['attribution'] ?? ''}', mapType: _googleType(json));
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
      other.maplibreKey == maplibreKey &&
      other.googleNative == googleNative;

  @override
  int get hashCode => Object.hash(url, darken, attribution, googleJsKey, maplibreKey, googleNative);
}

String _googleType(Map json) =>
    MapTileSpec.googleMapTypes.contains(json['mapType']) ? '${json['mapType']}' : 'roadmap';

/// The Google map type a stand-in URL names ("google-js:hybrid" → "hybrid"),
/// or null for any other source.
String? googleMapTypeOf(String url) {
  for (final prefix in const ['google-js:', 'google-native:']) {
    if (url.startsWith(prefix)) {
      final t = url.substring(prefix.length);
      return MapTileSpec.googleMapTypes.contains(t) ? t : null;
    }
  }
  return null;
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
    this.locate = const ['nominatim'],
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

  /// Who finds where Google's Autocomplete suggestions roughly are, for
  /// their distance (migration 0208).
  final List<String> locate;

  /// [list] with OpenStreetMap (Nominatim) last when it isn't on it: place
  /// search, address lookup and [locate] fall back to it, whatever is set.
  static List<String> withOsm(List<String> list) => list.contains('nominatim') ? list : [...list, 'nominatim'];

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
      locate: list(p['locate'], const ['nominatim']),
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

/// The profile the maps draw, as it changes; null while the app waits for
/// this user's settings at start ([waitForMapProfile]), so a map shows what
/// is set first rather than the app's own map and then that.
final mapProfileListenable = ValueNotifier<MapProfile?>(MapProfile.builtIn);

/// The maps wait (blank) until [applyMapProfile]: called once at app start.
void waitForMapProfile() {
  if (identical(activeMapProfile, MapProfile.builtIn)) mapProfileListenable.value = null;
}

void applyMapProfile(MapProfile p) {
  activeMapProfile = p;
  mapProfileListenable.value = p;
}
