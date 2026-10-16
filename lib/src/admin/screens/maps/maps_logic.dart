// Admin → Settings → Maps (migration 0200), the pure half: the setting the
// page edits (a profile per rider/partner and kind of device, and which
// API key each provider uses), the choices for each, and Google's rule.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../security/api_keys_logic.dart';

const mapsPage = 'admin-settings-maps';

const mapRoles = ['rider', 'partner'];
const mapDevices = ['android', 'ios', 'web', 'desktop'];

String mapRoleLabel(String r) => r == 'partner' ? 'Partner' : 'Rider';

String mapDeviceLabel(String d) => switch (d) {
  'android' => 'Android',
  'ios' => 'iPhone & iPad',
  'web' => 'Web',
  _ => 'Desktop (Windows, macOS, Linux)',
};

const tileSlots = ['light', 'dark', 'satellite', 'traffic'];

String tileSlotLabel(String s) => switch (s) {
  'light' => 'Map',
  'dark' => 'Map (dark mode)',
  'satellite' => 'Satellite',
  _ => 'Traffic',
};

/// The providers each tile slot can use ('app': as the app was built).
/// 'google_js' (Google's JavaScript map) and 'google' traffic are web only
/// (migration 0204): see [tileOptionsFor].
const tileOptions = <String, List<String>>{
  'light': ['app', 'osm', 'google', 'google_js', 'mapbox', 'here', 'tomtom', 'maptiler'],
  'dark': ['app', 'osm', 'google', 'google_js', 'mapbox', 'here', 'tomtom', 'maptiler'],
  'satellite': ['app', 'esri', 'google', 'google_js', 'mapbox', 'here', 'tomtom', 'maptiler'],
  'traffic': ['app', 'tomtom', 'here', 'google', 'none'],
};

/// [tileOptions] for [slot] on [device]: Google's JavaScript map and its
/// traffic only on the web.
List<String> tileOptionsFor(String slot, String device) => [
  for (final p in tileOptions[slot]!)
    if (device == 'web' || !(p == 'google_js' || (slot == 'traffic' && p == 'google'))) p,
];

const placeProviders = ['nominatim', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'maptiler'];
const routeProviders = ['osrm', 'google', 'mapbox', 'here', 'tomtom', 'locationiq'];

/// Providers the phone calls itself (no key).
const freeProviders = {'nominatim', 'osrm', 'osm', 'esri'};

String mapProviderLabel(String p, {String slot = ''}) => switch (p) {
  'app' => switch (slot) {
    'traffic' => 'Built in (TomTom, then HERE)',
    'satellite' => 'Built in (Esri imagery)',
    'dark' => 'Built in (OpenStreetMap, darkened)',
    _ => 'Built in (OpenStreetMap)',
  },
  'osm' => slot == 'dark' ? 'OpenStreetMap (darkened)' : 'OpenStreetMap',
  'esri' => 'Esri imagery',
  'google' => slot == 'traffic' ? 'Google traffic (on Google Maps JavaScript)' : 'Google',
  'google_js' => 'Google Maps (JavaScript)',
  'mapbox' => 'Mapbox',
  'here' => 'HERE',
  'tomtom' => 'TomTom',
  'maptiler' => 'MapTiler',
  'locationiq' => 'LocationIQ',
  'nominatim' => 'OpenStreetMap (Nominatim)',
  'osrm' => 'OpenStreetMap (OSRM)',
  'none' => 'Off',
  _ => p,
};

/// One rider's or partner's maps on one kind of device.
@immutable
class MapProfileSetting {
  const MapProfileSetting({
    this.tiles = const {'light': 'app', 'dark': 'app', 'satellite': 'app', 'traffic': 'app'},
    this.search = const ['nominatim'],
    this.reverse = const ['nominatim'],
    this.routing = const ['osrm'],
  });

  final Map<String, String> tiles;
  final List<String> search;
  final List<String> reverse;
  final List<String> routing;

