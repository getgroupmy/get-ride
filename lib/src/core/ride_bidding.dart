/// Fare bidding ("OfferMe") on an open ride request.
///
/// One bid at a time lives on the `ride_requests` row itself (no offers
/// table), shared with the Expo app:
/// - a partner's counter-offer stamps `offered_fare` and the partner fields
///   (`partner_id` = their auth uid) while the row stays `open`;
/// - the rider raising the fare sets `fare`/`ride_fare` and clears any bid;
/// - the rider accepting a bid moves their own row to `accepted`, keeping that
///   partner and billing the bid (`fare` = `ride_fare` = the offer), matched
///   on the exact partner and amount shown so a newer bid is never accepted
///   by mistake;
/// - the rider declining (or the bidder withdrawing) clears the bid.
/// The bidder watches the row and reads the outcome with [offerOutcome].
library;

import 'dart:convert';
import 'package:intl/intl.dart';

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import '../data/models.dart';
import 'region_pricing.dart';
import 'region_rules.dart';
import 'region_time.dart';
import 'service_tree.dart';

// ---- Region switch (Expo utils/regionBidding.ts) --------------------------

/// One `country-states-cities` region entry and its `biddingEnabled` flag.
class BiddingRegion {
  const BiddingRegion({
    required this.country,
    this.state = '',
    this.city = '',
    this.suburb = '',
    this.enabled = true,
    this.rings = const [],
    this.pricing,
    this.services,
    this.subServices = const {},
    this.rules = const [],
    this.timezone,
    this.currency,
    this.currencySymbol,
    this.blocked = false,
    RegionBlock? blockAt,
    this.boundaryAt,
    this.boundaryArea,
  }) : block = blockAt ?? (blocked ? RegionBlock.both : RegionBlock.none);

  final String country;
  final String state;
  final String city;
  final String suburb;
  final bool enabled;

  /// Mapped boundary polygons, empty when the region has none -- or when
  /// the server tested the boundary instead ([boundaryAt]).
  final List<List<LatLng>> rings;

  /// The server's answer for a region read by point (`regions_at`): whether
  /// its mapped boundary holds the point the list was read for. Null when
  /// it has no boundary, or the list came with [rings] instead. A list read
  /// for one point is only ever asked about that point.
  final bool? boundaryAt;

  /// With [boundaryAt]: the area of its smallest outline holding that point
  /// (square degrees, only compared with other regions'); see [holdingArea].
  final double? boundaryArea;

  /// Whether it has a mapped boundary, either way it came.
  bool get hasBoundary => rings.isNotEmpty || boundaryAt != null;

  /// Whether its mapped boundary holds [p]; null when it has none.
  bool? covers(LatLng p) =>
      rings.isNotEmpty ? rings.any((ring) => ring.length >= 3 && _inRing(p, ring)) : boundaryAt;

  /// The area of its smallest outline holding [p]; null when none does.
  /// Outlines are saved without their holes, so a state still covers the
  /// enclave inside it (Selangor's covers Kuala Lumpur); of two regions at
  /// the same level holding a point, the smaller is the one it is in.
  double? holdingArea(LatLng p) {
    if (rings.isEmpty) return boundaryAt == true ? boundaryArea : null;
    double? best;
    for (final ring in rings) {
      if (ring.length < 3 || !_inRing(p, ring)) continue;
      final a = _ringArea(ring);
      if (best == null || a < best) best = a;
    }
    return best;
  }

  /// How fares are priced here, when this region sets it (see
  /// [RegionPricing.fromValues]); null leaves it to the parent region.
  final RegionPricing? pricing;

  /// The `service-settings` ids switched on for this region; null when none
  /// is, which leaves it to the parent region (and, at the top, to every
  /// service).
  final Set<String>? services;

  /// Scheduled rules for some services at some times (core/region_rules.dart).
  final List<RegionRule> rules;

  /// Its Time zone field (IANA), for those rules' times.
  final String? timezone;

  /// Its currency (Country information): an ISO 4217 code, and the symbol
  /// it is printed with. Null when unset.
  final String? currency;
  final String? currencySymbol;

  /// Admin → Country / States / Cities → Services → each sub-service (a
  /// vehicle service, or anything under a master service, to any depth)
  /// switched on or off here by its settings entry id; one not listed
  /// follows the regions around it (on by default). See service_tree.dart.
  final Map<String, bool> subServices;

