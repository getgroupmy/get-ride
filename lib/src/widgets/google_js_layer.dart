// Google's JavaScript map as a FlutterMap's base layer (Admin → Settings →
// Maps, migration 0204): drawn by the browser on the web and in a web view
// on Android, Windows and macOS (google_js_map_io.dart). It follows the map's
// camera, shows Google's traffic while the traffic button is on (when the
// admin chose Google traffic), and gives way to [fallback] tiles if Google
// refuses the key or the API can't load.
//
// The page itself is always drawn north up: this kind of Google map cannot be
// turned. So when the app's map is turned — the driver's, to the way the car
// is going — the page is turned with the app's own layers, as its tiles would
// be ([turningMapSize]). Left as it was, Google's roads stayed north up under
// a route, pins and a car that had all turned.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'google_js_map.dart';
import 'map_brightness.dart';
import 'map_traffic.dart' show googleTrafficProvider, mapTrafficProvider;

/// Set once Google refused the key or the API failed to load on this page;
/// every map then uses its [GoogleJsBaseLayer.fallback] (and its credit).
final googleJsFailed = ValueNotifier<bool>(!googleJsSupported);

/// The size to draw a north-up page at so that it covers a map of [map]'s size
/// whichever way the map is turned: a square as wide as the map's diagonal,
/// centred on it. One size for every angle, so the page is laid out once and
/// not again with every degree of a bend.
Size turningMapSize(Size map) {
  if (map.isEmpty || !map.isFinite) return map;
  return Size.square(math.sqrt(map.width * map.width + map.height * map.height).ceilToDouble());
}

class GoogleJsBaseLayer extends ConsumerStatefulWidget {
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
  ConsumerState<GoogleJsBaseLayer> createState() => _GoogleJsBaseLayerState();
}

class _GoogleJsBaseLayerState extends ConsumerState<GoogleJsBaseLayer> {
  /// Whether the map has been turned since it opened. From then on the page
  /// is kept big enough to cover it at any angle ([turningMapSize]), turned or
  /// not: a map that has turned once will again, and a page that changed size
  /// each time would be laid out afresh each time.
  bool _turned = false;

  @override
  Widget build(BuildContext context) {
    final traffic = ref.watch(googleTrafficProvider) && ref.watch(mapTrafficProvider);
    final dark = mapIsDark(context);
    return ValueListenableBuilder<bool>(
      valueListenable: googleJsFailed,
      builder: (context, failed, _) {
        if (failed) return widget.fallback;
        final camera = MapCamera.of(context);
        if (camera.rotation != 0) _turned = true;
        final size = _turned ? turningMapSize(camera.nonRotatedSize) : camera.nonRotatedSize;
        return IgnorePointer(
          // Centred on the map, over its edges where it is the bigger: the
          // map clips what hangs over.
          child: OverflowBox(
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            // Turned as the app's own layers are (flutter_map's
            // MobileLayerTransformer): about the middle of the map.
            child: Transform.rotate(
              angle: camera.rotationRad,
              child: GoogleJsMapView(
                apiKey: widget.apiKey,
                center: camera.center,
                zoom: camera.zoom,
                size: size,
                satellite: widget.satellite,
                mapType: widget.mapType,
                dark: dark,
                traffic: traffic,
                onFailure: () => googleJsFailed.value = true,
              ),
            ),
          ),
        );
      },
    );
  }
}
