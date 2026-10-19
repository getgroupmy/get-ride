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
/// 'google_native' (Google's own map in the phone app, migration 0210) on
/// Android and iOS; 'google_js' (Google's JavaScript map, 0204) on the web
/// and, in a web view, on desktop and phones (0213); 'apple_native' (Apple's
/// own map, MapKit, 0214) on iOS; 'amazon_js' (Amazon Location's GrabMaps
/// map, 0206) on the web; 'google' traffic with either Google map: see
/// [tileOptionsFor].
const tileOptions = <String, List<String>>{
  'light': [
    'app', 'osm', 'google', 'google_native', 'google_js', 'apple_native', 'amazon_js', //
    'mapbox', 'here', 'tomtom', 'maptiler', 'google_xyz',
  ],
  'dark': [
    'app', 'osm', 'google', 'google_native', 'google_js', 'apple_native', 'amazon_js', //
    'mapbox', 'here', 'tomtom', 'maptiler', 'google_xyz',
  ],
  'satellite': [
    'app', 'esri', 'google', 'google_native', 'google_js', 'apple_native', //
    'mapbox', 'here', 'tomtom', 'maptiler', 'google_xyz',
  ],
  'traffic': ['app', 'tomtom', 'here', 'google', 'none'],
};

/// The Google map [device] draws under the app's layers by default: its own
/// on phones, the JavaScript one on the web and desktop. Phones can have the
/// JavaScript one too (migration 0213).
String googleMapFor(String device) => device == 'android' || device == 'ios' ? 'google_native' : 'google_js';

/// [tileOptions] for [slot] on [device].
List<String> tileOptionsFor(String slot, String device) => [
  for (final p in tileOptions[slot]!)
    if (switch (p) {
      'google_native' => p == googleMapFor(device),
      'apple_native' => device == 'ios',
      'amazon_js' => device == 'web',
      _ => true,
    })
      p,
];

const placeProviders = ['nominatim', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'maptiler', 'amazon'];
const routeProviders = ['osrm', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'amazon'];

/// Who measures place search results' distance from the user (migration
/// 0205); `straight` is as the crow flies, worked out on the phone.
const distanceProviders = [...routeProviders, 'straight'];

/// Providers the phone calls itself (no key).
const freeProviders = {'nominatim', 'osrm', 'osm', 'esri', 'straight', 'google_xyz', 'apple_native'};

