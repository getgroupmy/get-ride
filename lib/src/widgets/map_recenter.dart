import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Street zoom a recentred map lands on (Expo's recenter animates to 16).
const recenterZoom = 16.0;

/// Moves [map] onto [at] at [zoom] ([recenterZoom] unless given). False
/// when there is nowhere to go yet, or the map is not drawn yet (a
/// controller can't move a map before its first frame).
bool recenterMap(MapController map, LatLng? at, {double zoom = recenterZoom}) {
  if (at == null) return false;
  try {
    return map.move(at, zoom);
  } catch (_) {
    return false;
  }
}

/// The round recenter (my location) button the maps share: a white disc
/// with a black outline arrow on a light map, a charcoal disc with a white
/// one on a dark map.
class RecenterButton extends StatelessWidget {
  const RecenterButton({super.key, required this.onPressed, this.tooltip = 'My location'});

  final VoidCallback? onPressed;
  final String tooltip;

  /// The disc's diameter.
  static const size = 52.0;
  static const lightFill = Colors.white;
  static const darkFill = Color(0xFF262626);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('map-recenter'),
        color: dark ? darkFill : lightFill,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: Colors.black45,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            // An outline arrow pointing up and to the left, as the reference.
            child: Transform.flip(
              flipX: true,
              child: Icon(
                Icons.near_me_outlined,
                key: const ValueKey('map-recenter-icon'),
                size: 28,
                color: onPressed == null ? ink.withValues(alpha: 0.38) : ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