  factory MapProfileSetting.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final t = m['tiles'] is Map ? m['tiles'] as Map : const {};
    List<String> list(Object? v, List<String> allowed, String d) {
      final out = <String>[];
      for (final e in v is List ? v : const []) {
        if (e is String && allowed.contains(e) && !out.contains(e) && out.length < 3) out.add(e);
      }
      return out.isEmpty ? [d] : out;
    }

    return MapProfileSetting(
      tiles: {for (final s in tileSlots) s: tileOptions[s]!.contains(t[s]) ? t[s] as String : 'app'},
      search: list(m['search'], placeProviders, 'nominatim'),
      reverse: list(m['reverse'], placeProviders, 'nominatim'),
      routing: list(m['routing'], routeProviders, 'osrm'),
    );
  }

  Map<String, dynamic> toJson() => {'tiles': tiles, 'search': search, 'reverse': reverse, 'routing': routing};

  MapProfileSetting copyWith({
    Map<String, String>? tiles,
    List<String>? search,
    List<String>? reverse,
    List<String>? routing,
  }) => MapProfileSetting(
    tiles: tiles ?? this.tiles,
    search: search ?? this.search,
    reverse: reverse ?? this.reverse,
    routing: routing ?? this.routing,
  );

  MapProfileSetting withTile(String slot, String provider) => copyWith(tiles: {...tiles, slot: provider});

  /// This profile as [device] can have it: the web-only choices back to
  /// "Built in" elsewhere.
  MapProfileSetting forDevice(String device) => copyWith(
    tiles: {for (final e in tiles.entries) e.key: tileOptionsFor(e.key, device).contains(e.value) ? e.value : 'app'},
  );

  /// Every provider this profile would ask, for checking keys.
  Set<String> get providers => {...tiles.values, ...search, ...reverse, ...routing};

  /// Google's place search or geocoding without Google's map (its tiles or
  /// its JavaScript map) under it.
  bool get breaksGoogleTerms =>
      (search.contains('google') || reverse.contains('google')) &&
      (!_googleMaps.contains(tiles['light']) || !_googleMaps.contains(tiles['dark']));

  static const _googleMaps = {'google', 'google_js'};

  /// Google traffic is drawn by Google's JavaScript map, so it needs it for
  /// Map and Map (dark mode).
  bool get googleTrafficWithoutItsMap =>
      tiles['traffic'] == 'google' && (tiles['light'] != 'google_js' || tiles['dark'] != 'google_js');

  @override
  bool operator ==(Object other) =>
      other is MapProfileSetting &&
      mapEquals(other.tiles, tiles) &&
      listEquals(other.search, search) &&
      listEquals(other.reverse, reverse) &&
      listEquals(other.routing, routing);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(tiles.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAll(search),
    Object.hashAll(reverse),
    Object.hashAll(routing),
  );
}

/// A key slot: which provider (and use) it is for, and its default reference.
@immutable
class MapKeySlot {
  const MapKeySlot(this.id, this.label, this.defaultRef, {required this.providers});
  final String id;
  final String label;

  /// `<provider>/<service>` in Admin → API Keys.
  final String defaultRef;

  /// The map providers that need this slot (to tell which are in use).
  final Set<String> providers;
}

const mapKeySlots = [
  MapKeySlot('google_tiles', 'Google · map tiles', 'google/maps', providers: {'google:tiles'}),
  MapKeySlot('google_js', 'Google · Maps JavaScript (browser key)', 'google/maps_js', providers: {'google_js'}),
  MapKeySlot('google_places', 'Google · place search', 'google/places', providers: {'google:search'}),
  MapKeySlot('google_geocoding', 'Google · address lookup', 'google/geocoding', providers: {'google:reverse'}),
  MapKeySlot('google_routes', 'Google · routes', 'google/directions', providers: {'google:routing'}),
  MapKeySlot('mapbox', 'Mapbox', 'mapbox/tiles', providers: {'mapbox'}),
  MapKeySlot('here', 'HERE', 'here/api', providers: {'here'}),
  MapKeySlot('tomtom', 'TomTom', 'tomtom/api', providers: {'tomtom'}),
  MapKeySlot('maptiler', 'MapTiler', 'tiles/maptiler', providers: {'maptiler'}),
  MapKeySlot('locationiq', 'LocationIQ', 'geocoding/locationiq', providers: {'locationiq'}),
  MapKeySlot('nominatim', 'Nominatim server (optional)', 'openstreetmap/nominatim', providers: {}),
  MapKeySlot('osrm', 'OSRM server (optional)', 'openstreetmap/osrm', providers: {}),
];

