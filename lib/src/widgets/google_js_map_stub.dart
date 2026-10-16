// Not the web: no Google JavaScript map (see google_js_map.dart).
import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

const googleJsSupported = false;

class GoogleJsMapView extends StatelessWidget {
  const GoogleJsMapView({
    super.key,
    required this.apiKey,
    required this.center,
    required this.zoom,
    this.satellite = false,
    this.dark = false,
    this.traffic = false,
    this.onFailure,
  });

  final String apiKey;
  final LatLng center;
  final double zoom;
  final bool satellite;
  final bool dark;
  final bool traffic;
  final VoidCallback? onFailure;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
