import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Street zoom a recentred map lands on (Expo's recenter animates to 16).
const recenterZoom = 16.0;

/// Moves [map] onto [at] at [recenterZoom]. False when there is nowhere to
/// go yet, or the map is not drawn yet (a controller can't move a map
/// before its first frame).
bool recenterMap(MapController map, LatLng? at) {
  if (at == null) return false;
  try {
    return map.move(at, recenterZoom);
  } catch (_) {
    return false;
  }
}

/// The round recenter (my location) button the maps share.
class RecenterButton extends StatelessWidget {
  const RecenterButton({super.key, required this.onPressed, this.tooltip = 'My location'});

  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => FloatingActionButton.small(
    key: const ValueKey('map-recenter'),
    heroTag: null,
    tooltip: tooltip,
    onPressed: onPressed,
    child: const Icon(Icons.my_location),
  );
}
