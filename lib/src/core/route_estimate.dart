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
