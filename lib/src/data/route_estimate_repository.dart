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

  Future<RouteEstimate?> estimate(LatLng from, LatLng to) async {
    try {
      final res = await _db.functions.invoke(
        'ai-route-proxy',
        body: {
          'origin': {'latitude': from.latitude, 'longitude': from.longitude},
          'destination': {'latitude': to.latitude, 'longitude': to.longitude},
        },
      );
      return parseRouteEstimate(res.data);
    } catch (_) {
      return null;
    }
  }
}

final routeEstimateRepositoryProvider = Provider((ref) => RouteEstimateRepository(ref.watch(supabaseProvider)));
