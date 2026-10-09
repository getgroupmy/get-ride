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