/// Which Google API answers place search and routes (migration 0203): the
/// newer Places API (New) and Routes API, the older Places API (Text Search)
/// and Directions API, or the newer first and the older when it refuses.
const mapGoogleApis = [
  ('new_old', 'New, then Old if New refuses'),
  ('new', 'New only (Places API New, Routes API)'),
  ('old', 'Old only (Places API, Directions API)'),
];

/// The whole setting.
@immutable
class MapSettings {
  const MapSettings({this.profiles = const {}, this.keys = const {}, this.googleApi = 'new_old'});

  /// Keyed "rider.android" …; a missing one is [MapProfileSetting]'s default.
  final Map<String, MapProfileSetting> profiles;
  final Map<String, String> keys;

  /// One of [mapGoogleApis].
  final String googleApi;

  static String profileKey(String role, String device) => '$role.$device';

  MapProfileSetting profile(String role, String device) =>
      profiles[profileKey(role, device)] ?? const MapProfileSetting();

  String keyRef(String slot) =>
      keys[slot] ?? mapKeySlots.firstWhere((s) => s.id == slot, orElse: () => mapKeySlots.first).defaultRef;

  factory MapSettings.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final p = m['profiles'] is Map ? m['profiles'] as Map : const {};
    final k = m['keys'] is Map ? m['keys'] as Map : const {};
    return MapSettings(
      profiles: {
        for (final r in mapRoles)
          for (final d in mapDevices) profileKey(r, d): MapProfileSetting.fromJson(p[profileKey(r, d)]),
      },
      keys: {
        for (final s in mapKeySlots) s.id: k[s.id] is String && '${k[s.id]}'.isNotEmpty ? '${k[s.id]}' : s.defaultRef,
      },
      googleApi: mapGoogleApis.any((a) => a.$1 == m['googleApi']) ? '${m['googleApi']}' : 'new_old',
    );
  }

  Map<String, dynamic> toJson() => {
    'profiles': {
      for (final r in mapRoles)
        for (final d in mapDevices) profileKey(r, d): profile(r, d).toJson(),
    },
    'keys': {for (final s in mapKeySlots) s.id: keyRef(s.id)},
    'googleApi': googleApi,
  };

  MapSettings withProfile(String role, String device, MapProfileSetting p) =>
      MapSettings(profiles: {...profiles, profileKey(role, device): p}, keys: keys, googleApi: googleApi);

  /// [role]'s [device] profile copied to the other devices.
  MapSettings copiedToAllDevices(String role, String device) {
    final p = profile(role, device);
    return MapSettings(
      profiles: {...profiles, for (final d in mapDevices) profileKey(role, d): p.forDevice(d)},
      keys: keys,
      googleApi: googleApi,
    );
  }

  MapSettings withKey(String slot, String ref) =>
      MapSettings(profiles: profiles, keys: {...keys, slot: ref}, googleApi: googleApi);

  MapSettings withGoogleApi(String api) => MapSettings(profiles: profiles, keys: keys, googleApi: api);

  /// "Rider · Android, Partner · Web": the profiles Google's terms block.
  List<String> get googleConflicts => [
    for (final r in mapRoles)
      for (final d in mapDevices)
        if (profile(r, d).breaksGoogleTerms) '${mapRoleLabel(r)} · ${mapDeviceLabel(d)}',
  ];

  /// "Rider · Web": Google traffic without Google's JavaScript map.
  List<String> get googleTrafficConflicts => [
    for (final r in mapRoles)
      for (final d in mapDevices)
        if (profile(r, d).googleTrafficWithoutItsMap) '${mapRoleLabel(r)} · ${mapDeviceLabel(d)}',
  ];

  /// The key slots some profile uses ("google:search" for Google's).
  Set<String> get usedKeySlots {
    final used = <String>{};
    for (final r in mapRoles) {
      for (final d in mapDevices) {
        final p = profile(r, d);
        for (final t in p.tiles.values) {
          used.add(t == 'google' ? 'google:tiles' : t);
        }
        for (final (kind, list) in [('search', p.search), ('reverse', p.reverse), ('routing', p.routing)]) {
          for (final x in list) {
            used.add(x == 'google' ? 'google:$kind' : x);
          }
        }
      }
    }
    return {
      for (final s in mapKeySlots)
        if (s.providers.any(used.contains)) s.id,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is MapSettings &&
      mapEquals(other.profiles, profiles) &&
      mapEquals(other.keys, keys) &&
      other.googleApi == googleApi;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(profiles.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(keys.entries.map((e) => '${e.key}=${e.value}')),
    googleApi,
  );
}

/// One choice for a key slot: a service's first active key, or one key.
@immutable
class MapKeyChoice {
  const MapKeyChoice(this.ref, this.label, {this.usable = true});
  final String ref;
  final String label;

  /// Has an active key behind it.
  final bool usable;
}

/// The choices Admin → API Keys offers for [slot]: its default service's
/// first active key, then each of that service's keys (masked), then the
/// same for any other service, and the current reference if it is none of
/// those.
List<MapKeyChoice> mapKeyChoices(List<ApiProviderDef> providers, MapKeySlot slot, String current) {
  final out = <MapKeyChoice>[];
  final (pId, sId) = _split(slot.defaultRef);
  ApiServiceDef? service;
  for (final p in providers) {
    if (p.id != pId) continue;
    for (final s in p.services) {
      if (s.id == sId) service = s;
    }
  }
  final active = service?.keys.where((k) => k.isActive).toList() ?? const <ApiKeyEntry>[];
  out.add(
    MapKeyChoice(
      slot.defaultRef,
      active.isEmpty
          ? '${service?.name ?? slot.defaultRef}: no key yet'
          : '${service!.name}: first active key (${active.length})',
      usable: active.isNotEmpty,
    ),
  );
  for (final k in service?.keys ?? const <ApiKeyEntry>[]) {
    out.add(
      MapKeyChoice(
        '${slot.defaultRef}#${k.id}',
        '${k.label.isEmpty ? 'Key' : k.label} · ${maskSecret(k.value)}${k.isActive ? '' : ' (off)'}',
        usable: k.isActive,
      ),
    );
  }
  if (!out.any((c) => c.ref == current)) out.add(MapKeyChoice(current, current, usable: false));
  return out;
}

(String, String) _split(String ref) {
  final base = ref.split('#').first;
  final i = base.indexOf('/');
  return i < 0 ? (base, '') : (base.substring(0, i), base.substring(i + 1));
}

/// Whether [ref] has an active key behind it in [providers].
bool mapKeyUsable(List<ApiProviderDef> providers, String ref) {
  final (pId, sId) = _split(ref);
  final keyId = ref.contains('#') ? ref.split('#').last : null;
  for (final p in providers) {
    if (p.id != pId) continue;
    for (final s in p.services) {
      if (s.id != sId) continue;
      return s.keys.any((k) => k.isActive && (keyId == null || k.id == keyId));
    }
  }
  return false;
}

/// The z/x/y tile with [lat], [lng] at [zoom], filled into [template] (for
/// the page's Test, which draws one tile).
String sampleTileUrl(String template, double lat, double lng, {int zoom = 12}) {
  final n = 1 << zoom;
  final x = ((lng + 180) / 360 * n).floor().clamp(0, n - 1);
  final rad = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n).floor().clamp(0, n - 1);
  return template.replaceAll('{z}', '$zoom').replaceAll('{x}', '$x').replaceAll('{y}', '$y').replaceAll('{s}', 'a');
}

/// A tile template's host, to name it without its key.
String tileHost(String url) => Uri.tryParse(url)?.host ?? '';
