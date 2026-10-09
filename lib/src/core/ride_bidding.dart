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

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import '../data/models.dart';
import 'region_pricing.dart';
import 'region_rules.dart';
import 'region_time.dart';

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
    this.rules = const [],
    this.timezone,
    this.currency,
    this.currencySymbol,
    this.blocked = false,
  });

  final String country;
  final String state;
  final String city;
  final String suburb;
  final bool enabled;

  /// Mapped boundary polygons, empty when the region has none.
  final List<List<LatLng>> rings;

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

  /// Admin → Country / States / Cities → Block: no ride starts, stops or
  /// ends here, whatever the regions around it allow.
  final bool blocked;

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
  static BiddingRegion? fromValues(Map<String, dynamic> v) {
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
      rules: parseRegionRules(v['rules']),
      timezone: s(v['timezone']).isEmpty ? null : s(v['timezone']),
      currency: RegExp(r'^[A-Za-z]{3}$').hasMatch(s(v['currencyName'])) ? s(v['currencyName']).toUpperCase() : null,
      currencySymbol: s(v['currencySymbol']).isEmpty ? null : s(v['currencySymbol']),
      blocked: v['blocked'] == true,
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

/// The region tables, broadest first, with the columns [BiddingRegion.fromRegionRow] reads.
const regionTableSelects = {
  'countries': 'name, values, geofence',
  'states': 'country, name, values, geofence',
  'cities': 'country, state, name, values, geofence',
  'suburbs': 'country, state, city, name, values, geofence',
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

String _n(String? v) => (v ?? '').trim().toLowerCase();

/// The bidding switch of the most specific region whose mapped boundary
/// contains [pickup], or null when no boundary does.
bool? biddingByBoundary(List<BiddingRegion> regions, LatLng pickup) {
  BiddingRegion? best;
  for (final r in regions) {
    if (r.rings.any((ring) => ring.length >= 3 && _inRing(pickup, ring)) &&
        (best == null || r.specificity > best.specificity)) {
      best = r;
    }
  }
  return best?.enabled;
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
      if (r.rings.any((ring) => ring.length >= 3 && _inRing(pickup, ring)) &&
          (best == null || r.specificity > best.specificity)) {
        best = r;
      }
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
      if (r.rings.isNotEmpty
          ? pickup != null && r.rings.any((ring) => ring.length >= 3 && _inRing(pickup, ring))
          : byNames(r))
        r,
  ]..sort((a, b) => b.specificity.compareTo(a.specificity));
  return out;
}

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
/// with the most specific blocked one.
///
/// Errs towards serving: with no regions at all, or where a level can't be
/// told (no boundary holds the point and the geocoder gave no name for that
/// level), the check stops there and the point is served — a failed geocode
/// never strands a rider.
({CoverageGap gap, BiddingRegion? region})? coverageGap(
  List<BiddingRegion> regions,
  LatLng point, {
  AreaInfo? area,
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
    if (r.rings.isNotEmpty) return r.rings.any((ring) => ring.length >= 3 && _inRing(point, ring));
    final name = _n(names[level]);
    return name.isEmpty ? null : _n(own(r, level)) == name;
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
    final i = verdicts.indexOf(true);
    if (i >= 0) {
      chain.add(candidates[i]);
      continue;
    }
    if (verdicts.contains(null)) break;
    return (gap: CoverageGap.outside, region: parent);
  }
  final block = chain.reversed.where((r) => r.blocked).firstOrNull;
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
  bool available({Set<String> types = const {}, String? vehicleType, required DateTime nowUtc}) {
    final rule = outcomeFor(types: types, vehicleType: vehicleType, nowUtc: nowUtc).available;
    if (rule != null) return rule;
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
    photo: r.partnerPhoto,
    fromLat: r.partnerAcceptLat,
    fromLng: r.partnerAcceptLng,
  );
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
