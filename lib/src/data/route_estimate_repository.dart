import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/fare_timing.dart';
import '../core/route_estimate.dart';
import '../providers.dart';
import 'function_region.dart';
import 'route_eta.dart';

/// Apple Maps on the phone for a trip through these points, within a time;
/// null when it has no answer (see [appleRouteThrough]).
typedef DeviceAppleRoute = Future<({double km, double minutes})?> Function(List<LatLng> points, Duration within);

/// Asks `ai-route-proxy` for a traffic-aware estimate. Any failure (function
/// not deployed, AI switched off, no keys, offline) is no estimate: the map
/// route still prices the ride. Unlike Expo there is no client-side
/// fallback, so provider keys never reach this app.
///
/// On an iPhone with [FareTiming.deviceApple] on, Apple Maps' place in the
/// fare order is taken by the phone itself (`_shared/fare_timing.ts`): the
/// proxy answers `device_apple` when the order gets there, the phone asks
/// Apple Maps (MapKit), reports the answer for the response log, and if
/// Apple Maps has none asks the proxy to go on with the `remaining` steps.
class RouteEstimateRepository {
  RouteEstimateRepository(this._db, {DeviceAppleRoute? deviceApple, bool? onIphone})
      : _deviceApple = deviceApple ?? appleRouteThrough,
        _onIphone = onIphone ?? canAskAppleMapsOnDevice;
  final SupabaseClient _db;
  final DeviceAppleRoute _deviceApple;
  final bool _onIphone;

  Future<RouteEstimate?> estimate(LatLng from, LatLng to) async => (await estimateDetailed(from, to))?.estimate;

  /// The estimate and whether the AI service is on but could not give one
  /// ([aiEstimateUnavailable]); null when the function could not be reached.
  /// [via] are the trip's stops in order: the AI prices the whole trip
  /// through them (see [estimateCoversStops]). [timing] says whether and
  /// how long an iPhone asks Apple Maps itself.
  Future<({RouteEstimate? estimate, bool unavailable})?> estimateDetailed(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
    FareTiming timing = FareTiming.defaults,
  }) async {
    Map<String, double> point(LatLng p) => {'latitude': p.latitude, 'longitude': p.longitude};
    final trip = <String, dynamic>{
      'origin': point(from),
      'destination': point(to),
      if (via.isNotEmpty) 'waypoints': [for (final p in via) point(p)],
    };
    final onDevice = _onIphone && timing.deviceApple;
    try {
      final res = await _db.functions.invokeNearDb(
        'ai-route-proxy',
        body: {...trip, if (onDevice) 'device': 'ios_mapkit'},
      );
      final data = res.data;
      if (!onDevice || data is! Map || data['reason'] != 'device_apple') {
        return (estimate: parseRouteEstimate(data), unavailable: aiEstimateUnavailable(data));
      }
      // The order reached Apple Maps: ask it on the phone.
      final started = DateTime.now();
      final apple = await _deviceApple([from, ...via, to], timing.deviceAppleWait);
      final latencyMs = DateTime.now().difference(started).inMilliseconds;
      // The response log: fire and forget, it never holds up the fare.
      _db.functions
          .invokeNearDb('ai-route-proxy', body: {
            ...trip,
            'report': apple == null
                ? {'success': false, 'latency_ms': latencyMs, 'error': 'No answer from Apple Maps on the phone'}
                : {'success': true, 'distance_km': apple.km, 'duration_min': apple.minutes, 'latency_ms': latencyMs},
          })
          .then((_) {}, onError: (_) {});
      if (apple != null) {
        return (estimate: deviceAppleEstimate(apple.km, apple.minutes, via.length), unavailable: false);
      }
      final remaining = data['remaining'];
      if (remaining is! List || remaining.isEmpty) return (estimate: null, unavailable: false);
      final again = await _db.functions.invokeNearDb('ai-route-proxy', body: {...trip, 'resume': remaining});
      return (estimate: parseRouteEstimate(again.data), unavailable: aiEstimateUnavailable(again.data));
    } catch (_) {
      return null;
    }
  }
}

/// Apple Maps' answer on the phone as an estimate (provider `apple_device`,
/// shown as "Apple Maps"). No tolls: MapKit doesn't price them.
RouteEstimate deviceAppleEstimate(double km, double minutes, int stops) => RouteEstimate(
      distanceKm: (km * 10).round() / 10,
      durationMin: minutes.ceilToDouble(),
      summary: 'Apple Maps on the iPhone',
      provider: 'apple_device',
      stops: stops,
    );

final routeEstimateRepositoryProvider = Provider((ref) => RouteEstimateRepository(ref.watch(supabaseProvider)));

/// The apps' fare time limits (`fare_timing`, readable by every app; Admin ›
/// Fare AI provider › Time limits). The defaults when it can't be read.
final fareTimingProvider = FutureProvider<FareTiming>((ref) async {
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from('app_settings')
        .select('value')
        .eq('key', fareTimingSettingKey)
        .maybeSingle();
    return FareTiming.fromJson(app: row?['value']);
  } catch (_) {
    return FareTiming.defaults;
  }
});
