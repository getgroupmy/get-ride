// Own maps on the office NAS (migration 0319, deploy/nas-maps): routes
// (OSRM), place search (Photon) and the web map (Protomaps tiles) from
// OpenStreetMap. The settings (a Default rule and region rules), the NAS's
// check-in (each service's health, the weekly refresh) and what it answered.
// Pure: tested in test/nas_maps_test.dart.
import 'package:flutter/foundation.dart';

/// The parts the NAS can do, as the settings name them.
enum NasMapsPart {
  routes('Routes and travel times', 'Fare estimates, ETAs, "follow roads" (OSRM).'),
  search('Place search and address lookup', 'Search boxes and the address under the pin (Photon).'),
  tiles('Map on the web', 'The map in the web app (OpenStreetMap tiles). Phones keep their own map.');

  const NasMapsPart(this.label, this.help);
  final String label;
  final String help;
}

const nasTimeoutMin = 300;
const nasTimeoutMax = 5000;
const nasTimeoutDefault = 1500;

int _timeout(Object? v) =>
    v is num ? ((v / 100).round() * 100).clamp(nasTimeoutMin, nasTimeoutMax).toInt() : nasTimeoutDefault;

/// One rule. In the Default rule every part is set; a region rule sets only
/// the parts it overrides (null: as the wider rule says).
@immutable
class NasMapsRule {
  const NasMapsRule({this.routes, this.search, this.tiles, this.timeoutMs});

  final bool? routes;
  final bool? search;
  final bool? tiles;
  final int? timeoutMs;

  static const defaults = NasMapsRule(routes: true, search: true, tiles: true, timeoutMs: nasTimeoutDefault);

  factory NasMapsRule.fromJson(Object? json, {bool full = false}) {
    final m = json is Map ? json : const {};
    bool? b(String k) => m[k] is bool ? m[k] as bool : (full ? true : null);
    return NasMapsRule(
      routes: b('routes'),
      search: b('search'),
      tiles: b('tiles'),
      timeoutMs: m['timeoutMs'] is num ? _timeout(m['timeoutMs']) : (full ? nasTimeoutDefault : null),
    );
  }

  Map<String, dynamic> toJson() => {'routes': ?routes, 'search': ?search, 'tiles': ?tiles, 'timeoutMs': ?timeoutMs};

  bool? part(NasMapsPart p) => switch (p) {
    NasMapsPart.routes => routes,
    NasMapsPart.search => search,
    NasMapsPart.tiles => tiles,
  };

  /// [p] set to [on] (null: as the wider rule says).
  NasMapsRule withPart(NasMapsPart p, bool? on) => NasMapsRule(
    routes: p == NasMapsPart.routes ? on : routes,
    search: p == NasMapsPart.search ? on : search,
    tiles: p == NasMapsPart.tiles ? on : tiles,
    timeoutMs: timeoutMs,
  );

  NasMapsRule withTimeout(int? ms) =>
      NasMapsRule(routes: routes, search: search, tiles: tiles, timeoutMs: ms == null ? null : _timeout(ms));

  /// This rule over [wider]: what it sets wins.
  NasMapsRule over(NasMapsRule wider) => NasMapsRule(
    routes: routes ?? wider.routes,
    search: search ?? wider.search,
    tiles: tiles ?? wider.tiles,
    timeoutMs: timeoutMs ?? wider.timeoutMs,
  );

  bool get isEmpty => routes == null && search == null && tiles == null && timeoutMs == null;

  @override
  bool operator ==(Object other) =>
      other is NasMapsRule &&
      other.routes == routes &&
      other.search == search &&
      other.tiles == tiles &&
      other.timeoutMs == timeoutMs;

  @override
  int get hashCode => Object.hash(routes, search, tiles, timeoutMs);
}

/// A region rule: a country, and optionally its state, city and suburb.
@immutable
class NasMapsRegion {
  const NasMapsRegion({required this.country, this.state, this.city, this.suburb, this.rule = const NasMapsRule()});

  final String country;
  final String? state;
  final String? city;
  final String? suburb;
  final NasMapsRule rule;

  static NasMapsRegion? fromJson(Object? json) {
    if (json is! Map) return null;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final country = s(json['country']);
    if (country == null) return null;
    return NasMapsRegion(
      country: country,
      state: s(json['state']),
      city: s(json['city']),
      suburb: s(json['suburb']),
      rule: NasMapsRule.fromJson(json),
    );
  }

  Map<String, dynamic> toJson() => {
    'country': country,
    'state': ?state,
    'city': ?city,
    'suburb': ?suburb,
    ...rule.toJson(),
  };

