/// Pure half of `expo/utils/apiKeysStore.ts` (+ the key-rotation order of
/// `expo/utils/mappingClient.ts`). The whole providers list is one JSON array
/// in `app_settings` (key = `api_providers`); every mutation here returns a
/// new list that the screen writes back after re-reading the row.
library;

import 'dart:math';

const apiKeysRemoteKey = 'api_providers';

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

class ApiKeyEntry {
  const ApiKeyEntry({
    required this.id,
    required this.label,
    required this.value,
    this.useCount = 0,
    this.failedCount = 0,
    this.disabled,
    this.lastUsedAt,
    this.lastFailedAt,
    this.extra = const {},
  });

  factory ApiKeyEntry.fromJson(Object? json) {
    final m = _map(json);
    return ApiKeyEntry(
      id: '${m['id'] ?? ''}',
      label: '${m['label'] ?? ''}',
      value: '${m['value'] ?? ''}',
      useCount: _int(m['useCount']),
      failedCount: _int(m['failedCount']),
      disabled: m['disabled'] is bool ? m['disabled'] as bool : null,
      lastUsedAt: m['lastUsedAt'] is num ? (m['lastUsedAt'] as num).toInt() : null,
      lastFailedAt: m['lastFailedAt'] is num ? (m['lastFailedAt'] as num).toInt() : null,
      extra: m,
    );
  }

  final String id;
  final String label;

  /// The secret. Never logged; masked in lists ([maskSecret]).
  final String value;
  final int useCount;
  final int failedCount;
  final bool? disabled;
  final int? lastUsedAt;
  final int? lastFailedAt;

  /// The stored JSON, so fields this client doesn't know survive a save.
  final Map<String, dynamic> extra;

  bool get isDisabled => disabled == true;
  bool get hasValue => value.trim().isNotEmpty;
  bool get isActive => !isDisabled && hasValue;

  ApiKeyEntry copyWith({String? label, String? value, int? useCount, int? failedCount, bool? disabled, int? lastUsedAt, int? lastFailedAt}) =>
      ApiKeyEntry(
        id: id,
        label: label ?? this.label,
        value: value ?? this.value,
        useCount: useCount ?? this.useCount,
        failedCount: failedCount ?? this.failedCount,
        disabled: disabled ?? this.disabled,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        lastFailedAt: lastFailedAt ?? this.lastFailedAt,
        extra: extra,
      );

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'label': label,
        'value': value,
        'useCount': useCount,
        'failedCount': failedCount,
        'disabled': ?disabled,
        'lastUsedAt': ?lastUsedAt,
        'lastFailedAt': ?lastFailedAt,
      };
}

class ApiServiceDef {
  const ApiServiceDef({required this.id, required this.name, this.description, this.keys = const [], this.extra = const {}});

  factory ApiServiceDef.fromJson(Object? json) {
    final m = _map(json);
    return ApiServiceDef(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? ''}',
      description: m['description'] as String?,
      keys: [for (final k in (m['keys'] as List?) ?? const []) ApiKeyEntry.fromJson(k)],
      extra: m,
    );
  }

  final String id;
  final String name;
  final String? description;
  final List<ApiKeyEntry> keys;
  final Map<String, dynamic> extra;

  int get activeKeyCount => keys.where((k) => k.isActive).length;

  ApiServiceDef withKeys(List<ApiKeyEntry> keys) =>
      ApiServiceDef(id: id, name: name, description: description, keys: keys, extra: extra);

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'name': name,
        'description': ?description,
        'keys': [for (final k in keys) k.toJson()],
      };
}

class ApiProviderDef {
  const ApiProviderDef({required this.id, required this.name, this.description, this.category, this.services = const [], this.extra = const {}});

  factory ApiProviderDef.fromJson(Object? json) {
    final m = _map(json);
    return ApiProviderDef(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? ''}',
      description: m['description'] as String?,
      category: m['category'] as String?,
      services: [for (final s in (m['services'] as List?) ?? const []) ApiServiceDef.fromJson(s)],
      extra: m,
    );
  }

  final String id;
  final String name;
  final String? description;
  final String? category;
  final List<ApiServiceDef> services;
  final Map<String, dynamic> extra;

  int get keyCount => services.fold(0, (n, s) => n + s.keys.length);

  ApiProviderDef withServices(List<ApiServiceDef> services) =>
      ApiProviderDef(id: id, name: name, description: description, category: category, services: services, extra: extra);

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'name': name,
        'description': ?description,
        'category': ?category,
        'services': [for (final s in services) s.toJson()],
      };
}

