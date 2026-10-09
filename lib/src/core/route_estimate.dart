/// Traffic-aware route estimate from the `ai-route-proxy` edge function
/// (Expo `utils/geminiRoute.ts` → `estimateViaProxy`). The function runs the
/// admin's fare-AI provider with keys that never reach the app, and answers
/// `{ ok, estimate: { distance_km, duration_min, summary, provider,
/// toll_count, toll_total, tolls } | null, reason }`.
library;

/// One toll plaza on the route.
class TollBooth {
  const TollBooth({this.name, required this.charge, this.lat, this.lng});
  final String? name;
  final double charge;

  /// Where the booth is, when the model gave a usable position.
  final double? lat;
  final double? lng;
  bool get located => lat != null && lng != null;
}

/// A toll mark for the map: each located booth, or — when the model listed
/// tolls but placed none — one "Toll road" mark at the middle of [route]
/// (Expo's ride-confirm fallback).
typedef TollMark = ({double lat, double lng, String label});

List<TollMark> tollMarks(RouteEstimate? e, List<({double lat, double lng})> route) {
  if (e == null) return const [];
  final located = [for (final t in e.tolls) if (t.located) (lat: t.lat!, lng: t.lng!, label: t.name ?? 'Toll')];
  if (located.isNotEmpty) return located;
  final any = e.tolls.isNotEmpty || (e.tollCount ?? 0) > 0;
  if (!any || route.isEmpty) return const [];
  final mid = route[route.length ~/ 2];
  return [(lat: mid.lat, lng: mid.lng, label: 'Toll road')];
}

/// How many booths to report: the model's count, else the booths it listed.
int tollBoothCount(RouteEstimate? e) {
  if (e == null) return 0;
  final c = e.tollCount ?? 0;
  return c > 0 ? c : e.tolls.length;
}

class RouteEstimate {
  const RouteEstimate({
    required this.distanceKm,
    required this.durationMin,
    this.summary,
    this.provider,
    this.tollCount,
    this.tollTotal,
    this.tolls = const [],
    this.trend,
  });

  final double distanceKm;
  final double durationMin;
  final String? summary;
  final String? provider;
  final int? tollCount;
  final double? tollTotal;
  final List<TollBooth> tolls;

  /// The arrows before the recommended fare (Admin → Fare AI → Fare trend
  /// arrows), decided by `ai-route-proxy`; null when it decided none.
  final FareTrend? trend;

  /// The tolls to show the rider: the model's total, else the sum of the
  /// booths it listed, else none.
  double? get tollsToShow {
    final total = tollTotal;
    if (total != null && total > 0) return total;
    final sum = tolls.fold<double>(0, (a, t) => a + t.charge);
    return sum > 0 ? sum : null;
  }
}

double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

/// The estimate in a proxy answer, or null (no estimate, a refusal, or a
/// distance/duration that isn't a positive number).
RouteEstimate? parseRouteEstimate(Object? payload) {
  if (payload is! Map || payload['ok'] != true) return null;
  final e = payload['estimate'];
  if (e is! Map) return null;
  final km = _num(e['distance_km']);
  final min = _num(e['duration_min']);
  if (km == null || min == null || km <= 0 || min <= 0) return null;
  final tolls = <TollBooth>[];
  if (e['tolls'] is List) {
    for (final t in e['tolls'] as List) {
      if (t is! Map) continue;
      final charge = _num(t['charge']);
      if (charge == null || charge < 0) continue;
      final name = t['name'];
      double? coord(Object? v) {
        final d = _num(v);
        return d == null || !d.isFinite || d == 0 ? null : d;
      }

      final lat = coord(t['lat']), lng = coord(t['lng']);
      tolls.add(TollBooth(
        name: name is String && name.trim().isNotEmpty ? name.trim() : null,
        charge: charge,
        lat: lat != null && lng != null ? lat : null,
        lng: lat != null && lng != null ? lng : null,
      ));
    }
  }
  final summary = e['summary'];
  final provider = e['provider'];
  final count = _num(e['toll_count']);
  return RouteEstimate(
    distanceKm: km,
    durationMin: min,
    summary: summary is String && summary.trim().isNotEmpty ? summary.trim() : null,
    provider: provider is String ? provider : null,
    tollCount: count?.round(),
    tollTotal: _num(e['toll_total']),
    tolls: tolls,
    trend: parseFareTrend(e['trend']),
  );
}