  /// 1 country, 2 state, 3 city, 4 suburb.
  int get depth => suburb != null
      ? 4
      : city != null
      ? 3
      : state != null
      ? 2
      : 1;

  /// "Bangsar, Kuala Lumpur, Malaysia": the most specific first.
  String get name => [?suburb, ?city, ?state, country].join(', ');

  NasMapsRegion withRule(NasMapsRule r) =>
      NasMapsRegion(country: country, state: state, city: city, suburb: suburb, rule: r);

  bool samePlace(NasMapsRegion o) =>
      _n(o.country) == _n(country) && _n(o.state) == _n(state) && _n(o.city) == _n(city) && _n(o.suburb) == _n(suburb);

  /// Whether this region holds a place of these names.
  bool holds({required String country, String? state, String? city, String? suburb}) =>
      _n(this.country) == _n(country) &&
      (this.state == null || _n(this.state) == _n(state)) &&
      (this.city == null || _n(this.city) == _n(city)) &&
      (this.suburb == null || _n(this.suburb) == _n(suburb));

  @override
  bool operator ==(Object other) => other is NasMapsRegion && samePlace(other) && other.rule == rule;

  @override
  int get hashCode => Object.hash(_n(country), _n(state), _n(city), _n(suburb), rule);
}

String _n(String? s) => (s ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// app_settings 'nas_maps', as nas_maps_normalize keeps it.
@immutable
class NasMapsSettings {
  const NasMapsSettings({
    this.defaultRule = NasMapsRule.defaults,
    this.regions = const [],
    this.routeCost = 5,
    this.searchCost = 17,
  });

  final NasMapsRule defaultRule;
  final List<NasMapsRegion> regions;

  /// What Google charges, USD per 1,000 routes and per 1,000 searches: for
  /// the "saved" figure.
  final double routeCost;
  final double searchCost;

  factory NasMapsSettings.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final cost = m['googleCost'] is Map ? m['googleCost'] as Map : const {};
    double c(Object? v, double d) => v is num ? v.toDouble().clamp(0, 100).toDouble() : d;
    return NasMapsSettings(
      defaultRule: NasMapsRule.fromJson(m['default'], full: true),
      regions: [for (final r in m['regions'] is List ? m['regions'] as List : const []) ?NasMapsRegion.fromJson(r)],
      routeCost: c(cost['route'], 5),
      searchCost: c(cost['search'], 17),
    );
  }

  Map<String, dynamic> toJson() => {
    'default': defaultRule.toJson(),
    'regions': [for (final r in regions) r.toJson()],
    'googleCost': {'route': routeCost, 'search': searchCost},
  };

  NasMapsSettings copyWith({
    NasMapsRule? defaultRule,
    List<NasMapsRegion>? regions,
    double? routeCost,
    double? searchCost,
  }) => NasMapsSettings(
    defaultRule: defaultRule ?? this.defaultRule,
    regions: regions ?? this.regions,
    routeCost: routeCost ?? this.routeCost,
    searchCost: searchCost ?? this.searchCost,
  );

  /// [region] added, or put in place of the rule for the same place.
  NasMapsSettings withRegion(NasMapsRegion region) {
    final i = regions.indexWhere((r) => r.samePlace(region));
    final list = [...regions];
    if (i < 0) {
      list.add(region);
    } else {
      list[i] = region;
    }
    return copyWith(regions: list);
  }

  NasMapsSettings withoutRegion(NasMapsRegion region) => copyWith(
    regions: [
      for (final r in regions)
        if (!r.samePlace(region)) r,
    ],
  );

  /// The rule at a place of these names: the Default rule, then each region
  /// holding it from the widest to the most specific, as the server does.
  NasMapsRule ruleFor({required String country, String? state, String? city, String? suburb}) {
    final holding = [
      for (final (i, r) in regions.indexed)
        if (r.holds(country: country, state: state, city: city, suburb: suburb)) (i, r),
    ]..sort((a, b) => a.$2.depth != b.$2.depth ? a.$2.depth.compareTo(b.$2.depth) : a.$1.compareTo(b.$1));
    var rule = defaultRule;
    for (final (_, r) in holding) {
      rule = r.rule.over(rule);
    }
    return rule;
  }

  @override
  bool operator ==(Object other) =>
      other is NasMapsSettings &&
      other.defaultRule == defaultRule &&
      listEquals(other.regions, regions) &&
      other.routeCost == routeCost &&
      other.searchCost == searchCost;

  @override
  int get hashCode => Object.hash(defaultRule, Object.hashAll(regions), routeCost, searchCost);
}

