import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'map_sheet_layout.dart';
import 'map_credit.dart';
import 'map_tiles.dart';
import 'road_info_layers.dart';

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
  double top = 64,
  double pointZoom = 15,
}) {
  final all = [...points, ...route];
  final first = points.isNotEmpty ? points.first : (all.isNotEmpty ? all.first : defaultCenter);
  if (all.length < 2 || !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0) {
    return (center: first, zoom: points.length == 1 ? pointZoom : 14);
  }
  final fitted = CameraFit.coordinates(
    coordinates: all,
    padding: EdgeInsets.fromLTRB(64, top, 64, 64 + bottom),
    maxZoom: 16,
  ).fit(MapCamera(crs: const Epsg3857(), center: first, zoom: 14, rotation: 0, nonRotatedSize: size));
  return (center: fitted.center, zoom: fitted.zoom);
}

/// The least zoom at which one copy of the world spans a map [width] wide
/// (256 px a tile), so flutter_map never draws it, and the pins on it,
/// twice side by side. 0 for an unbounded or empty width.
double worldOnceZoom(double width) =>
    width.isFinite && width > 256 ? math.log(width / 256) / math.ln2 + 0.05 : 0;

/// How far up from the map's bottom edge (or the sheet over it) the
/// bottom-right map buttons start. The OpenStreetMap credit sits bottom
/// left, so the buttons only keep a margin rather than clearing it.
const mapAttributionClearance = 12.0;

/// The height the map credit takes in the bottom-left corner (its ⓘ button
/// and padding), above the safe area: what floats in that corner starts
/// above it.
const mapCreditHeight = 48.0;

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

/// The confirm map's pickup and drop-off squares (inDrive's).
const confirmBadgeSize = 36.0;

/// The confirm map's pickup: its square stands this far over the ringed
/// dot on the point, which is this wide.
const confirmPickupGap = 4.0, confirmPickupDot = 14.0;

