import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/route_estimate.dart';
import '../providers.dart';

/// Asks `ai-route-proxy` for a traffic-aware estimate. Any failure (function
/// not deployed, AI switched off, no keys, offline) is no estimate: the map
/// route still prices the ride. Unlike Expo there is no client-side
/// fallback, so provider keys never reach this app.
class RouteEstimateRepository {
  RouteEstimateRepository(this._db);
  final SupabaseClient _db;

  Future<RouteEstimate?> estimate(LatLng from, LatLng to) async => (await estimateDetailed(from, to))?.estimate;

  /// The estimate and whether the AI service is on but could not give one
  /// ([aiEstimateUnavailable]); null when the function could not be reached.
  /// [via] are the trip's stops in order: the AI prices the whole trip
  /// through them (see [estimateCoversStops]).
  Future<({RouteEstimate? estimate, bool unavailable})?> estimateDetailed(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
  }) async {
    Map<String, double> point(LatLng p) => {'latitude': p.latitude, 'longitude': p.longitude};
    try {
      final res = await _db.functions.invoke(
        'ai-route-proxy',
        body: {
          'origin': point(from),
          'destination': point(to),
          if (via.isNotEmpty) 'waypoints': [for (final p in via) point(p)],
        },
      );
      return (estimate: parseRouteEstimate(res.data), unavailable: aiEstimateUnavailable(res.data));
    } catch (_) {
      return null;
    }
  }
}

final routeEstimateRepositoryProvider = Provider((ref) => RouteEstimateRepository(ref.watch(supabaseProvider)));
