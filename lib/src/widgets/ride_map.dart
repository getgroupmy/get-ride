import 'dart:math' as math;

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
    this.driverHeading,
    this.me,
    this.route = const [],
    this.onTap,
    this.controller,
    this.extraMarkers = const [],
    this.framed = const [],
  });

  final LatLng? pickup;
  final LatLng? drop;

  /// Stops on the way, in order (numbered pins).
  final List<LatLng> stops;
  final LatLng? driver;

  /// Compass heading of the driver's car in degrees (0 = north), turning
  /// the car marker to face where it is going.
  final double? driverHeading;
  final LatLng? me;
  final List<LatLng> route;
  final void Function(LatLng)? onTap;
  final MapController? controller;

  /// Further marks drawn above the route (toll booths and the like).
  final List<Marker> extraMarkers;

  /// Further points the camera keeps in frame (the driver home map's
  /// request pickups).
  final List<LatLng> framed;

  @override
  State<RideMap> createState() => _RideMapState();
}

class _RideMapState extends State<RideMap> {
  late final MapController _controller = widget.controller ?? MapController();
  bool _ready = false;

  List<LatLng> get _points =>
      [widget.pickup, ...widget.stops, widget.drop, widget.driver, widget.me, ...widget.framed].whereType<LatLng>().toList();

  @override
  void didUpdateWidget(covariant RideMap old) {
    super.didUpdateWidget(old);
    if (_ready &&
        (old.pickup != widget.pickup ||
            old.drop != widget.drop ||
            old.stops.length != widget.stops.length ||
            old.route.length != widget.route.length ||
            old.framed.length != widget.framed.length ||
            // The first fix: a map opened before it was centred on nothing.
            (old.me == null && widget.me != null))) {
      _fit();
    }
  }

  /// The camera that shows every point, or null for none or one.
  CameraFit? get _cameraFit {
    final pts = [..._points, ...widget.route];
    if (pts.length < 2) return null;
    return CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(64), maxZoom: 16);
  }

  void _fit() {
    final pts = [..._points, ...widget.route];
    if (pts.isEmpty) return;
    final fit = _cameraFit;
    if (fit == null) {
      _controller.move(pts.first, 15);
      return;
    }
    _controller.fitCamera(fit);
  }

  @override
  Widget build(BuildContext context) {
    final center = _points.isNotEmpty ? _points.first : defaultCenter;
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: _points.length == 1 ? 15 : 14,
        // Open already framing the trip. Starting zoomed in on the pickup and
        // fitting a frame later requested a screenful of close-up tiles that
        // were thrown away at once, and on a long trip those queued requests
        // held up (or used up the server's allowance for) the tiles shown.
        initialCameraFit: _cameraFit,
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
        if (widget.extraMarkers.isNotEmpty) MarkerLayer(markers: widget.extraMarkers),
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
              child: CircleAvatar(
                backgroundColor: Colors.black,
                child: widget.driverHeading == null
                    ? const Icon(Icons.local_taxi, color: Color(0xFFFFD400), size: 22)
                    : Transform.rotate(
                        key: const ValueKey('driver-heading'),
                        angle: widget.driverHeading! * math.pi / 180,
                        child: const Icon(Icons.navigation, color: Color(0xFFFFD400), size: 22),
                      ),
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
