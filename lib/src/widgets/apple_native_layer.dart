// Apple's own map in the iPhone app (Admin → Settings → Maps, migration
// 0214) as a FlutterMap's base layer: MapKit draws it under the app's own
// layers and follows the app's camera; the app's map takes every gesture.
// Built into the phone, so no key. It is also the iPhone's fallback when the
// map set for it can't draw (see map_tiles.dart).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as am;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Whether this device can draw Apple's map: iPhone and iPad.
bool get appleNativeSupported => !kIsWeb && Platform.isIOS;

class AppleNativeBaseLayer extends StatefulWidget {
  const AppleNativeBaseLayer({super.key, required this.fallback, this.satellite = false, this.mapType});

  final bool satellite;

  /// "roadmap", "satellite" or "hybrid"; null for the roadmap, or satellite
  /// when [satellite]. Apple has no terrain map: its standard one instead.
  final String? mapType;

  String get type => mapType ?? (satellite ? 'satellite' : 'roadmap');

  /// The tiles to draw instead where there is no Apple map.
  final Widget fallback;

  @override
  State<AppleNativeBaseLayer> createState() => _AppleNativeBaseLayerState();
}

class _AppleNativeBaseLayerState extends State<AppleNativeBaseLayer> {
  am.AppleMapController? _map;
  MapCamera? _shown;

  am.CameraPosition _position(MapCamera c) => am.CameraPosition(
    target: am.LatLng(c.center.latitude, c.center.longitude),
    zoom: c.zoom,
    // flutter_map turns the map clockwise by its rotation; Apple faces the
    // heading, turning the map the other way.
    heading: -c.rotation,
  );

  /// The app's camera, moved to at once (no animation: the layers on top
  /// are already there).
  ///
  /// The plugin turns a zoom into a camera height by a rule of thumb, which
  /// leaves Apple's roads a little bigger or smaller than the app's route
  /// and pins on top, more so away from the centre. Unturned, the map is
  /// given the exact area the app shows instead; turned (heading up on a
  /// trip), the zoom is all there is.
  void _follow(MapCamera c) {
    final map = _map;
    if (map == null || _shown == c) return;
    final turned = (_shown?.rotation ?? 0) != 0;
    _shown = c;
    if (c.rotation != 0 || turned) {
      unawaited(map.moveCamera(am.CameraUpdate.newCameraPosition(_position(c))).catchError((_) {}));
    }
    if (c.rotation == 0) {
      final b = c.visibleBounds;
      unawaited(map
          .moveCamera(am.CameraUpdate.newLatLngBounds(
            am.LatLngBounds(
              southwest: am.LatLng(b.south, b.west),
              northeast: am.LatLng(b.north, b.east),
            ),
            0,
          ))
          .catchError((_) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!appleNativeSupported) return widget.fallback;
    final camera = MapCamera.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _follow(camera);
    });
    return IgnorePointer(
      child: SizedBox.fromSize(
        size: camera.nonRotatedSize,
        child: am.AppleMap(
          initialCameraPosition: _position(camera),
          onMapCreated: (c) {
            _map = c;
            _shown = null;
            _follow(MapCamera.of(context));
          },
          mapType: switch (widget.type) {
            'satellite' => am.MapType.satellite,
            'hybrid' => am.MapType.hybrid,
            _ => am.MapType.standard,
          },
          // The app's own traffic layer draws over it, as over any map.
          trafficEnabled: false,
          // Only shows: the app's own map and buttons do the rest.
          compassEnabled: false,
          rotateGesturesEnabled: false,
          scrollGesturesEnabled: false,
          zoomGesturesEnabled: false,
          pitchGesturesEnabled: false,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
        ),
      ),
    );
  }
}