List<ApiProviderDef> parseProviders(Object? raw) =>
    raw is List ? [for (final p in raw) ApiProviderDef.fromJson(p)] : const [];

List<Map<String, dynamic>> providersToJson(List<ApiProviderDef> list) => [for (final p in list) p.toJson()];

ApiServiceDef _svc(String id, String name, String description) => ApiServiceDef(id: id, name: name, description: description);

/// Same catalogue as Expo `DEFAULT_PROVIDERS` (ids must match).
final defaultApiProviders = <ApiProviderDef>[
  ApiProviderDef(id: 'google', name: 'Google', description: 'Google Maps Platform services', category: 'Mapping', services: [
    _svc('maps', 'Maps SDK', 'Maps SDK, tiles & static maps'),
    _svc('places', 'Places', 'Place search, autocomplete & details'),
    _svc('geocoding', 'Geocoding', 'Forward & reverse geocoding'),
    _svc('directions', 'Directions', 'Routing, ETAs & navigation'),
    _svc('distance_matrix', 'Distance Matrix', 'Travel time & distance between points'),
    _svc('roads', 'Roads', 'Snap-to-roads & speed limits'),
  ]),
  ApiProviderDef(id: 'openstreetmap', name: 'OpenStreetMap', description: 'OSM-based open services', category: 'Mapping', services: [
    _svc('nominatim', 'Nominatim', 'Geocoding & boundary lookup'),
    _svc('overpass', 'Overpass API', 'Custom Overpass server URL'),
    _svc('osrm', 'OSRM Routing', 'Open Source Routing Machine'),
  ]),
  ApiProviderDef(id: 'mapbox', name: 'Mapbox', description: 'Mapbox tiles, geocoding & navigation', category: 'Mapping', services: [
    _svc('tiles', 'Tiles & Geocoding', 'Maps & geocoding access token'),
    _svc('navigation', 'Navigation', 'Turn-by-turn navigation SDK'),
  ]),
  ApiProviderDef(id: 'here', name: 'HERE', description: 'HERE maps, routing & traffic', category: 'Mapping', services: [
    _svc('api', 'HERE API', 'Maps, geocoding, routing & traffic'),
    _svc('app_id', 'HERE App ID', 'Legacy HERE App ID'),
  ]),
  ApiProviderDef(id: 'tomtom', name: 'TomTom', description: 'TomTom maps, search & traffic', category: 'Mapping', services: [
    _svc('api', 'TomTom API', 'Maps, search, routing & traffic'),
  ]),
  ApiProviderDef(id: 'microsoft', name: 'Microsoft', description: 'Azure & Bing Maps services', category: 'Mapping', services: [
    _svc('azure_maps', 'Azure Maps', 'Microsoft Azure Maps services'),
    _svc('bing_maps', 'Bing Maps', 'Bing Maps tiles, geocoding & routes'),
  ]),
  ApiProviderDef(id: 'apple', name: 'Apple', description: 'Apple MapKit JS', category: 'Mapping', services: [
    _svc('mapkit_token', 'MapKit JS Token', 'MapKit JS auth token (JWT)'),
  ]),
  ApiProviderDef(id: 'esri', name: 'Esri', description: 'ArcGIS basemaps & services', category: 'Mapping', services: [
    _svc('arcgis', 'ArcGIS API', 'ArcGIS basemaps, geocoding & routing'),
  ]),
  ApiProviderDef(id: 'tiles', name: 'Tile Providers', description: 'Vector & raster tile providers', category: 'Tiles', services: [
    _svc('maptiler', 'MapTiler', 'Vector tiles & geocoding'),
    _svc('stadia_maps', 'Stadia Maps', 'Tiles, geocoding & routing'),
    _svc('thunderforest', 'Thunderforest', 'OSM-based styled tiles'),
  ]),
  ApiProviderDef(id: 'routing', name: 'Routing', description: 'Routing & matrix providers', category: 'Routing', services: [
    _svc('graphhopper', 'GraphHopper', 'Routing, matrix & geocoding'),
  ]),
  ApiProviderDef(id: 'geocoding', name: 'Geocoding', description: 'Forward & reverse geocoding providers', category: 'Geocoding', services: [
    _svc('locationiq', 'LocationIQ', 'Geocoding & maps (Nominatim-based)'),
    _svc('opencage', 'OpenCage', 'Forward & reverse geocoding'),
    _svc('geoapify', 'Geoapify', 'Geocoding, places, routing & isolines'),
    _svc('positionstack', 'Positionstack', 'Forward & reverse geocoding'),
    _svc('what3words', 'what3words', '3-word address conversion'),
  ]),
  ApiProviderDef(id: 'geofencing', name: 'Geofencing', description: 'Geofencing & tracking', category: 'Geofencing', services: [
    _svc('radar', 'Radar', 'Geofencing, geocoding & tracking'),
  ]),
  ApiProviderDef(id: 'places', name: 'Places', description: 'Places & venue data', category: 'Places', services: [
    _svc('foursquare', 'Foursquare', 'Places search & venue data'),
  ]),
  ApiProviderDef(id: 'google_gemini', name: 'Google Gemini', description: 'Google Gemini AI models', category: 'AI', services: [
    _svc('generative_language', 'Generative Language API', 'Gemini text, chat & multimodal generation'),
    _svc('vision', 'Vision', 'Image understanding & OCR via Gemini'),
    _svc('embeddings', 'Embeddings', 'Text embeddings (text-embedding-004)'),
  ]),
  ApiProviderDef(id: 'ip_geolocation', name: 'IP Geolocation', description: 'IP-based geolocation services', category: 'IP Geolocation', services: [
    _svc('ipinfo', 'IPinfo', 'IP geolocation lookups'),
    _svc('ipgeolocation', 'ipgeolocation.io', 'IP-based geolocation service'),
  ]),
];

