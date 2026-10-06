import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'map_tiles.dart';

/// OpenStreetMap view used on every platform (web, desktop, iOS, Android).
class RideMap extends StatefulWidget {
  const RideMap({
    super.key,
    this.pickup,
    this.drop,
    this.stops = const [],
    this.driver,
    this.me,
    this.route = const [],
    this.onTap,
    this.controller,
  });

  final LatLng? pickup;
  final LatLng? drop;

  /// Stops on the way, in order (numbered pins).
  final List<LatLng> stops;
  final LatLng? driver;
  final LatLng? me;
  final List<LatLng> route;
  final void Function(LatLng)? onTap;
  final MapController? controller;

  @override
  State<RideMap> createState() => _RideMapState();
}

class _RideMapState extends State<RideMap> {
  late final MapController _controller = widget.controller ?? MapController();
  bool _ready = false;

  List<LatLng> get _points =>
      [widget.pickup, ...widget.stops, widget.drop, widget.driver, widget.me].whereType<LatLng>().toList();

  @override
  void didUpdateWidget(covariant RideMap old) {
    super.didUpdateWidget(old);
    if (_ready &&
        (old.pickup != widget.pickup ||
            old.drop != widget.drop ||
            old.stops.length != widget.stops.length ||
            old.route.length != widget.route.length)) {
      _fit();
    }
  }

  void _fit() {
    final pts = [..._points, ...widget.route];
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _controller.move(pts.first, 15);
      return;
    }
    _controller.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(64), maxZoom: 16));
  }

  @override
  Widget build(BuildContext context) {
    final center = _points.isNotEmpty ? _points.first : defaultCenter;
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: 14,
        onTap: widget.onTap == null ? null : (_, p) => widget.onTap!(p),
        onMapReady: () {
          _ready = true;
          _fit();
        },
      ),
      children: [
        baseTileLayer(context),
        if (widget.route.length > 1)
          PolylineLayer(polylines: [
            Polyline(points: widget.route, strokeWidth: 5, color: const Color(0xFF2DABE2)),
          ]),
        MarkerLayer(markers: [
          if (widget.me != null)
            Marker(
              point: widget.me!,
              width: 22,
              height: 22,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                ),
              ),
            ),
          if (widget.pickup != null) _pin(widget.pickup!, Colors.green.shade700, Icons.trip_origin),
          for (var i = 0; i < widget.stops.length; i++)
            Marker(
              point: widget.stops[i],
              width: 26,
              height: 26,
              child: CircleAvatar(
                backgroundColor: Colors.orange.shade800,
                child: Text('${i + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          if (widget.drop != null) _pin(widget.drop!, Colors.red.shade700, Icons.location_on),
          if (widget.driver != null)
            Marker(
              point: widget.driver!,
              width: 40,
              height: 40,
              child: const CircleAvatar(
                backgroundColor: Colors.black,
                child: Icon(Icons.local_taxi, color: Color(0xFFFFD400), size: 22),
              ),
            ),
        ]),
        const RichAttributionWidget(
          attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
        ),
      ],
    );
  }

  Marker _pin(LatLng p, Color c, IconData icon) => Marker(
        point: p,
        width: 40,
        height: 40,
        alignment: Alignment.topCenter,
        child: Icon(icon, color: c, size: 36, shadows: const [Shadow(blurRadius: 4, color: Colors.black38)]),
      );
}
