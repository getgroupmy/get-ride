// Live traffic on the driver's map: a transparent tile overlay drawn over the
// street (or satellite) tiles, switched on and off per device.
//
// OpenStreetMap has no traffic data, and every live-traffic tile service
// needs a key (TomTom, HERE, …), so the overlay is off — and its button
// hidden — until the build names one with --dart-define, the same way the
// base tiles are pointed at a keyed provider (lib/src/widgets/map_tiles.dart):
//
//   MAP_TILE_URL_TRAFFIC  an XYZ raster template with {z}/{x}/{y} and its key
//                         in the query string, e.g. TomTom's flow tiles:
//                         https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=…
//
//   MAP_TILE_URL_TRAFFIC_FALLBACK  optional second source (e.g. HERE's flow
//                         tiles) fetched for any tile the first one fails
//                         to load: a provider outage or an exhausted quota
//                         degrades tile by tile instead of blanking traffic.
//
// The URLs are never logged or shown: they carry the keys.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'map_tiles.dart' show appTileProvider;

const _configuredTraffic = String.fromEnvironment('MAP_TILE_URL_TRAFFIC');
const _configuredTrafficFallback = String.fromEnvironment('MAP_TILE_URL_TRAFFIC_FALLBACK');

/// The traffic tile template to use, or null when none is configured (or
/// what is configured is not an https XYZ template).
String? resolveTrafficTileUrl({String configured = _configuredTraffic}) {
  final url = configured.trim();
  if (url.isEmpty || !url.startsWith('https://')) return null;
  if (!url.contains('{z}') || !url.contains('{x}') || !url.contains('{y}')) return null;
  return url;
}

/// The configured traffic tile source (overridden in tests); null hides the
/// traffic button.
final trafficTileUrlProvider = Provider<String?>((_) => resolveTrafficTileUrl());

/// The backup traffic source, validated the same way; null when there is
/// none, or when it is the same as the primary (nothing to fall back to).
String? resolveTrafficFallbackUrl({
  String configured = _configuredTrafficFallback,
  String? primary,
}) {
  final url = resolveTrafficTileUrl(configured: configured);
  return url == primary ? null : url;
}

final trafficFallbackTileUrlProvider = Provider<String?>(
  (ref) => resolveTrafficFallbackUrl(primary: ref.watch(trafficTileUrlProvider)),
);

/// Whether the driver has traffic switched on, persisted per device.
class MapTraffic extends Notifier<bool> {
  static const prefsKey = 'map_traffic';

  @override
  bool build() {
    SharedPreferences.getInstance().then((p) {
      final v = p.getBool(prefsKey);
      if (v != null) state = v;
    }).ignore();
    return false;
  }

  Future<void> set(bool on) async {
    state = on;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefsKey, on);
    } catch (_) {
      // Not remembered on this device; the switch still works for now.
    }
  }

  Future<void> toggle() => set(!state);
}

final mapTrafficProvider = NotifierProvider<MapTraffic, bool>(MapTraffic.new);

/// The traffic layer to draw over the base tiles, when traffic is configured
/// and switched on; null otherwise.
///
/// With a [fallback], a tile the primary source fails to load is fetched
/// from the fallback instead (flutter_map's per-tile `fallbackUrl`).
TileLayer? trafficTileLayer(String? url, {required bool on, String? fallback}) {
  if (url == null || !on) return null;
  return TileLayer(
    key: const ValueKey('traffic-tiles'),
    urlTemplate: url,
    fallbackUrl: fallback,
    subdomains: url.contains('{s}') ? const ['a', 'b', 'c', 'd'] : const [],
    userAgentPackageName: 'com.taxxee.teksi',
    tileProvider: appTileProvider,
    // Coordinates only: the URL carries the provider's key.
    errorTileCallback: (tile, _, _) => debugPrint('Traffic tile ${tile.coordinates} failed'),
    panBuffer: kIsWeb ? 0 : 1,
    evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
  );
}

/// The round traffic button above the map-type button: highlighted while on.
/// Draws nothing when no traffic source is configured.
class TrafficButton extends ConsumerWidget {
  const TrafficButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(trafficTileUrlProvider) == null) return const SizedBox.shrink();
    final on = ref.watch(mapTrafficProvider);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: on,
        child: FloatingActionButton.small(
          key: const ValueKey('map-traffic'),
          heroTag: null,
          tooltip: on ? 'Hide traffic' : 'Show traffic',
          backgroundColor: on ? scheme.primary : null,
          foregroundColor: on ? scheme.onPrimary : null,
          onPressed: ref.read(mapTrafficProvider.notifier).toggle,
          child: const Icon(Icons.traffic_outlined),
        ),
      ),
    );
  }
}