/// Adds missing default providers/services without touching edits; defaults
/// first (in catalogue order), then custom providers.
({List<ApiProviderDef> list, bool changed}) mergeDefaultProviders(List<ApiProviderDef> stored) {
  var changed = false;
  final byId = {for (final p in stored) p.id: p};
  for (final def in defaultApiProviders) {
    final existing = byId[def.id];
    if (existing == null) {
      byId[def.id] = def;
      changed = true;
      continue;
    }
    final have = existing.services.map((s) => s.id).toSet();
    final missing = def.services.where((s) => !have.contains(s.id)).toList();
    if (missing.isNotEmpty) {
      byId[def.id] = existing.withServices([...existing.services, ...missing]);
      changed = true;
    }
  }
  final defaultIds = defaultApiProviders.map((d) => d.id).toSet();
  return (
    list: [
      for (final d in defaultApiProviders) byId[d.id]!,
      ...stored.where((p) => !defaultIds.contains(p.id)),
    ],
    changed: changed,
  );
}

final _rand = Random();

/// `<prefix>_<base36 time>_<5 random base36 chars>`, like Expo `genId`.
String genApiId(String prefix, [DateTime? now]) {
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36);
  final r = List.generate(5, (_) => _rand.nextInt(36).toRadixString(36)).join();
  return '${prefix}_${t}_$r';
}

List<ApiProviderDef> addProvider(List<ApiProviderDef> list, String name, {String? id}) => [
      ...list,
      ApiProviderDef(id: id ?? genApiId('prov'), name: name.trim(), category: 'Custom'),
    ];

List<ApiProviderDef> removeProvider(List<ApiProviderDef> list, String providerId) =>
    list.where((p) => p.id != providerId).toList();

List<ApiProviderDef> _mapServices(
  List<ApiProviderDef> list,
  String providerId,
  List<ApiServiceDef> Function(List<ApiServiceDef>) f,
) =>
    [for (final p in list) p.id == providerId ? p.withServices(f(p.services)) : p];

List<ApiProviderDef> _mapKeys(
  List<ApiProviderDef> list,
  String providerId,
  String serviceId,
  List<ApiKeyEntry> Function(ApiServiceDef) f,
) =>
    _mapServices(list, providerId, (svcs) => [for (final s in svcs) s.id == serviceId ? s.withKeys(f(s)) : s]);

List<ApiProviderDef> addService(List<ApiProviderDef> list, String providerId, String name, {String? description, String? id}) =>
    _mapServices(list, providerId, (svcs) => [
          ...svcs,
          ApiServiceDef(
            id: id ?? genApiId('svc'),
            name: name.trim(),
            description: (description?.trim().isEmpty ?? true) ? null : description!.trim(),
          ),
        ]);

List<ApiProviderDef> removeService(List<ApiProviderDef> list, String providerId, String serviceId) =>
    _mapServices(list, providerId, (svcs) => svcs.where((s) => s.id != serviceId).toList());