  /// Admin → Country / States / Cities → Block: no ride starts, stops or
  /// ends here, whatever the regions around it allow. Kept for the old
  /// switch; [block] says which (migration 0212).
  final bool blocked;

  /// What the Block stops here: pickups, drop-offs (stops and the
  /// destination) or both.
  final RegionBlock block;

  /// Whether the Block stops a ride at a point here: its pickup ([pickup])
  /// or a stop or the destination.
  bool blocks({required bool pickup}) => switch (block) {
    RegionBlock.none => false,
    RegionBlock.both => true,
    RegionBlock.pickup => pickup,
    RegionBlock.drop => !pickup,
  };

  /// Its own name: the suburb, city, state or country.
  String get name => [suburb, city, state, country].firstWhere((n) => n.isNotEmpty);

  /// 0 country … 3 suburb: the more specific region wins.
  int get specificity => suburb.isNotEmpty
      ? 3
      : city.isNotEmpty
      ? 2
      : state.isNotEmpty
      ? 1
      : 0;

  /// From a settings entry's `values`; null without a country. A missing
  /// flag means enabled, as in Expo.
  static BiddingRegion? fromValues(Map<String, dynamic> v, {bool? boundaryAt, double? boundaryArea}) {
    String s(Object? x) => x is String ? x.trim() : '';
    final country = s(v['country']);
    if (country.isEmpty) return null;
    return BiddingRegion(
      country: country,
      state: s(v['state']),
      city: s(v['city']),
      suburb: s(v['suburb']),
      enabled: v['biddingEnabled'] != false,
      rings: _parseBoundary(v['boundary']),
      pricing: RegionPricing.fromValues(v),
      services: _enabledServices(v['services']),
      subServices: regionSubServiceSwitches(v['subServices']),
      rules: parseRegionRules(v['rules']),
      timezone: s(v['timezone']).isEmpty ? null : s(v['timezone']),
      currency: RegExp(r'^[A-Za-z]{3}$').hasMatch(s(v['currencyName'])) ? s(v['currencyName']).toUpperCase() : null,
      currencySymbol: s(v['currencySymbol']).isEmpty ? null : s(v['currencySymbol']),
      blocked: v['blocked'] == true,
      blockAt: regionBlockOf(v),
      boundaryAt: boundaryAt,
      boundaryArea: boundaryArea,
    );
  }

  /// From a row of the admin's region tables (`countries`, `states`,
  /// `cities`, `suburbs`), which is where Admin → Country / States / Cities
  /// saves: the path is in the columns, the settings in `values`, the mapped
  /// boundary in `geofence`.
  static BiddingRegion? fromRegionRow(String table, Map<String, dynamic> row) {
    String col(String k) => '${row[k] ?? ''}'.trim();
    final name = col('name');
    final path = switch (table) {
      'countries' => {'country': name},
      'states' => {'country': col('country'), 'state': name},
      'cities' => {'country': col('country'), 'state': col('state'), 'city': name},
      'suburbs' => {'country': col('country'), 'state': col('state'), 'city': col('city'), 'suburb': name},
      _ => null,
    };
    if (path == null) return null;
    final gf = row['geofence'];
    return fromValues({
      if (row['values'] is Map) ...Map<String, dynamic>.from(row['values'] as Map),
      ...path,
      if (gf is Map && gf['boundary'] is String) 'boundary': gf['boundary'],
    });
  }
}

/// The cache key of a region list read for [p]: ~11 m cells, so a pickup
/// nudged by a few metres reuses the answer for the spot it moved from.
String regionLookupKey(LatLng p) => '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';

/// A row of `regions_at` (migration 0169): a region with its settings and,
/// instead of its boundary, whether the boundary holds the point asked
/// about (`inside`; null without a boundary or a point).
BiddingRegion? regionFromLookupRow(Map<String, dynamic> row) {
  String col(String k) => '${row[k] ?? ''}'.trim();
  final values = row['values'] is Map ? Map<String, dynamic>.from(row['values'] as Map) : <String, dynamic>{};
  values.remove('boundary');
  final inside = row['inside'];
  final area = row['area'];
  return BiddingRegion.fromValues(
    {...values, 'country': col('country'), 'state': col('state'), 'city': col('city'), 'suburb': col('suburb')},
    boundaryAt: inside is bool ? inside : null,
    boundaryArea: area is num ? area.toDouble() : null,
  );
}

