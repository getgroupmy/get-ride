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
@immutable
class MapTileSpec {
  const MapTileSpec({required this.url, this.darken = false, this.attribution = ''});

  final String url;
  final bool darken;
  final String attribution;

  static MapTileSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = '${json['url'] ?? ''}'.trim();
    if (!_isTemplate(url)) return null;
    return MapTileSpec(url: url, darken: json['darken'] == true, attribution: '${json['attribution'] ?? ''}');
  }

  @override
  bool operator ==(Object other) =>
      other is MapTileSpec && other.url == url && other.darken == darken && other.attribution == attribution;

  @override
  int get hashCode => Object.hash(url, darken, attribution);
}

bool _isTemplate(String url) =>
    url.startsWith('https://') && url.contains('{z}') && url.contains('{x}') && url.contains('{y}');

/// The traffic overlay: off, a source (with an optional fallback), or the
/// app's own when [MapProfile.traffic] is null.
@immutable
class MapTrafficSpec {
  const MapTrafficSpec({this.off = false, this.url, this.fallback});

  final bool off;
  final String? url;
  final String? fallback;

  static MapTrafficSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['off'] == true) return const MapTrafficSpec(off: true);
    final url = '${json['url'] ?? ''}'.trim();
    if (!_isTemplate(url)) return null;
    final fb = '${json['fallback'] ?? ''}'.trim();
    return MapTrafficSpec(url: url, fallback: _isTemplate(fb) && fb != url ? fb : null);
  }
}

/// Providers the device calls itself; every other one goes through `geo`.
const directGeoProviders = {'nominatim', 'osrm'};

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
      nominatimUrl: url(direct['nominatim']),
      osrmUrl: url(direct['osrm']),
    );
  }
}

/// The map profile in use, set as it arrives (see `mapProfileProvider`);
/// read by the tile layers and [GeoService]. [MapProfile.builtIn] until then.
MapProfile activeMapProfile = MapProfile.builtIn;