/// "Routes on, search off, timeout 2.0 s" for a region rule; only what it sets.
String nasRuleSummary(NasMapsRule r) {
  final parts = <String>[
    if (r.routes != null) 'routes ${r.routes! ? 'on' : 'off'}',
    if (r.search != null) 'search ${r.search! ? 'on' : 'off'}',
    if (r.tiles != null) 'web map ${r.tiles! ? 'on' : 'off'}',
    if (r.timeoutMs != null) 'wait ${nasSeconds(r.timeoutMs)}',
  ];
  if (parts.isEmpty) return 'As the Default rule';
  final s = parts.join(', ');
  return s[0].toUpperCase() + s.substring(1);
}

/// "1.5 s" from milliseconds; "–" for none.
String nasSeconds(int? ms) => ms == null ? '–' : '${(ms / 1000).toStringAsFixed(1)} s';

// ---- The NAS's check-in (nas_services 'maps') ----------------------------------------------

/// One service's check: up, and how long it took.
@immutable
class NasCheck {
  const NasCheck({this.ok = false, this.ms, this.bytes});
  final bool ok;
  final int? ms;
  final int? bytes;

  static NasCheck? fromJson(Object? json) {
    if (json is! Map) return null;
    return NasCheck(
      ok: json['ok'] == true,
      ms: json['ms'] is num ? (json['ms'] as num).toInt() : null,
      bytes: json['bytes'] is num ? (json['bytes'] as num).toInt() : null,
    );
  }
}

/// The weekly refresh (refresh.sh), as the agent reads its status file.
@immutable
class NasRefresh {
  const NasRefresh({
    this.running = false,
    this.stage,
    this.percent,
    this.lastOkAt,
    this.lastError,
    this.dataDate,
    this.tilesDate,
    this.nextAt,
  });

  final bool running;
  final String? stage;
  final int? percent;
  final DateTime? lastOkAt;
  final String? lastError;
  final DateTime? dataDate;
  final DateTime? tilesDate;
  final DateTime? nextAt;

  factory NasRefresh.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return NasRefresh(
      running: m['running'] == true,
      stage: s(m['stage']),
      percent: m['percent'] is num ? (m['percent'] as num).toInt().clamp(0, 100) : null,
      lastOkAt: t(m['lastOkAt']),
      lastError: s(m['lastError']),
      dataDate: t(m['dataDate']),
      tilesDate: t(m['tilesDate']),
      nextAt: t(m['nextAt']),
    );
  }

  /// "Building routes (15%)".
  String get stageLabel {
    final what = switch (stage) {
      'download' => 'Downloading OpenStreetMap',
      'routes' => 'Building routes',
      'search' => 'Building search',
      'tiles' => 'Getting the map',
      'style' => 'Making the map styles',
      'swap' => 'Switching to the new maps',
      _ => 'Refreshing',
    };
    return percent == null ? what : '$what ($percent%)';
  }
}

/// The service row and its detail.
@immutable
class NasMapsService {
  const NasMapsService({
    this.status = 'down',
    this.online = false,
    this.lastSeen,
    this.version,
    this.osrm,
    this.photon,
    this.tiles,
    this.tunnel,
    this.refresh = const NasRefresh(),
    this.mapsUrl,
    this.tilesUrl,
    this.secretSet = false,
  });

  /// ok | degraded | refreshing | down.
  final String status;
  final bool online;
  final DateTime? lastSeen;
  final String? version;
  final NasCheck? osrm;
  final NasCheck? photon;
  final NasCheck? tiles;
  final NasCheck? tunnel;
  final NasRefresh refresh;
  final String? mapsUrl;
  final String? tilesUrl;
  final bool secretSet;

  static NasMapsService? fromJson(Object? json) {
    if (json is! Map) return null;
    final d = json['detail'] is Map ? json['detail'] as Map : const {};
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    const statuses = {'ok', 'degraded', 'refreshing', 'down'};
    return NasMapsService(
      status: statuses.contains(json['status']) ? json['status'] as String : 'degraded',
      online: json['online'] == true,
      lastSeen: DateTime.tryParse('${json['last_seen']}')?.toLocal(),
      version: s(json['version']),
      osrm: NasCheck.fromJson(d['osrm']),
      photon: NasCheck.fromJson(d['photon']),
      tiles: NasCheck.fromJson(d['tiles']),
      tunnel: NasCheck.fromJson(d['tunnel']),
      refresh: NasRefresh.fromJson(d['refresh']),
      mapsUrl: s(d['mapsUrl']),
      tilesUrl: s(d['tilesUrl']),
      secretSet: d['secretSet'] == true,
    );
  }

  /// What GET.ride can use now: online and, per part, that service up.
  bool serves(NasMapsPart p) =>
      online &&
      status != 'down' &&
      switch (p) {
        NasMapsPart.routes => osrm?.ok ?? false,
        NasMapsPart.search => photon?.ok ?? false,
        NasMapsPart.tiles => (tiles?.ok ?? false) && tilesUrl != null,
      };