/// How far above its point each confirm-map mark reaches: the pickup's
/// square stands over its dot; the drop-off's square is centred on it.
const confirmPickupTop = confirmBadgeSize + confirmPickupGap + confirmPickupDot / 2;
const confirmDropTop = confirmBadgeSize / 2;

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
    this.topMarkers = const [],
    this.framed = const [],
    this.satellite = false,
    this.autoFit = true,
    this.onGesture,
    this.onReady,
    this.pointZoom = 15,
    this.showPickup = true,
    this.dotPins = false,
    this.fitTop = 64,
    this.fitBottom = 64,
    this.focusPickup = false,
    this.extraLayers = const [],
    this.hideCredit = false,
    this.trafficSignals = true,
    this.tileOverlays = const [],
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

  /// Labels drawn over everything, the car included (the request map's
  /// time and distance chips, which the car near the drop-off covered).
  final List<Marker> topMarkers;

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

  /// The confirm screen's look (inDrive's): the pickup a waving rider in a
  /// rounded square over a ringed dot, stops numbered squares, the drop-off
  /// a flag, and the route a thinner line, all black on a light map and
  /// white on a dark one.
  final bool dotPins;

  /// Room kept above the topmost point when the map frames them (more where
  /// labels stand over the pins, or a title over the map).
  final double fitTop;

  /// Room kept below the lowest point, over what a sheet covers
  /// ([MapBottomInset]): more where a bar stands on the sheet's top.
  final double fitBottom;

  /// The home map's look (inDrive's): with no drop-off yet the camera keeps
  /// the pickup (else the rider) alone in the middle of the map above the
  /// sheet when it is all the way down ([MapBottomInset.focusOffset]),
  /// rather than framing every point.
  final bool focusPickup;

  /// Map layers drawn over the route and under the pins (a second line).
  final List<Widget> extraLayers;

  /// Slides the OpenStreetMap credit down off the map and back, alongside a
  /// sheet hidden while the map is dragged under the pickup pin.
  final bool hideCredit;
  /// OSM traffic signals drawn once zoomed in ([TrafficSignalsLayer]).
  final bool trafficSignals;

  /// Transparent tile layers drawn straight over the base tiles, under the
  /// route and pins (the driver map's live traffic).
  final List<Widget> tileOverlays;

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
    _shown.value = widget;
    if (_ready &&
        widget.autoFit &&
        (old.pickup != widget.pickup ||
            old.drop != widget.drop ||
            old.stops.length != widget.stops.length ||
            old.route.length != widget.route.length ||
            old.framed.length != widget.framed.length ||
            // Room above or below changed (the card over the map grew).
            old.fitTop != widget.fitTop ||
            old.fitBottom != widget.fitBottom ||
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
    return CameraFit.coordinates(
      coordinates: pts,
      padding: EdgeInsets.fromLTRB(64, widget.fitTop, 64, widget.fitBottom + bottom),
      maxZoom: 16,
    );
  }

  /// The point [RideMap.focusPickup] keeps in the middle; null when off, or
  /// when there is a route to frame instead.
  LatLng? get _focus =>
      widget.focusPickup && widget.drop == null && widget.route.isEmpty ? widget.pickup ?? widget.me : null;

  void _fit() {
    final focus = _focus;
    if (focus != null) {
      _controller.move(focus, widget.pointZoom, offset: MapBottomInset.focusOffset(context));
      return;
    }
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
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  /// The map's moving parts (pins, the car, the route): handed to the layers
  /// that draw them through here, so a new position redraws those layers
  /// alone. The [FlutterMap] itself, its options and its base tiles are kept
  /// as they are, and the tiles redraw only when the camera moves.
  late final _shown = ValueNotifier<RideMap>(widget);

  /// The parts of the map kept from one build to the next (see [_shown]).
  MapOptions? _options;
  Widget? _base, _credit;
  bool? _baseSatellite;
  (bool, bool)? _creditFor;
  FlutterMap? _map;
  late final Widget _layers = ValueListenableBuilder<RideMap>(
    valueListenable: _shown,
    builder: (context, w, _) => _movingLayers(context, w),
  );

  void _onTap(TapPosition _, LatLng p) => widget.onTap?.call(p);

  void _onPositionChanged(MapCamera _, bool gesture) {
    if (gesture) widget.onGesture?.call();
  }

  void _onMapReady() {
    _ready = true;
    if (widget.autoFit) _fit();
    widget.onReady?.call();
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
        // Only the first opens the map: flutter_map keeps its camera through
        // later options, so they are made once and kept (new options would
        // redraw every layer, the tiles included).
        _options ??= () {
          final start = openingView(
            _points,
            widget.route,
            Size(constraints.maxWidth, constraints.maxHeight),
            bottom: MapBottomInset.of(context) + widget.fitBottom - 64,
            top: widget.fitTop,
            pointZoom: widget.pointZoom,
          );
          final minZoom = worldOnceZoom(constraints.maxWidth);
          return MapOptions(
            initialCenter: start.center,
            initialZoom: math.max(start.zoom, minZoom),
            // Never so far out that the world shows twice across the map, its
            // pins and labels with it (a wide, short map framing a ride).
            minZoom: minZoom,
            // North stays up: two fingers pinch and pan but never turn the
            // map (a trip map that follows the car still turns it itself).
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onTap: _onTap,
            onPositionChanged: _onPositionChanged,
            onMapReady: _onMapReady,
          );
        }();
        // The base tiles follow the theme and Admin → Settings → Maps by
        // themselves; only satellite makes new ones.
        if (_baseSatellite != widget.satellite) {
          _baseSatellite = widget.satellite;
          _base = baseTileLayer(context, satellite: widget.satellite);
        }
        final creditFor = (widget.hideCredit, widget.satellite);
        if (_creditFor != creditFor) {
          _creditFor = creditFor;
          _credit = _creditLayer(widget.hideCredit, widget.satellite);
        }
        final children = [_base!, ...widget.tileOverlays, _layers, _credit!];
        final kept = _map;
        if (kept == null || !listEquals(kept.children, children)) {
          _map = FlutterMap(mapController: _controller, options: _options!, children: children);
        }
        return _map!;
      },
    );
  }

  /// The OpenStreetMap credit, above any sheet floating over the map so it
  /// stays reachable.
  static Widget _creditLayer(bool hide, bool satellite) => Builder(
    builder: (context) => MapBottomInset.listen(
      context,
      (inset) => TweenAnimationBuilder<double>(
        tween: Tween(end: hide ? 1 : 0),
        duration: MapSheetLayout.hideDuration,
        curve: hide ? Curves.easeIn : Curves.easeOut,
        builder: (_, t, child) => IgnorePointer(
          ignoring: hide,
          child: Opacity(
            opacity: 1 - t,
            // Down past the map's bottom edge, as the sheet goes.
            child: Transform.translate(offset: Offset(0, t * (inset + 56)), child: child),
          ),
        ),
        child: Padding(
          key: const ValueKey('map-credit'),
          padding: EdgeInsets.only(bottom: inset),
          child: MapCreditLayer(satellite: satellite),
        ),
      ),
    ),
  );

  /// The route, pins and car of [w], over the base tiles: what a new
  /// position redraws. Stacked as flutter_map stacks its own layers.
  Widget _movingLayers(BuildContext context, RideMap w) {
    final ink = _markerInk(context);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (w.route.length > 1)
          PolylineLayer(
            polylines: [
              w.dotPins
                  ? Polyline(points: w.route, strokeWidth: 4, color: ink.fill)
                  : Polyline(points: w.route, strokeWidth: 5, color: const Color(0xFF2DABE2)),
            ],
          ),
        if (w.trafficSignals) const TrafficSignalsLayer(),
        ...w.extraLayers,
        if (w.extraMarkers.isNotEmpty) MarkerLayer(rotate: true, markers: w.extraMarkers),
        MarkerLayer(
          // Pins stand upright on a map turned to the car's heading…
          rotate: true,
          markers: [
            if (w.me != null)
              Marker(
                point: w.me!,
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
            if (w.dotPins) ...[
              if (w.pickup != null && w.showPickup) _pickupBadge(w.pickup!, ink),
              for (var i = 0; i < w.stops.length; i++)
                _badge(
                  w.stops[i],
                  'stop-$i',
                  ink,
                  size: 26,
                  glyph: (ink) => Text(
                    '${i + 1}',
                    style: TextStyle(color: ink, fontSize: 14, fontWeight: FontWeight.w700, height: 1),
                  ),
                ),
              if (w.drop != null)
                _badge(w.drop!, 'drop', ink, glyph: (ink) => Icon(Icons.flag, color: ink, size: 22)),
            ],
            if (!w.dotPins && w.pickup != null && w.showPickup)
              Marker(
                point: w.pickup!,
                width: pickupPinHead,
                height: pickupPinHeight,
                alignment: Alignment.topCenter,
                child: const PickupPin(),
              ),
            if (!w.dotPins)
              for (var i = 0; i < w.stops.length; i++)
              Marker(
                point: w.stops[i],
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
            if (!w.dotPins && w.drop != null) _pin(w.drop!, Colors.red.shade700, Icons.location_on),
            if (w.driver != null)
              Marker(
                point: w.driver!,
                // …but the car turns with the map, so it keeps pointing
                // the way it drives.
                rotate: false,
                width: 40,
                height: 40,
                child: CircleAvatar(
                  backgroundColor: Colors.black,
                  child: w.driverHeading == null
                      ? const Icon(Icons.local_taxi, color: Color(0xFFFFD400), size: 22)
                      : Transform.rotate(
                          key: const ValueKey('driver-heading'),
                          angle: w.driverHeading! * math.pi / 180,
                          child: const Icon(Icons.navigation, color: Color(0xFFFFD400), size: 22),
                        ),
                ),
              ),
          ],
        ),
        if (w.topMarkers.isNotEmpty) MarkerLayer(rotate: true, markers: w.topMarkers),
      ],
    );
  }

  /// inDrive's confirm map: black marks with white glyphs on a light map,
  /// and the reverse on a dark one (as [PickupPin]); the route in the same.
  static ({Color fill, Color ink}) _markerInk(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? (fill: Colors.white, ink: Colors.black)
          : (fill: const Color(0xFF111111), ink: Colors.white);

  /// A rounded square on the point holding [glyph] (a stop's number, the
  /// drop-off's flag).
  static Marker _badge(
    LatLng p,
    String name,
    ({Color fill, Color ink}) c, {
    double size = confirmBadgeSize,
    required Widget Function(Color ink) glyph,
  }) {
    return Marker(
      point: p,
      width: size,
      height: size,
      child: Container(
        key: ValueKey('map-dot-$name'),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(size * 0.28),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: glyph(c.ink),
      ),
    );
  }

  /// The pickup: the waving rider in a rounded square, stood just above a
  /// ringed dot on the point itself.
  static Marker _pickupBadge(LatLng p, ({Color fill, Color ink}) c) {
    const gap = confirmPickupGap, dot = confirmPickupDot;
    const h = confirmBadgeSize + gap + dot;
    return Marker(
      point: p,
      width: confirmBadgeSize,
      height: h,
      // The dot's centre, not the box's, sits on the point.
      alignment: const Alignment(0, -(h - dot) / h),
      child: Column(
        key: const ValueKey('map-dot-pickup'),
        children: [
          Container(
            width: confirmBadgeSize,
            height: confirmBadgeSize,
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(confirmBadgeSize * 0.28),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
            child: Icon(Icons.emoji_people, color: c.ink, size: 24),
          ),
          const SizedBox(height: gap),
          Container(
            key: const ValueKey('map-dot-pickup-point'),
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: c.ink,
              shape: BoxShape.circle,
              border: Border.all(color: c.fill, width: 4),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
            ),
          ),
        ],
      ),
    );
  }

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