/// The region tables, broadest first, with the columns
/// [BiddingRegion.fromRegionRow] reads when `regions_at` is missing. The
/// boundaries are left out (megabytes for the states alone): the regions
/// then match by name, as `regions_at` does without a point.
const regionTableSelects = {
  'countries': 'name, values',
  'states': 'country, name, values',
  'cities': 'country, state, name, values',
  'suburbs': 'country, state, city, name, values',
};

/// The symbols the regions give their currencies, by code (the first
/// region to name one wins), for [setRegionCurrencySymbols].
Map<String, String> regionCurrencySymbols(List<BiddingRegion> regions) {
  final out = <String, String>{};
  for (final r in regions) {
    if (r.currency != null && r.currencySymbol != null) out.putIfAbsent(r.currency!, () => r.currencySymbol!);
  }
  return out;
}

/// The switched-on ids of a region's `services` (a JSON string of
/// `{serviceId: bool}`), or null when none is on.
Set<String>? _enabledServices(Object? raw) {
  Object? j = raw;
  if (raw is String) {
    if (raw.isEmpty) return null;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (j is! Map) return null;
  final on = {
    for (final e in j.entries)
      if (e.value == true || (e.value is num && e.value != 0)) '${e.key}',
  };
  return on.isEmpty ? null : on;
}

List<List<LatLng>> _parseBoundary(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return const [];
    List<LatLng> ring(Object? pts) => [
      if (pts is List)
        for (final p in pts)
          if (p is Map && p['latitude'] is num && p['longitude'] is num)
            LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble()),
    ];
    final polygons = j['polygons'];
    if (polygons is List && polygons.isNotEmpty) {
      return [for (final p in polygons) ring(p)].where((r) => r.length >= 3).toList();
    }
    final coords = ring(j['coords']);
    if (coords.length >= 3) return [coords];
    final b = j['bbox'];
    if (b is Map && b['north'] is num && b['south'] is num && b['east'] is num && b['west'] is num) {
      final n = (b['north'] as num).toDouble(), s = (b['south'] as num).toDouble();
      final e = (b['east'] as num).toDouble(), w = (b['west'] as num).toDouble();
      return [
        [LatLng(n, w), LatLng(n, e), LatLng(s, e), LatLng(s, w)],
      ];
    }
  } catch (_) {}
  return const [];
}

