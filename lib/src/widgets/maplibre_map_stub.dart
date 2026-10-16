// Not the web: no MapLibre map (see maplibre_map.dart).
import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

const maplibreSupported = false;

class MapLibreMapView extends StatelessWidget {
  const MapLibreMapView({
    super.key,
    required this.style,
    required this.apiKey,
    required this.center,
    required this.zoom,
    required this.size,
    this.onFailure,
  });

  final String style;
  final String apiKey;
  final LatLng center;
  final double zoom;
  final Size size;
  final VoidCallback? onFailure;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