/// Blank labels become "Key N" (N = position in that service).
List<ApiProviderDef> addKey(List<ApiProviderDef> list, String providerId, String serviceId, String label, String value,
        {String? id}) =>
    _mapKeys(list, providerId, serviceId, (s) => [
          ...s.keys,
          ApiKeyEntry(
            id: id ?? genApiId('key'),
            label: label.trim().isEmpty ? 'Key ${s.keys.length + 1}' : label.trim(),
            value: value.trim(),
          ),
        ]);

List<ApiProviderDef> updateKey(List<ApiProviderDef> list, String providerId, String serviceId, String keyId,
        ApiKeyEntry Function(ApiKeyEntry) patch) =>
    _mapKeys(list, providerId, serviceId, (s) => [for (final k in s.keys) k.id == keyId ? patch(k) : k]);

List<ApiProviderDef> removeKey(List<ApiProviderDef> list, String providerId, String serviceId, String keyId) =>
    _mapKeys(list, providerId, serviceId, (s) => s.keys.where((k) => k.id != keyId).toList());

/// Success bumps `useCount` + `lastUsedAt`; failure bumps `failedCount` +
/// `lastFailedAt` (epoch ms).
List<ApiProviderDef> reportKeyUsage(List<ApiProviderDef> list, String providerId, String serviceId, String keyId, bool success,
        {DateTime? now}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return updateKey(list, providerId, serviceId, keyId, (k) =>
      success ? k.copyWith(useCount: k.useCount + 1, lastUsedAt: ms) : k.copyWith(failedCount: k.failedCount + 1, lastFailedAt: ms));
}

/// Keys in the order failover tries them: enabled keys with a value, fewest
/// failures first, then least used (stable for ties).
List<ApiKeyEntry> rotationOrder(ApiServiceDef service) {
  final indexed = [
    for (var i = 0; i < service.keys.length; i++)
      if (service.keys[i].isActive) (i, service.keys[i]),
  ];
  indexed.sort((a, b) {
    final f = a.$2.failedCount.compareTo(b.$2.failedCount);
    if (f != 0) return f;
    final u = a.$2.useCount.compareTo(b.$2.useCount);
    return u != 0 ? u : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// The key the next call would use (Expo `pickNextKey`).
ApiKeyEntry? pickNextKey(ApiServiceDef service) {
  final order = rotationOrder(service);
  return order.isEmpty ? null : order.first;
}

/// The failover loop of Expo `runWithMappingRotation`, for an already
/// resolved service (null = nothing assigned → [fallback]). Keyless services
/// are tried once with an empty key; otherwise each key is tried in
/// [rotationOrder], [report]ing every attempt, and the last non-ok value wins
/// over the fallback when every key fails.
Future<T> runKeyRotation<T>({
  required ApiServiceDef? service,
  required Future<({bool ok, T value})> Function(String key) perform,
  required Future<T> Function() fallback,
  Future<void> Function(String keyId, bool success)? report,
}) async {
  if (service == null) return fallback();
  Future<void> rep(String id, bool ok) async {
    try {
      await report?.call(id, ok);
    } catch (_) {}
  }

  final keys = rotationOrder(service);
  if (keys.isEmpty) {
    try {
      final r = await perform('');
      if (r.ok) return r.value;
    } catch (_) {}
    return fallback();
  }
  T? last;
  var hadValue = false;
  for (final k in keys) {
    try {
      final r = await perform(k.value);
      if (r.ok) {
        await rep(k.id, true);
        return r.value;
      }
      await rep(k.id, false);
      last = r.value;
      hadValue = true;
    } catch (_) {
      await rep(k.id, false);
    }
  }
  if (hadValue && last != null) return last;
  return fallback();
}

/// Masks a secret for lists: only the last 4 characters are ever shown, and
/// short values show none.
String maskSecret(String value) {
  final v = value.trim();
  if (v.isEmpty) return '(empty)';
  if (v.length <= 8) return '••••';
  return '••••${v.substring(v.length - 4)}';
}

({int services, int keys}) providerTotals(List<ApiProviderDef> list) => (
      services: list.fold(0, (n, p) => n + p.services.length),
      keys: list.fold(0, (n, p) => n + p.keyCount),
    );

bool matchesProvider(ApiProviderDef p, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [p.name, p.description ?? '', p.category ?? ''].any((s) => s.toLowerCase().contains(q));
}

bool matchesService(ApiServiceDef s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return s.name.toLowerCase().contains(q) || (s.description ?? '').toLowerCase().contains(q);
}