bool _inRing(LatLng p, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    final dy = (yj - yi) == 0 ? 1e-12 : (yj - yi);
    if ((yi > p.latitude) != (yj > p.latitude) && p.longitude < (xj - xi) * (p.latitude - yi) / dy + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// A ring's area in square degrees (shoelace); only compared with others.
double _ringArea(List<LatLng> ring) {
  var twice = 0.0;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    twice += (ring[j].longitude * ring[i].latitude) - (ring[i].longitude * ring[j].latitude);
  }
  return twice.abs() / 2;
}

/// Whether [r], whose mapped boundary holds [p], is a better match there
/// than [best]: more specific, or as specific and smaller -- the enclave
/// inside its neighbour's outline.
bool _holdsBetter(BiddingRegion r, BiddingRegion? best, LatLng p) {
  if (best == null || r.specificity > best.specificity) return true;
  if (r.specificity < best.specificity) return false;
  final mine = r.holdingArea(p), theirs = best.holdingArea(p);
  return mine != null && (theirs == null || mine < theirs);
}

String _n(String? v) => (v ?? '').trim().toLowerCase();

/// The bidding switch of the most specific region whose mapped boundary
/// contains [pickup], or null when no boundary does.
bool? biddingByBoundary(List<BiddingRegion> regions, LatLng pickup) {
  BiddingRegion? best;
  for (final r in regions) {
    if (r.covers(pickup) == true && _holdsBetter(r, best, pickup)) best = r;
  }
  return best?.enabled;
}

/// The most specific region at [point]: one whose mapped boundary contains
/// it, else one matching [area]'s names (suburbs only by boundary, as the
/// geocoder cannot be trusted at that level) -- the region the bidding and
/// pricing rules would use there. Null when none matches. Pure.
BiddingRegion? regionAt(List<BiddingRegion> regions, LatLng point, {AreaInfo? area}) {
  BiddingRegion? best;
  for (final r in regions) {
    if (r.covers(point) == true && _holdsBetter(r, best, point)) best = r;
  }
  if (best != null) return best;
  final country = _n(area?.country);
  if (country.isEmpty) return null;
  for (final r in regions) {
    if (_n(r.country) != country || r.suburb.isNotEmpty) continue;
    if (r.state.isNotEmpty && _n(r.state) != _n(area?.state)) continue;
    if (r.city.isNotEmpty && _n(r.city) != _n(area?.city)) continue;
    if (best == null || r.specificity > best.specificity) best = r;
  }
  return best;
}

/// The place a phone reports for area broadcasts (push_set_location,
/// migration 0168): the names of the region it is in (spelt as the admin
/// spelt them, so a broadcast to that region finds it), the geocoder's for
/// any level the region leaves open. Pure.
({String? country, String? state, String? city, String? suburb}) pushPlaceAt(
  List<BiddingRegion> regions,
  LatLng point,
  AreaInfo? area,
) {
  final r = regionAt(regions, point, area: area);
  String? pick(String? fromRegion, String? fromGeocoder) {
    final v = (fromRegion ?? '').trim().isNotEmpty ? fromRegion!.trim() : (fromGeocoder ?? '').trim();
    return v.isEmpty ? null : v;
  }

  return (
    country: pick(r?.country, area?.country),
    state: pick(r?.state, area?.state),
    city: pick(r?.city, area?.city),
    suburb: pick(r?.suburb, area?.suburb),
  );
}

/// Whether riders may bid at [pickup]. The most specific region whose
/// boundary contains the point decides; failing that, the most specific
/// region matching [area]'s names (suburb rules are skipped, as the geocoder
/// cannot be trusted at that level); failing that, bidding is on.
bool biddingEnabledAt(List<BiddingRegion> regions, LatLng? pickup, {AreaInfo? area}) {
  if (pickup == null) return true;
  final byBoundary = biddingByBoundary(regions, pickup);
  if (byBoundary != null) return byBoundary;
  BiddingRegion? best;
  final country = _n(area?.country);
  if (country.isEmpty) return true;
  for (final r in regions) {
    if (_n(r.country) != country || r.suburb.isNotEmpty) continue;
    if (r.state.isNotEmpty && _n(r.state) != _n(area?.state)) continue;
    if (r.city.isNotEmpty && _n(r.city) != _n(area?.city)) continue;
    if (best == null || r.specificity > best.specificity) best = r;
  }
  return best?.enabled ?? true;
}

/// The setting [pick] reads at [pickup]: the most specific region with a
/// mapped boundary containing the point, else the most specific region
/// matching [area]'s names (suburbs skipped, as the geocoder cannot be trusted
/// at that level) — counting only regions where [pick] is not null.
T? _settingAt<T extends Object>(
  List<BiddingRegion> regions,
  LatLng? pickup,
  AreaInfo? area,
  T? Function(BiddingRegion) pick,
) {
  final set = [for (final r in regions) if (pick(r) != null) r];
  if (set.isEmpty) return null;
  if (pickup != null) {
    BiddingRegion? best;
    for (final r in set) {
      if (r.covers(pickup) == true && _holdsBetter(r, best, pickup)) best = r;
    }
    if (best != null) return pick(best);
  }
  final country = _n(area?.country);
  if (country.isEmpty) return null;
  BiddingRegion? best;
  for (final r in set) {
    if (_n(r.country) != country || r.suburb.isNotEmpty) continue;
    if (r.state.isNotEmpty && _n(r.state) != _n(area?.state)) continue;
    if (r.city.isNotEmpty && _n(r.city) != _n(area?.city)) continue;
    if (best == null || r.specificity > best.specificity) best = r;
  }
  return best == null ? null : pick(best);
}

/// The fare pricing at [pickup], chosen the way the bidding switch is,
/// counting only regions that set their own pricing; none is decimals and no
/// tax. It prices the booking flow only: Meter Digital's fares come from its
/// own rate cards and are never rounded by a region.
RegionPricing pricingAt(List<BiddingRegion> regions, LatLng? pickup, {AreaInfo? area}) =>
    _settingAt(regions, pickup, area, (r) => r.pricing) ?? RegionPricing.none;

/// The `service-settings` ids a region switches on at [pickup], chosen the
/// same way and counting only regions that switch at least one on; null
/// when none does, which leaves every service available.
Set<String>? servicesAt(List<BiddingRegion> regions, LatLng? pickup, {AreaInfo? area}) =>
    _settingAt(regions, pickup, area, (r) => r.services);

/// The regions around [pickup], most specific first: each whose mapped
/// boundary contains it, and each without a boundary whose names match
/// [area] (suburbs only by boundary, as the geocoder cannot be trusted
/// there).
List<BiddingRegion> regionsAround(List<BiddingRegion> regions, LatLng? pickup, {AreaInfo? area}) {
  final country = _n(area?.country);
  bool byNames(BiddingRegion r) {
    if (country.isEmpty || _n(r.country) != country || r.suburb.isNotEmpty) return false;
    if (r.state.isNotEmpty && _n(r.state) != _n(area?.state)) return false;
    if (r.city.isNotEmpty && _n(r.city) != _n(area?.city)) return false;
    return true;
  }

  final out = [
    for (final r in regions)
      if (r.hasBoundary ? pickup != null && r.covers(pickup) == true : byNames(r))
        r,
  ];
  double size(BiddingRegion r) => (pickup == null ? null : r.holdingArea(pickup)) ?? double.infinity;
  out.sort((a, b) {
    final bySpec = b.specificity.compareTo(a.specificity);
    return bySpec != 0 ? bySpec : size(a).compareTo(size(b));
  });
  return out;
}

// Administrative wording the geocoder adds around a place's own name
// ("Kajang Municipal Council", "Wilayah Persekutuan Kuala Lumpur").
final _adminWords = RegExp(
  r'\b(municipal council|city council|district council|town council|municipality|majlis perbandaran|'
  r'majlis bandaraya|majlis daerah|wilayah persekutuan|federal territory of|federal territory|district|daerah|'
  r'city of)\b',
);

/// A place name reduced for comparing: lower case, punctuation and the
/// geocoder's administrative wording dropped, spaces collapsed. Kept in step
/// with `region_name_norm` (migration 0126).
String placeNameKey(String? name) => (name ?? '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
    .replaceAll(_adminWords, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Whether [name] can be compared with the region names at all: it has
/// Latin letters. Empty, or in another script ("吉隆坡" from a phone set to
/// Chinese), it can't — that level is then unknown, and served.
bool comparablePlaceName(String? name) => RegExp('[a-z]').hasMatch(placeNameKey(name));

/// Whether the geocoder's [place] is the region named [region]: the
/// region's name, as whole words, within the place's ("Kajang" in "Kajang
/// Municipal Council"). Kept in step with `region_name_matches` (0126).
bool placeNameMatches(String? region, String? place) {
  final r = placeNameKey(region), p = placeNameKey(place);
  return r.isNotEmpty && p.isNotEmpty && ' $p '.contains(' $r ');
}

/// What a region's Block stops (migration 0212).
enum RegionBlock { none, pickup, drop, both }

/// A region's Block from its `values`: `blockAt`, else the old `blocked`
/// switch (both).
RegionBlock regionBlockOf(Map<String, dynamic> v) => switch (v['blockAt']) {
  'pickup' => RegionBlock.pickup,
  'drop' => RegionBlock.drop,
  'both' => RegionBlock.both,
  _ => v['blocked'] == true ? RegionBlock.both : RegionBlock.none,
};

/// Why GET.ride can't serve a point.
enum CoverageGap {
  /// In no country / state / city / suburb the admin has set up.
  outside,

  /// In one the admin has blocked.
  blocked,
}

/// The database's refusal of a ride GET.ride doesn't serve (migration
/// 0125): `SERVICE_UNAVAILABLE:<pickup|stopN|drop>:<outside|blocked>:<region>`.
class ServiceUnavailableError implements Exception {
  const ServiceUnavailableError({required this.at, this.stop = -1, required this.gap, this.region});

  /// 'pickup', 'stop' or 'drop'.
  final String at;

  /// The stop's index when [at] is 'stop'.
  final int stop;
  final CoverageGap gap;
  final String? region;

  /// The refusal in a database error message, or null when it isn't one.
  static ServiceUnavailableError? parse(String message) {
    final m = RegExp(r'SERVICE_UNAVAILABLE:(pickup|drop|stop(\d+)):(outside|blocked):([^\n]*)').firstMatch(message);
    if (m == null) return null;
    final region = m.group(4)!.trim();
    return ServiceUnavailableError(
      at: m.group(1)!.startsWith('stop') ? 'stop' : m.group(1)!,
      stop: int.tryParse(m.group(2) ?? '') ?? -1,
      gap: m.group(3) == 'blocked' ? CoverageGap.blocked : CoverageGap.outside,
      region: region.isEmpty ? null : region,
    );
  }

  @override
  String toString() => 'GET.ride is currently unavailable here.';
}

/// Whether GET.ride serves [point]: null when it does, else why not and the
/// region it concerns.
///
/// Every level is checked, top down: the point must be in one of the
/// countries; if that country has states set up, in one of them; if that
/// state has cities, in one of those; and so on to the suburbs. A region is
/// matched by its mapped boundary where it has one, else by the name the
/// geocoder gives that level ([area]). Missing a level's list is
/// [CoverageGap.outside], with the region it is in (Perak, for a town Perak
/// doesn't list); a block on any region it is in is [CoverageGap.blocked],
/// with the most specific blocked one. A region blocking only pickups or
/// only drop-offs blocks the point as the trip's [pickup], or as a stop or
/// the destination.
///
/// Errs towards serving: with no regions at all, or where a level can't be
/// told (no boundary holds the point and the geocoder gave no name for that
/// level), the check stops there and the point is served — a failed geocode
/// never strands a rider.
({CoverageGap gap, BiddingRegion? region})? coverageGap(
  List<BiddingRegion> regions,
  LatLng point, {
  AreaInfo? area,
  bool pickup = true,
}) {
  if (regions.isEmpty) return null;
  String own(BiddingRegion r, int level) => switch (level) {
    0 => r.country,
    1 => r.state,
    2 => r.city,
    _ => r.suburb,
  };
  final names = [area?.country, area?.state, area?.city, area?.suburb];
  // Whether [r] holds the point: its boundary decides, else its name; null
  // when neither can tell.
  bool? holds(BiddingRegion r, int level) {
    if (r.hasBoundary) return r.covers(point) == true;
    return comparablePlaceName(names[level]) ? placeNameMatches(own(r, level), names[level]) : null;
  }

  bool under(BiddingRegion r, BiddingRegion parent) {
    for (var l = 0; l <= parent.specificity; l++) {
      if (_n(own(r, l)) != _n(own(parent, l))) return false;
    }
    return true;
  }

  final chain = <BiddingRegion>[];
  for (var level = 0; level <= 3; level++) {
    final parent = chain.lastOrNull;
    final candidates = [
      for (final r in regions)
        if (r.specificity == level && (parent == null || under(r, parent))) r,
    ];
    if (candidates.isEmpty) break;
    final verdicts = [for (final r in candidates) holds(r, level)];
    // Of those holding it, the smallest outline: the enclave over the
    // neighbour that still covers it.
    BiddingRegion? holder;
    for (var k = 0; k < candidates.length; k++) {
      if (verdicts[k] != true) continue;
      final r = candidates[k];
      final a = r.holdingArea(point), h = holder?.holdingArea(point);
      if (holder == null || (a != null && (h == null || a < h))) holder = r;
    }
    if (holder != null) {
      chain.add(holder);
      continue;
    }
    if (verdicts.contains(null)) break;
    return (gap: CoverageGap.outside, region: parent);
  }
  final block = chain.reversed.where((r) => r.blocks(pickup: pickup)).firstOrNull;
  return block == null ? null : (gap: CoverageGap.blocked, region: block);
}

/// What a pickup's regions say about each service, now: the rules around it
/// and the regions' plain switches underneath them.
class RegionRuleContext {
  const RegionRuleContext(this.around);

  static const empty = RegionRuleContext([]);

  /// The regions around the pickup, most specific first.
  final List<BiddingRegion> around;

  /// The most specific region's time zone.
  String? get timezone => around.map((r) => r.timezone).whereType<String>().firstOrNull;

  List<RegionRules> get chain => [
    for (final r in around)
      if (r.rules.isNotEmpty) (specificity: r.specificity, rules: r.rules),
  ];

  bool get hasRules => around.any((r) => r.rules.isNotEmpty);

  /// The region's wall-clock time at [nowUtc].
  DateTime localTime(DateTime nowUtc) => regionLocalTime(timezone, nowUtc);

  /// The rules for a vehicle type ([vehicleType], a Vehicle Services id) in
  /// some Service Settings types ([types], ids) at [nowUtc].
  RuleOutcome outcomeFor({Set<String> types = const {}, String? vehicleType, required DateTime nowUtc}) =>
      resolveRules(chain, categories: types, vehicleType: vehicleType, local: localTime(nowUtc));

  /// The Service Settings types the most specific region with a Services
  /// list switches on; null when none restricts them.
  Set<String>? get allowedTypes => around.map((r) => r.services).whereType<Set<String>>().firstOrNull;

  /// Whether a vehicle type in [types] is offered now: a rule decides while
  /// one holds; else, when its region restricts the service types and the
  /// vehicle has some, one of them must be on.
  /// [lineage] is the service and every sub-service above it, nearest first
  /// (ServiceTree.lineage); without it, [vehicleType] alone.
  bool available({
    Set<String> types = const {},
    String? vehicleType,
    Iterable<String> lineage = const [],
    required DateTime nowUtc,
  }) {
    final rule = outcomeFor(types: types, vehicleType: vehicleType, nowUtc: nowUtc).available;
    if (rule != null) return rule;
    // Switched off here, or something above it is (service_tree.dart).
    final line = lineage.isNotEmpty ? lineage : [?vehicleType];
    if (!subServiceOn(line, [for (final r in around) r.subServices])) return false;
    final allowed = allowedTypes;
    if (allowed == null || types.isEmpty) return true;
    return types.any(allowed.contains);
  }

  /// Whether the fare may be bid on for this service now: a rule decides
  /// while one holds, else the region's Bidding switch ([fallback]).
  bool bidding({Set<String> types = const {}, String? vehicleType, required DateTime nowUtc, required bool fallback}) =>
      outcomeFor(types: types, vehicleType: vehicleType, nowUtc: nowUtc).bidding ?? fallback;

  /// [base] with the scheduled taxes and surcharges in force for this
  /// service now.
  RegionPricing pricingFor(
    RegionPricing base, {
    Set<String> types = const {},
    String? vehicleType,
    required DateTime nowUtc,
  }) {
    final o = outcomeFor(types: types, vehicleType: vehicleType, nowUtc: nowUtc);
    FareCharge charge(RegionRule r) =>
        FareCharge(isTax: r.kind == RuleKind.tax, name: r.name.trim(), percent: r.charge == ChargeKind.percent, value: r.amount);
    if (o.taxes == null && o.surcharges.isEmpty) return base;
    return base.withRules(
      taxes: o.taxes == null ? null : [for (final r in o.taxes!) charge(r)],
      surcharges: [for (final r in o.surcharges) charge(r)],
    );
  }
}

// ---- Rider: raising the fare ----------------------------------------------

/// Steps offered on the raise buttons (RM).
const fareRaiseSteps = [1.0, 5.0, 10.0];

/// A raise never takes the fare past this multiple of the first quote.
const maxFareMultiple = 4.0;

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// The fare after raising [current] by [step], capped at [maxFareMultiple]
/// × [quoted] (the fare the request was first priced at).
double raisedFare(double current, double step, {required double quoted}) {
  final cap = _round2(quoted * maxFareMultiple);
  final next = _round2(current + step);
  return next > cap ? cap : next;
}

// ---- Partner: counter-offers ----------------------------------------------

/// Quick counter-offer presets: the fare plus 20 / 30 / 50 %, rounded to the
/// ringgit (Expo partner-ehailing).
List<double> counterOfferPresets(double fare) => [
  for (final pct in const [20, 30, 50]) (fare * (1 + pct / 100)).roundToDouble(),
];

/// Why [offer] cannot be sent against a request priced at [fare].
String? counterOfferProblem(double offer, double fare) {
  if (!(offer > fare)) return 'Offer more than the rider\'s ${fare.toStringAsFixed(2)}.';
  if (offer > fare * maxFareMultiple) return 'That is more than ${maxFareMultiple.toStringAsFixed(0)}× the fare.';
  return null;
}

/// How long a partner's offer stands before the app withdraws it.
const counterOfferWindow = Duration(seconds: 45);

// ---- Reading the row --------------------------------------------------------

/// The bid a rider is looking at, read off their open request.
class RideOffer {
  const RideOffer({
    required this.partnerId,
    required this.amount,
    this.name,
    this.vehicle,
    this.plate,
    this.rating,
    this.trips,
    this.photo,
    this.fromLat,
    this.fromLng,
  });

  final String partnerId;
  final double amount;
  final String? name;
  final String? vehicle;
  final String? plate;
  final double? rating;

  /// The driver's completed trips, stamped by the server (migration 0237);
  /// null before it ran. See [driverTripsLabel].
  final int? trips;
  final String? photo;

  /// Where the driver was when they made the offer (`partner_accept_*`),
  /// which the rider's app routes to the pickup for the card's "3 min".
  final double? fromLat, fromLng;

  /// Same bidder and amount: what an accept is matched on.
  String get key => '$partnerId:${amount.toStringAsFixed(2)}';
}

/// The bid standing on [r], or null when there is none (or it is no longer open).
RideOffer? standingOffer(RideRequest r) {
  final amount = r.offeredFare;
  final partner = r.partnerId;
  if (r.status != RideStatus.open || amount == null || partner == null) return null;
  return RideOffer(
    partnerId: partner,
    amount: amount,
    name: r.partnerName,
    vehicle: r.partnerVehicle,
    plate: r.partnerPlate,
    rating: r.partnerRating,
    trips: r.partnerTrips,
    photo: r.partnerPhoto,
    fromLat: r.partnerAcceptLat,
    fromLng: r.partnerAcceptLng,
  );
}

/// What a driver card says of [trips] completed trips next to the rating:
/// "312 trips" with [locale]'s thousands separator, "1 trip", and "New
/// driver" for none. Null when the count isn't known (a server from before
/// migration 0237), so the card shows the rating alone. The number and its
/// word never part across a line.
String? driverTripsLabel(int? trips, {String? locale}) {
  if (trips == null) return null;
  if (trips <= 0) return 'New\u00A0driver';
  String n;
  try {
    final l = locale != null && NumberFormat.localeExists(locale) ? locale : null;
    n = NumberFormat.decimalPattern(l).format(trips);
  } catch (_) {
    n = NumberFormat.decimalPattern('en').format(trips);
  }
  return '$n\u00A0${trips == 1 ? 'trip' : 'trips'}';
}

/// The minutes an offer card shows for a drive of [routeMinutes] to the
/// pickup: whole minutes, rounded up, and never under one (inDrive shows
/// "1 min" for a driver at the kerb).
int offerEtaMinutes(double routeMinutes) => routeMinutes.isNaN || routeMinutes <= 1 ? 1 : routeMinutes.ceil();

/// Where a partner's offer stands.
enum OfferOutcome {
  /// Still on the row, waiting for the rider.
  pending,

  /// The rider accepted it: the trip is this partner's.
  won,

  /// Another partner bid after this one, or took the request.
  outbid,

  /// The rider raised the fare, which clears every bid.
  raised,

  /// The rider declined it (or it was withdrawn).
  declined,

  /// The request was cancelled or expired.
  closed,
}

/// The outcome of the offer [me] made at [amount] on a request first seen
/// at [fareWhenOffered], given the row as it is now.
OfferOutcome offerOutcome(
  RideRequest r, {
  required String me,
  required double amount,
  required double? fareWhenOffered,
}) {
  switch (r.status) {
    case RideStatus.open:
      break;
    case RideStatus.cancelled || RideStatus.expired:
      return OfferOutcome.closed;
    default:
      return r.partnerId == me ? OfferOutcome.won : OfferOutcome.outbid;
  }
  if (r.partnerId == me && r.offeredFare != null && (r.offeredFare! - amount).abs() < 0.005) {
    return OfferOutcome.pending;
  }
  if (r.partnerId != null && r.partnerId != me) return OfferOutcome.outbid;
  if (fareWhenOffered != null && r.fare != null && (r.fare! - fareWhenOffered).abs() >= 0.005) {
    return OfferOutcome.raised;
  }
  return OfferOutcome.declined;
}
