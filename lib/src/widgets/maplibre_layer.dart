// A MapLibre map (Amazon Location's, Admin → Settings → Maps, migration
// 0206, web only) as a FlutterMap's base layer: it follows the map's camera
// and gives way to [fallback] tiles if MapLibre can't load or the key is
// refused.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'maplibre_map.dart';

/// Set once MapLibre failed on this page; every map then uses its
/// [MapLibreBaseLayer.fallback] (and its credit).
final maplibreFailed = ValueNotifier<bool>(!maplibreSupported);

class MapLibreBaseLayer extends StatelessWidget {
  const MapLibreBaseLayer({super.key, required this.style, required this.apiKey, required this.fallback});

  final String style;
  final String apiKey;

  /// The tiles to draw instead when the map can't be shown.
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: maplibreFailed,
      builder: (context, failed, _) {
        if (failed) return fallback;
        final camera = MapCamera.of(context);
        return IgnorePointer(
          child: SizedBox.fromSize(
            size: camera.nonRotatedSize,
            child: MapLibreMapView(
              style: style,
              apiKey: apiKey,
              center: camera.center,
              zoom: camera.zoom,
              size: camera.nonRotatedSize,
              onFailure: () => maplibreFailed.value = true,
            ),
          ),
        );
      },
    );
  }
}
