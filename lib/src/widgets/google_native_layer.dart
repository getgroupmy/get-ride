// Google's own map in the phone app (Admin → Settings → Maps, migration
// 0210, Android and iOS) as a FlutterMap's base layer: the Maps SDK draws
// it under the app's own layers and follows the app's camera; the app's map
// takes every gesture. Built only into a release that carries a Maps SDK
// key (GOOGLE_MAPS_NATIVE); otherwise, or should it fail, [fallback] tiles.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

import 'google_map_style.dart';
import 'map_brightness.dart';
import 'map_traffic.dart' show googleTrafficProvider, mapTrafficProvider;

/// Whether this build can draw Google's own map: Android or iOS, with the
/// Maps SDK key the release workflow put in (it sets GOOGLE_MAPS_NATIVE).
bool get googleNativeSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS) && const String.fromEnvironment('GOOGLE_MAPS_NATIVE') == 'true';

class GoogleNativeBaseLayer extends ConsumerStatefulWidget {
  const GoogleNativeBaseLayer({super.key, required this.fallback, this.satellite = false, this.mapType});

  final bool satellite;

  /// "roadmap", "satellite", "hybrid" or "terrain" (Admin → Maps, migration
  /// 0211); null for the roadmap, or satellite when [satellite].
  final String? mapType;

  String get type => mapType ?? (satellite ? 'satellite' : 'roadmap');

  /// The tiles to draw instead when this build has no Google map.
  final Widget fallback;

  @override
  ConsumerState<GoogleNativeBaseLayer> createState() => _GoogleNativeBaseLayerState();
}

class _GoogleNativeBaseLayerState extends ConsumerState<GoogleNativeBaseLayer> {
  gm.GoogleMapController? _map;
  MapCamera? _shown;

  gm.CameraPosition _position(MapCamera c) => gm.CameraPosition(
    target: gm.LatLng(c.center.latitude, c.center.longitude),
    zoom: c.zoom,
    // flutter_map turns the map clockwise by its rotation; Google faces
    // the bearing, turning the map the other way.
    bearing: -c.rotation,
  );

  /// The app's camera, moved to at once (no animation: the layers on top
  /// are already there).
  void _follow(MapCamera c) {
    final map = _map;
    if (map == null || _shown == c) return;
    _shown = c;
    unawaited(map.moveCamera(gm.CameraUpdate.newCameraPosition(_position(c))).catchError((_) {}));
  }

  @override
  void dispose() {
    _map?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!googleNativeSupported) return widget.fallback;
    final camera = MapCamera.of(context);
    final traffic = ref.watch(googleTrafficProvider) && ref.watch(mapTrafficProvider);
    final dark = mapIsDark(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _follow(camera);
    });
    return IgnorePointer(
      child: SizedBox.fromSize(
        size: camera.nonRotatedSize,
        child: gm.GoogleMap(
          initialCameraPosition: _position(camera),
          onMapCreated: (c) {
            _map = c;
            _shown = null;
            _follow(MapCamera.of(context));
          },
          mapType: switch (widget.type) {
            'satellite' => gm.MapType.satellite,
            'hybrid' => gm.MapType.hybrid,
            'terrain' => gm.MapType.terrain,
            _ => gm.MapType.normal,
          },
          style: dark && widget.type == 'roadmap' ? googleNightStyleJson : null,
          trafficEnabled: traffic,
          // Only shows: the app's own map and buttons do the rest.
          zoomControlsEnabled: false,
          zoomGesturesEnabled: false,
          scrollGesturesEnabled: false,
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          myLocationButtonEnabled: false,
          compassEnabled: false,
          mapToolbarEnabled: false,
          indoorViewEnabled: false,
          buildingsEnabled: true,
        ),
      ),
    );
  }
}