String mapProviderLabel(String p, {String slot = '', String device = ''}) => switch (p) {
  // The iPhone app's own map is Apple's (migration 0214).
  'app' when device == 'ios' && slot != 'traffic' => 'Built in (Apple Maps)',
  'app' => switch (slot) {
    // The build's own map (scripts/ci/map_defines.sh): TomTom's unless
    // GitHub's MAP_TILE_URL variables name another.
    'traffic' => 'Built in (TomTom, then HERE)',
    'satellite' => "Built in (this build's imagery)",
    'dark' => "Built in (this build's map: TomTom night)",
    _ => "Built in (this build's map: TomTom)",
  },
  'osm' => slot == 'dark' ? 'OpenStreetMap (darkened)' : 'OpenStreetMap',
  'esri' => 'Esri imagery',
  'google' => slot == 'traffic' ? 'Google traffic (on a Google map)' : 'Google',
  'google_js' => 'Google Maps (JavaScript)',
  'google_native' => 'Google Maps (native)',
  'apple_native' => 'Apple Maps (native)',
  'google_xyz' =>
    slot == 'dark' ? 'Google tiles, darkened (unofficial, testing only)' : 'Google tiles (unofficial, testing only)',
  'mapbox' => 'Mapbox',
  'here' => 'HERE',
  'tomtom' => 'TomTom',
  'maptiler' => 'MapTiler',
  'locationiq' => 'LocationIQ',
  'amazon' => 'Amazon Location (GrabMaps)',
  'amazon_js' => 'Amazon Location map (GrabMaps)',
  'nominatim' => 'OpenStreetMap (Nominatim)',
  'osrm' => 'OpenStreetMap (OSRM)',
  'straight' => 'Straight line (no roads)',
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
    this.distance = const ['osrm'],
    this.locate = const ['nominatim'],
  });

  final Map<String, String> tiles;
  final List<String> search;
  final List<String> reverse;
  final List<String> routing;

  /// Place search results' distance from the user.
  final List<String> distance;

  /// Who finds where Google's Autocomplete suggestions roughly are, for
  /// their distance (migration 0208). The app asks OpenStreetMap last for
  /// this, place search and address lookup ([osmFallback]).
  final List<String> locate;

  /// The lists the app falls back to OpenStreetMap (Nominatim) for.
  static const osmFallback = {'search', 'reverse', 'locate'};

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
      distance: list(m['distance'], distanceProviders, 'osrm'),
      locate: list(m['locate'], placeProviders, 'nominatim'),
    );
  }

  Map<String, dynamic> toJson() => {
    'tiles': tiles,
    'search': search,
    'reverse': reverse,
    'routing': routing,
    'distance': distance,
    'locate': locate,
  };

  MapProfileSetting copyWith({
    Map<String, String>? tiles,
    List<String>? search,
    List<String>? reverse,
    List<String>? routing,
    List<String>? distance,
    List<String>? locate,
  }) => MapProfileSetting(
    tiles: tiles ?? this.tiles,
    search: search ?? this.search,
    reverse: reverse ?? this.reverse,
    routing: routing ?? this.routing,
    distance: distance ?? this.distance,
    locate: locate ?? this.locate,
  );

  MapProfileSetting withTile(String slot, String provider) => copyWith(tiles: {...tiles, slot: provider});

  /// This profile as [device] can have it: Google's map as that device draws
  /// it, the web-only choices back to "Built in" elsewhere.
  MapProfileSetting forDevice(String device) => copyWith(
    tiles: {
      for (final e in tiles.entries)
        e.key: switch (e.value) {
          // Google's map, as this device draws it.
          'google_native' || 'google_js' => googleMapFor(device),
          final v => tileOptionsFor(e.key, device).contains(v) ? v : 'app',
        },
    },
  );

  /// Every provider this profile would ask, for checking keys.
  Set<String> get providers => {...tiles.values, ...search, ...reverse, ...routing, ...distance, ...locate};

  /// Google's place search, geocoding or distances without Google's map (its
  /// tiles or its JavaScript map) under it.
  bool get breaksGoogleTerms =>
      (search.contains('google') || reverse.contains('google') || distance.contains('google')) &&
      (!_googleMaps.contains(tiles['light']) || !_googleMaps.contains(tiles['dark']));

  static const _googleMaps = {'google', 'google_js', 'google_native'};

  /// Google traffic is drawn by Google's own or JavaScript map, so it needs
  /// one of them for Map and Map (dark mode).
  bool get googleTrafficWithoutItsMap =>
      tiles['traffic'] == 'google' &&
      (!const {'google_js', 'google_native'}.contains(tiles['light']) || tiles['dark'] != tiles['light']);

  @override
  bool operator ==(Object other) =>
      other is MapProfileSetting &&
      mapEquals(other.tiles, tiles) &&
      listEquals(other.search, search) &&
      listEquals(other.reverse, reverse) &&
      listEquals(other.routing, routing) &&
      listEquals(other.distance, distance) &&
      listEquals(other.locate, locate);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(tiles.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAll(search),
    Object.hashAll(reverse),
    Object.hashAll(routing),
    Object.hashAll(distance),
    Object.hashAll(locate),
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
  MapKeySlot('google_tiles', 'Google · map tiles (Map Tiles API)', 'google/maps', providers: {'google:tiles'}),
  MapKeySlot('google_js', 'Google · Maps JavaScript (browser key)', 'google/maps_js', providers: {'google_js'}),
  MapKeySlot('google_places', 'Google · place search', 'google/places', providers: {'google:search'}),
  MapKeySlot(
    'google_address',
    'Google · Address Validation (smart address C)',
    'google/address_validation',
    providers: {'smart:check'},
  ),
  MapKeySlot('google_geocoding', 'Google · address lookup', 'google/geocoding', providers: {'google:reverse'}),
  MapKeySlot(
    'google_routes',
    'Google · routes and distances',
    'google/directions',
    providers: {'google:routing', 'google:distance'},
  ),
  MapKeySlot('amazon', 'Amazon Location · search, address, routes', 'amazon/location', providers: {'amazon'}),
  MapKeySlot('amazon_maps', 'Amazon Location · map (browser key)', 'amazon/maps', providers: {'amazon_js'}),
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

/// How Google's place search answers (migration 0207).
const mapGoogleSearches = [
  ('text', 'Text Search (when typing stops)'),
  ('autocomplete', 'Autocomplete (as the rider types)'),
];

/// How place search results are shown and checked (migration 0207).
const mapSmartAddresses = [
  ('normal', 'Normal: as the provider gives'),
  ('a', 'A: two-line results'),
  ('b', 'B: places first'),
  ('c', 'C: Google checks addresses'),
  ('all', 'Combination: A, B and C'),
];

/// Amazon Location's regions that answer with GrabMaps data (migration 0206).
const mapAmazonRegions = [
  ('ap-southeast-5', 'Asia Pacific (Malaysia)'),
  ('ap-southeast-1', 'Asia Pacific (Singapore)'),
];

/// Google's satellite map: imagery only, or with roads and names (migration 0211).
const mapGoogleSatellites = [
  ('satellite', 'Satellite (imagery only)'),
  ('hybrid', 'Hybrid (with roads)'),
];

/// Google's light map: the roadmap, or terrain (migration 0211). Dark mode keeps the night roadmap.
const mapGoogleMaps = [
  ('roadmap', 'Roadmap'),
  ('terrain', 'Terrain (relief)'),
];

/// The whole setting.
@immutable
class MapSettings {
  const MapSettings({
    this.profiles = const {},
    this.keys = const {},
    this.googleApi = 'new_old',
    this.amazonRegion = 'ap-southeast-5',
    this.googleSearch = 'text',
    this.smartAddress = 'normal',
    this.googleSatellite = 'satellite',
    this.googleMap = 'roadmap',
  });

  /// Keyed "rider.android" …; a missing one is [MapProfileSetting]'s default.
  final Map<String, MapProfileSetting> profiles;
  final Map<String, String> keys;

  /// One of [mapGoogleApis].
  final String googleApi;

  /// One of [mapAmazonRegions].
  final String amazonRegion;

  /// One of [mapGoogleSearches].
  final String googleSearch;

  /// One of [mapSmartAddresses].
  final String smartAddress;

  /// One of [mapGoogleSatellites].
  final String googleSatellite;

  /// One of [mapGoogleMaps].
  final String googleMap;

  MapSettings copyWith({
    Map<String, MapProfileSetting>? profiles,
    Map<String, String>? keys,
    String? googleApi,
    String? amazonRegion,
    String? googleSearch,
    String? smartAddress,
    String? googleSatellite,
    String? googleMap,
  }) => MapSettings(
    profiles: profiles ?? this.profiles,
    keys: keys ?? this.keys,
    googleApi: googleApi ?? this.googleApi,
    amazonRegion: amazonRegion ?? this.amazonRegion,
    googleSearch: googleSearch ?? this.googleSearch,
    smartAddress: smartAddress ?? this.smartAddress,
    googleSatellite: googleSatellite ?? this.googleSatellite,
    googleMap: googleMap ?? this.googleMap,
  );

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
      amazonRegion: mapAmazonRegions.any((a) => a.$1 == m['amazonRegion']) ? '${m['amazonRegion']}' : 'ap-southeast-5',
      googleSearch: m['googleSearch'] == 'autocomplete' ? 'autocomplete' : 'text',
      smartAddress: mapSmartAddresses.any((a) => a.$1 == m['smartAddress']) ? '${m['smartAddress']}' : 'normal',
      googleSatellite: m['googleSatellite'] == 'hybrid' ? 'hybrid' : 'satellite',
      googleMap: m['googleMap'] == 'terrain' ? 'terrain' : 'roadmap',
    );
  }

  Map<String, dynamic> toJson() => {
    'profiles': {
      for (final r in mapRoles)
        for (final d in mapDevices) profileKey(r, d): profile(r, d).toJson(),
    },
    'keys': {for (final s in mapKeySlots) s.id: keyRef(s.id)},
    'googleApi': googleApi,
    'amazonRegion': amazonRegion,
    'googleSearch': googleSearch,
    'smartAddress': smartAddress,
    'googleSatellite': googleSatellite,
    'googleMap': googleMap,
  };

  MapSettings withProfile(String role, String device, MapProfileSetting p) =>
      copyWith(profiles: {...profiles, profileKey(role, device): p});

  /// [role]'s [device] profile copied to the other devices.
  MapSettings copiedToAllDevices(String role, String device) {
    final p = profile(role, device);
    return copyWith(profiles: {...profiles, for (final d in mapDevices) profileKey(role, d): p.forDevice(d)});
  }

  MapSettings withKey(String slot, String ref) => copyWith(keys: {...keys, slot: ref});

  MapSettings withGoogleApi(String api) => copyWith(googleApi: api);

  MapSettings withAmazonRegion(String region) => copyWith(amazonRegion: region);

  /// "Rider · Android, Partner · Web": the profiles using Google's results
  /// over another map (allowed since migration 0207; the page notes it).
  List<String> get googleConflicts => [
    for (final r in mapRoles)
      for (final d in mapDevices)
        if (profile(r, d).breaksGoogleTerms) '${mapRoleLabel(r)} · ${mapDeviceLabel(d)}',
  ];

  /// "Rider · Android": the profiles on Google's unofficial tile address
  /// (migration 0211), for testing only.
  List<String> get unofficialGoogleTiles => [
    for (final r in mapRoles)
      for (final d in mapDevices)
        if (profile(r, d).tiles.values.contains('google_xyz')) '${mapRoleLabel(r)} · ${mapDeviceLabel(d)}',
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
        for (final (kind, list) in [
          ('search', p.search),
          ('reverse', p.reverse),
          ('routing', p.routing),
          ('distance', p.distance),
        ]) {
          for (final x in list) {
            used.add(x == 'google' ? 'google:$kind' : x);
          }
        }
      }
    }
    if (smartAddress == 'c' || smartAddress == 'all') used.add('smart:check');
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
      other.googleApi == googleApi &&
      other.amazonRegion == amazonRegion &&
      other.googleSearch == googleSearch &&
      other.smartAddress == smartAddress &&
      other.googleSatellite == googleSatellite &&
      other.googleMap == googleMap;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(profiles.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(keys.entries.map((e) => '${e.key}=${e.value}')),
    googleApi,
    amazonRegion,
    googleSearch,
    smartAddress,
    googleSatellite,
    googleMap,
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

/// [value] added to Admin → API Keys under [slot]'s own service (the
/// provider and service made if missing), and the reference that picks it.
({List<ApiProviderDef> list, String ref}) addMapKey(
  List<ApiProviderDef> list,
  MapKeySlot slot,
  String label,
  String value, {
  String? id,
}) {
  final (pId, sId) = _split(slot.defaultRef);
  var out = list;
  if (!out.any((p) => p.id == pId)) out = addProvider(out, pId, id: pId);
  final provider = out.firstWhere((p) => p.id == pId);
  if (!provider.services.any((s) => s.id == sId)) out = addService(out, pId, sId, id: sId);
  final keyId = id ?? genApiId('key');
  out = addKey(out, pId, sId, label, value, id: keyId);
  return (list: out, ref: '${slot.defaultRef}#$keyId');
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

/// Why a map slot set here fell back to the app's own, as the geo function
/// said (its `refused`), in plain words for Admin → Maps → Test.
String mapRefusalText(String raw) {
  if (raw == 'No key') return 'No key for it: add one on the Keys tab or in Admin > API Keys';
  if (raw.contains('SERVICE_DISABLED')) {
    return "Google refused: Map Tiles API is not enabled in this key's Google Cloud project";
  }
  if (raw.contains('API_KEY_SERVICE_BLOCKED')) {
    return "Google refused: this key's API restrictions don't include Map Tiles API";
  }
  if (raw.contains('BILLING')) return 'Google refused: billing is not enabled for this key\'s project';
  if (raw.contains('API_KEY_INVALID') || raw.contains('INVALID_ARGUMENT')) {
    return 'Google refused: the key is not valid';
  }
  return 'Refused: $raw';
}

/// Google's JavaScript map error name in plain words (Admin → Maps → Test).
String googleJsErrorText(String name) => switch (name) {
  'ApiNotActivatedMapError' => "Google refused: Maps JavaScript API is not enabled in this key's project",
  'RefererNotAllowedMapError' => "Google refused: this site isn't in the key's website restrictions",
  'ApiTargetBlockedMapError' => "Google refused: this key's API restrictions don't include Maps JavaScript API",
  'BillingNotEnabledMapError' => "Google refused: billing is not enabled for this key's project",
  'InvalidKeyMapError' => 'Google refused: the key is not valid',
  'ExpiredKeyMapError' => 'Google refused: the key has expired',
  'MissingKeyMapError' => 'No key was sent',
  _ => 'Google refused: $name',
};
