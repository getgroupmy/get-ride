import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'map_sheet_layout.dart';
import 'map_tiles.dart';

/// Where a map of [points] (and [route]) opens, laid out at [size]: framing
/// them all when there are two or more, else on the one point (or
/// [defaultCenter]). Pure.
/// [bottom] is how much of the map a sheet over it covers.
/// [pointZoom] is the zoom a lone point opens at.
({LatLng center, double zoom}) openingView(
  List<LatLng> points,
  List<LatLng> route,
  Size size, {
  double bottom = 0,
  double pointZoom = 15,
}) {
  final all = [...points, ...route];
  final first = points.isNotEmpty ? points.first : (all.isNotEmpty ? all.first : defaultCenter);
  if (all.length < 2 || !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0) {
    return (center: first, zoom: points.length == 1 ? pointZoom : 14);
  }
  final fitted = CameraFit.coordinates(
    coordinates: all,
    padding: EdgeInsets.fromLTRB(64, 64, 64, 64 + bottom),
    maxZoom: 16,
  ).fit(MapCamera(crs: const Epsg3857(), center: first, zoom: 14, rotation: 0, nonRotatedSize: size));
  return (center: fitted.center, zoom: fitted.zoom);
}

/// How far up from the map's bottom edge a control in the bottom-right
/// corner starts, so it clears the OpenStreetMap credit button flutter_map
/// draws there (its tap target is 48 px, which OSM's terms need reachable).
const mapAttributionClearance = 56.0;

/// Height of the box a pickup/drop-off pin is drawn in, standing on its point.
const rideMapPinBox = 40.0;

/// Size of the pin icon, centred in [rideMapPinBox].
const rideMapPinIcon = 36.0;

/// The pickup pin: a white rounded square with a person hailing, on a thin
/// stem whose foot is the point (as Expo's / inDrive's).
const pickupPinHead = 40.0;
const pickupPinStem = 14.0;
const pickupPinHeight = pickupPinHead + pickupPinStem;

/// How far above its point the pickup pin's visible top is (the label over
/// it is spaced from there).
const rideMapPinTop = pickupPinHeight;

/// The pickup pin, [pickupPinHeight] tall, standing on its point.
class PickupPin extends StatelessWidget {
  const PickupPin({super.key, this.elevation = 0});

  /// 0 standing, 1 lifted (a deeper shadow while it floats).
  final double elevation;

  @override
  Widget build(BuildContext context) {
    // Light maps get a black head with a white figure; dark maps the reverse.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? Colors.white : Colors.black;
    final ink = dark ? Colors.black : Colors.white;
    return SizedBox(
      width: pickupPinHead,
      height: pickupPinHeight,
      child: Column(
        children: [
          Container(
            key: const ValueKey('pickup-pin'),
            width: pickupPinHead,
            height: pickupPinHead,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: ink, width: 2),
              boxShadow: [
                BoxShadow(blurRadius: 4 + 6 * elevation, offset: Offset(0, 2 + 4 * elevation), color: Colors.black38),
              ],
            ),
            child: Icon(Icons.emoji_people, size: 26, color: ink),
          ),
          Container(
            key: const ValueKey('pickup-pin-stem'),
            width: 2,
            height: pickupPinStem,
            decoration: BoxDecoration(
              color: fill,
              boxShadow: const [BoxShadow(blurRadius: 2, color: Colors.black38)],
            ),
          ),
        ],
      ),
    );
  }
}

/// A label drawn [gap] px above the pickup pin at [point], moving with the
/// map (the pickup box, in place of one fixed to the top of the screen).
/// [width] and [height] bound the label; space it doesn't use takes no taps.
Marker labelAbovePin(LatLng point, Widget label, {double gap = 5, double width = 300, double height = 72}) {
  final lift = rideMapPinTop + gap;
  return Marker(
    point: point,
    width: width,
    height: height + lift,
    alignment: Alignment.topCenter,
    child: Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: lift),
        child: label,
      ),
    ),
  );
}

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
    this.satellite = false,
    this.autoFit = true,
    this.onGesture,
    this.onReady,
    this.pointZoom = 15,
    this.showPickup = true,
    this.dotPins = false,
    this.extraLayers = const [],
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

  /// Satellite imagery instead of the street map ([MapTypeButton]).
  final bool satellite;

  /// Whether the map frames its points again as they change. Off while
  /// something else steers the camera (a map following the car).
  final bool autoFit;

  /// The user panned, zoomed or turned the map by hand.
  final VoidCallback? onGesture;

  /// The map is drawn and its controller can move it.
  final VoidCallback? onReady;

  /// The zoom a map showing one point (the user alone) opens at.
  final double pointZoom;

  /// Whether the pickup pin is drawn; off while a [MapDragPin] holds it
  /// up off the map. The camera still counts it either way.
  final bool showPickup;

  /// The confirm screen's look (Expo `ride-confirm`): pickup, stops and
  /// drop-off as small white dots ringed green, blue and red, and a thinner,
  /// deeper blue route line.
  final bool dotPins;

  /// Map layers drawn over the route and under the pins (a second line).
  final List<Widget> extraLayers;

  @override
  State<RideMap> createState() => _RideMapState();
}

