// Google's JavaScript map as a FlutterMap's base layer (Admin → Settings →
// Maps, migration 0204, web only): it follows the map's camera, shows
// Google's traffic while the traffic button is on (when the admin chose
// Google traffic), and gives way to [fallback] tiles if Google refuses the
// key or the API can't load.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'google_js_map.dart';
import 'map_traffic.dart' show googleTrafficProvider, mapTrafficProvider;

/// Set once Google refused the key or the API failed to load on this page;
/// every map then uses its [GoogleJsBaseLayer.fallback] (and its credit).
final googleJsFailed = ValueNotifier<bool>(!googleJsSupported);

class GoogleJsBaseLayer extends ConsumerWidget {
  const GoogleJsBaseLayer({
    super.key,
    required this.apiKey,
    required this.fallback,
    this.satellite = false,
    this.mapType,
  });

  final String apiKey;
  final bool satellite;

  /// "hybrid", "terrain" … (migration 0211); null for [satellite]'s.
  final String? mapType;

  /// The tiles to draw instead when Google's map can't be shown.
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traffic = ref.watch(googleTrafficProvider) && ref.watch(mapTrafficProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<bool>(
      valueListenable: googleJsFailed,
      builder: (context, failed, _) {
        if (failed) return fallback;
        final camera = MapCamera.of(context);
        return IgnorePointer(
          child: SizedBox.fromSize(
            size: camera.nonRotatedSize,
            child: GoogleJsMapView(
              apiKey: apiKey,
              center: camera.center,
              zoom: camera.zoom,
              satellite: satellite,
              mapType: mapType,
              dark: dark,
              traffic: traffic,
              onFailure: () => googleJsFailed.value = true,
            ),
          ),
        );
      },
    );
  }
}