enum FareTrendDirection { up, down }

/// Why the fare is up or down: the AI's drive time against the standard
/// route's (empty roads), or the AI's own fare-range verdict.
class FareTrend {
  const FareTrend({
    required this.direction,
    required this.fromFareRange,
    this.aiMin,
    this.standardMin,
    this.colorLight,
    this.colorDark,
  });

  final FareTrendDirection direction;

  /// The admin's colours (ARGB) for these arrows in light and dark mode;
  /// null keeps the app's red / green.
  final int? colorLight, colorDark;
  final bool fromFareRange;
  final double? aiMin;
  final double? standardMin;

  /// What the arrows mean, for their tooltip and screen readers.
  String get explanation {
    final up = direction == FareTrendDirection.up;
    final ai = aiMin, std = standardMin;
    if (!fromFareRange && ai != null && std != null) {
      final diff = (ai - std).abs().round();
      if (diff > 0) {
        return up
            ? 'Heavy traffic now: the drive takes about $diff min longer than on clear roads.'
            : 'Light traffic now: the drive takes about $diff min less than usual.';
      }
    }
    return up ? 'Heavier traffic than usual on this route right now.' : 'Lighter traffic than usual on this route right now.';
  }
}

/// The trend in an estimate; null when there is none or it shows no arrows.
FareTrend? parseFareTrend(Object? raw) {
  if (raw is! Map) return null;
  final dir = switch (raw['direction']) {
    'up' => FareTrendDirection.up,
    'down' => FareTrendDirection.down,
    _ => null,
  };
  if (dir == null) return null;
  return FareTrend(
    direction: dir,
    fromFareRange: raw['source'] == 'fare_range',
    aiMin: _num(raw['ai_min']),
    standardMin: _num(raw['standard_min']),
    colorLight: argbFromHex(raw['color_light']),
    colorDark: argbFromHex(raw['color_dark']),
  );
}

/// An opaque ARGB colour from "#RRGGBB" / "RRGGBB" / "#RGB"; null otherwise.
int? argbFromHex(Object? v) {
  if (v is! String) return null;
  var h = v.trim().replaceFirst('#', '');
  if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(h)) h = h.split('').map((c) => '$c$c').join();
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(h)) return null;
  return 0xFF000000 | int.parse(h, radix: 16);
}

/// What the fare is priced on: the AI's traffic-aware distance and time when
/// there is an estimate (as Expo's ride-confirm does), else the map route's.
({double distanceKm, double durationMin}) fareBasis({
  required double routeKm,
  required double routeMin,
  RouteEstimate? ai,
}) => ai == null
    ? (distanceKm: routeKm, durationMin: routeMin)
    : (distanceKm: ai.distanceKm, durationMin: ai.durationMin);

/// Whether a reply from `ai-route-proxy` with no estimate means the AI fare
/// service is on but could not answer (no keys, every key resting or
/// failing), which is when Expo warns "Unable to fetch current traffic
/// conditions". The service switched off, or an estimate, is no warning.
bool aiEstimateUnavailable(Object? payload) {
  if (payload is! Map || payload['ok'] != true) return false;
  if (payload['estimate'] is Map) return false;
  return const {'no_keys', 'keys_cooling_down', 'all_keys_failed'}.contains(payload['reason']);
}

const trafficUnavailableTitle = 'Unable to fetch current traffic conditions';
const trafficUnavailableMessage = 'Actual travel time and distance may vary';