  /// The headline: "Working", "Part working", "Refreshing the maps", "Down", "Offline".
  String get headline {
    if (!online) return 'Offline';
    return switch (status) {
      'ok' => 'Working',
      'degraded' => 'Part working',
      'refreshing' => 'Refreshing the maps',
      _ => 'Down',
    };
  }
}

/// A connected NAS (nas_map_servers).
@immutable
class NasMapsServer {
  const NasMapsServer({
    required this.id,
    required this.label,
    this.model,
    this.appVersion,
    this.lastSeenAt,
    this.online = false,
    this.mapsUrl,
    this.tilesUrl,
    this.secretSet = false,
  });

  final String id;
  final String label;
  final String? model;
  final String? appVersion;
  final DateTime? lastSeenAt;
  final bool online;
  final String? mapsUrl;
  final String? tilesUrl;
  final bool secretSet;

  static NasMapsServer? fromJson(Object? json) {
    if (json is! Map || json['id'] == null) return null;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return NasMapsServer(
      id: '${json['id']}',
      label: s(json['label']) ?? 'Office NAS',
      model: s(json['model']),
      appVersion: s(json['app_version']),
      lastSeenAt: DateTime.tryParse('${json['last_seen_at']}')?.toLocal(),
      online: json['online'] == true,
      mapsUrl: s(json['maps_url']),
      tilesUrl: s(json['tiles_url']),
      secretSet: json['secret_set'] == true,
    );
  }
}

/// What the NAS answered of one kind, today or in 30 days.
@immutable
class NasUsage {
  const NasUsage({this.served = 0, this.failed = 0, this.timedOut = 0, this.avgMs});
  final int served;
  final int failed;
  final int timedOut;
  final int? avgMs;

  factory NasUsage.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    return NasUsage(
      served: n(m['served']),
      failed: n(m['failed']),
      timedOut: n(m['timedOut']),
      avgMs: m['avgMs'] is num ? (m['avgMs'] as num).toInt() : null,
    );
  }

  int get asked => served + failed + timedOut;

  NasUsage operator +(NasUsage o) {
    final ms = served + o.served == 0
        ? null
        : (((avgMs ?? 0) * served + (o.avgMs ?? 0) * o.served) / (served + o.served)).round();
    return NasUsage(served: served + o.served, failed: failed + o.failed, timedOut: timedOut + o.timedOut, avgMs: ms);
  }
}

/// The kinds the geo function counts, with their labels.
const nasUsageKinds = [
  ('routing', 'Routes'),
  ('distance', 'Distances'),
  ('search', 'Searches'),
  ('reverse', 'Address lookups'),
];

/// admin_nas_maps_status().
@immutable
class NasMapsStatus {
  const NasMapsStatus({
    this.settings = const NasMapsSettings(),
    this.service,
    this.servers = const [],
    this.today = const {},
    this.days30 = const {},
  });

  final NasMapsSettings settings;
  final NasMapsService? service;
  final List<NasMapsServer> servers;
  final Map<String, NasUsage> today;
  final Map<String, NasUsage> days30;

  factory NasMapsStatus.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final usage = m['usage'] is Map ? m['usage'] as Map : const {};
    Map<String, NasUsage> pick(String when) => {
      for (final e in usage.entries)
        if (e.value is Map) '${e.key}': NasUsage.fromJson((e.value as Map)[when]),
    };
    return NasMapsStatus(
      settings: NasMapsSettings.fromJson(m['settings']),
      service: NasMapsService.fromJson(m['service']),
      servers: [for (final s in m['servers'] is List ? m['servers'] as List : const []) ?NasMapsServer.fromJson(s)],
      today: pick('today'),
      days30: pick('days30'),
    );
  }

  /// USD not spent on Google in the last 30 days: what the NAS answered,
  /// at the admin's prices.
  double get savedUsd30 {
    int served(String k) => days30[k]?.served ?? 0;
    return (served('routing') + served('distance')) * settings.routeCost / 1000 +
        (served('search') + served('reverse')) * settings.searchCost / 1000;
  }
}

/// "USD 12.34".
String nasUsd(double v) => 'USD ${v.toStringAsFixed(2)}';

/// "20 s ago", "3 min ago", "2 h ago", "4 days ago".
String nasAgo(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return '${d.inSeconds.clamp(0, 59)} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

/// "1.2 GB" from bytes.
String nasBytes(int? b) {
  if (b == null) return '–';
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(b / 1024).toStringAsFixed(0)} kB';
}