class _RideMapState extends State<RideMap> {
  late final MapController _controller = widget.controller ?? MapController();
  bool _ready = false;

  List<LatLng> get _points => [
    widget.pickup,
    ...widget.stops,
    widget.drop,
    widget.driver,
    widget.me,
    ...widget.framed,
  ].whereType<LatLng>().toList();

  @override
  void didUpdateWidget(covariant RideMap old) {
    super.didUpdateWidget(old);
    if (_ready &&
        widget.autoFit &&
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
    // Frame the points in the part of the map a sheet over it leaves showing.
    final bottom = MapBottomInset.of(context);
    return CameraFit.coordinates(coordinates: pts, padding: EdgeInsets.fromLTRB(64, 64, 64, 64 + bottom), maxZoom: 16);
  }

  void _fit() {
    final pts = [..._points, ...widget.route];
    if (pts.isEmpty) return;
    final fit = _cameraFit;
    if (fit == null) {
      _controller.move(pts.first, widget.pointZoom);
      return;
    }
    _controller.fitCamera(fit);
  }

  @override
  Widget build(BuildContext context) {
    // The opening view is worked out here, against the size the map is laid
    // out at, rather than handed to flutter_map as `initialCameraFit`: that
    // fit moves the camera without telling the tile layer, which had already
    // asked for the tiles of the unfitted view (zoom 14 on the first point).
    // A map opened framing two points far apart — a ride's pickup and
    // drop-off — then showed only grey until it was dragged.
    return LayoutBuilder(
      builder: (context, constraints) {
        final start = openingView(
          _points,
          widget.route,
          Size(constraints.maxWidth, constraints.maxHeight),
          bottom: MapBottomInset.of(context),
          pointZoom: widget.pointZoom,
        );
        return FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: start.center,
            initialZoom: start.zoom,
            onTap: widget.onTap == null ? null : (_, p) => widget.onTap!(p),
            onPositionChanged: widget.onGesture == null
                ? null
                : (_, gesture) {
                    if (gesture) widget.onGesture!();
                  },
            onMapReady: () {
              _ready = true;
              if (widget.autoFit) _fit();
              widget.onReady?.call();
            },
          ),
          children: [
            baseTileLayer(context, satellite: widget.satellite),
            if (widget.route.length > 1)
              PolylineLayer(
                polylines: [
                  widget.dotPins
                      ? Polyline(points: widget.route, strokeWidth: 4, color: const Color(0xFF4A90D9))
                      : Polyline(points: widget.route, strokeWidth: 5, color: const Color(0xFF2DABE2)),
                ],
              ),
            ...widget.extraLayers,
            if (widget.extraMarkers.isNotEmpty) MarkerLayer(rotate: true, markers: widget.extraMarkers),
            MarkerLayer(
              // Pins stand upright on a map turned to the car's heading…
              rotate: true,
              markers: [
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
                if (widget.dotPins) ...[
                  if (widget.pickup != null && widget.showPickup) _dot(widget.pickup!, const Color(0xFF22C55E), 'pickup'),
                  for (var i = 0; i < widget.stops.length; i++) _dot(widget.stops[i], const Color(0xFF3B82F6), 'stop-$i'),
                  if (widget.drop != null) _dot(widget.drop!, const Color(0xFFEF4444), 'drop'),
                ],
                if (!widget.dotPins && widget.pickup != null && widget.showPickup)
                  Marker(
                    point: widget.pickup!,
                    width: pickupPinHead,
                    height: pickupPinHeight,
                    alignment: Alignment.topCenter,
                    child: const PickupPin(),
                  ),
                if (!widget.dotPins)
                  for (var i = 0; i < widget.stops.length; i++)
                  Marker(
                    point: widget.stops[i],
                    width: 26,
                    height: 26,
                    child: CircleAvatar(
                      backgroundColor: Colors.orange.shade800,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                if (!widget.dotPins && widget.drop != null) _pin(widget.drop!, Colors.red.shade700, Icons.location_on),
                if (widget.driver != null)
                  Marker(
                    point: widget.driver!,
                    // …but the car turns with the map, so it keeps pointing
                    // the way it drives.
                    rotate: false,
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
              ],
            ),
            // Above any sheet floating over the map, so the credit stays reachable.
            MapBottomInset.listen(
              context,
              (inset) => Padding(
                padding: EdgeInsets.only(bottom: inset),
                child: const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
              ),
            ),
          ],
        );
      },
    );
  }

  Marker _dot(LatLng p, Color c, String name) => Marker(
    point: p,
    width: 18,
    height: 18,
    child: Container(
      key: ValueKey('map-dot-$name'),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: c, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
    ),
  );

  Marker _pin(LatLng p, Color c, IconData icon) => Marker(
    point: p,
    width: 40,
    height: rideMapPinBox,
    alignment: Alignment.topCenter,
    child: Icon(
      icon,
      color: c,
      size: rideMapPinIcon,
      shadows: const [Shadow(blurRadius: 4, color: Colors.black38)],
    ),
  );
}
