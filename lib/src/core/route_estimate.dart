/// Traffic-aware route estimate from the `ai-route-proxy` edge function
/// (Expo `utils/geminiRoute.ts` → `estimateViaProxy`). The function runs the
/// admin's fare-AI provider with keys that never reach the app, and answers
/// `{ ok, estimate: { distance_km, duration_min, summary, provider,
/// toll_count, toll_total, tolls } | null, reason }`.
library;

/// One toll plaza on the route.
class TollBooth {
  const TollBooth({this.name, required this.charge});
  final String? name;
  final double charge;
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
  });

  final double distanceKm;
  final double durationMin;
  final String? summary;
  final String? provider;
  final int? tollCount;
  final double? tollTotal;
  final List<TollBooth> tolls;

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
      tolls.add(TollBooth(name: name is String && name.trim().isNotEmpty ? name.trim() : null, charge: charge));
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
  );
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
