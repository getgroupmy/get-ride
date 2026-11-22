import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as am;
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/map_profile.dart' show mapProfileListenable;
import '../data/geo_service.dart';
import 'apple_native_layer.dart' show MapRouteLine;
import 'map_badge_bitmap.dart';
import 'map_sheet_layout.dart';
import 'map_credit.dart';
import 'map_tiles.dart';
import 'road_info_layers.dart';
import 'map_vehicle_icon.dart';

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

/// How far above its point each confirm-map mark reaches. The pickup and the
/// drop-off both stand their square over a ringed dot on the point, so they
/// reach the same height and line up the same way over the route however far
/// the map is zoomed out (before, the drop's square was centred on its point
/// and so sat lower than the pickup — they read as out of line when zoomed out).
const confirmPickupTop = confirmBadgeSize + confirmPickupGap + confirmPickupDot / 2;
const confirmDropTop = confirmPickupTop;

/// The pickup pin, [pickupPinHeight] tall, standing on its point.
class PickupPin extends StatelessWidget {
  const PickupPin({super.key, this.elevation = 0});

  /// 0 standing, 1 lifted (a deeper shadow while it floats).
  final double elevation;

  @override
  Widget build(BuildContext context) {
    // Light maps get a black head with a white figure; dark maps the reverse.
    final dark = mapIsDark(context);
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

/// A car as a map draws it: where, and the way it faces (degrees clockwise from
/// north; null when not known).
typedef CarOnMap = ({LatLng at, double? heading});

/// OpenStreetMap view used on every platform (web, desktop, iOS, Android).
class RideMap extends StatefulWidget {
  const RideMap({
    super.key,
    this.pickup,
    this.drop,
    this.stops = const [],
    this.driver,
    this.driverHeading,
    this.driverIcon,
    this.me,
    this.route = const [],
    this.onTap,
    this.controller,
    this.extraMarkers = const [],
    this.topMarkers = const [],
    this.framed = const [],
    this.satellite = false,
    this.autoFit = true,
    this.rotate = false,
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
    this.nativeMe = false,
    this.showMeDot = true,
    this.meLive,
    this.driverLive,
  });

  /// Draw the device's own location dot with the native map (MapKit) itself
  /// rather than as a flutter_map marker, so it stays on the real spot while
  /// the map is panned instead of sliding a frame behind the native base.
  /// On for the partner's own map, where the driver pans the idle map around;
  /// the rider and confirm maps keep the flutter_map dot.
  final bool nativeMe;

  /// Whether this map draws the location dot at all (native or flutter_map).
  /// Off where the caller draws its own dot over the map — the driver idle map
  /// welds the heading cone to its own dot so the two can never drift apart,
  /// which a separately-drawn native dot does during motion.
  final bool showMeDot;

  /// Where the device is a frame at a time, where the caller keeps up with it
  /// (the rider's home map, live_position.dart). The location dot is then drawn
  /// there — in a layer of its own, which a new position redraws alone — and at
  /// [me] until the first live position comes. Only the dot moves with it:
  /// [me] is still what the camera counts, so a rider walking along does not
  /// drag the map, the pickup pin or its address with them.
  final ValueListenable<LatLng?>? meLive;

  /// The car a frame at a time, where the caller works out its motion between
  /// the positions it has (the trip maps, live_ride_map.dart). The car is then
  /// drawn there, facing that way — in a layer of its own, which a new frame
  /// redraws alone — and at [driver] and [driverHeading] while it holds
  /// nothing. [driver] is still the car's latest known position for everything
  /// else (framing, and what the caller reads it for).
  final ValueListenable<CarOnMap?>? driverLive;

  final LatLng? pickup;
  final LatLng? drop;

  /// Stops on the way, in order (numbered pins).
  final List<LatLng> stops;
  final LatLng? driver;

  /// Compass heading of the driver's car in degrees (0 = north), turning
  /// the car marker to face where it is going.
  final double? driverHeading;

  /// The ride service's Map Icon (`media:<id>`, [MapVehicleIcon]): a
  /// multi-angle icon shows the frame for [driverHeading], upright; null
  /// keeps the built-in car.
  final String? driverIcon;
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

  /// Whether two fingers may turn the map. Off by default — north stays up on
  /// the trip maps, which turn the map themselves while following the car. The
  /// driver's idle home map turns it on so the driver can rotate it freely.
  final bool rotate;

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
    if (old.route != widget.route ||
        old.dotPins != widget.dotPins ||
        old.me != widget.me ||
        old.nativeMe != widget.nativeMe) {
      _syncApple();
    }
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
    _appleRoute.dispose();
    _appleMe.dispose();
    _appleAnnotations.dispose();
    _marksKey.dispose();
    super.dispose();
  }

  /// The map's moving parts (pins, the car, the route): handed to the layers
  /// that draw them through here, so a new position redraws those layers
  /// alone. The [FlutterMap] itself, its options and its base tiles are kept
  /// as they are, and the tiles redraw only when the camera moves.
  late final _shown = ValueNotifier<RideMap>(widget);

  /// The route line for MapKit to draw itself on the Apple base (iOS), kept in
  /// step with the base instead of lagging it as a flutter_map overlay would.
  /// Null off a route; the flutter_map line (below) is hidden while Apple draws
  /// it. Set outside build (theme + widget changes), never from _movingLayers,
  /// so the base layer listening to it is not marked dirty mid-build.
  final _appleRoute = ValueNotifier<MapRouteLine?>(null);

  /// Whether MapKit should draw the device's own location dot on the Apple base
  /// (iOS), so it stays on the real spot while the map pans instead of sliding
  /// as a flutter_map marker does. On whenever this map has a "me" to show; the
  /// flutter_map dot (below) is hidden while Apple draws it.
  final _appleMe = ValueNotifier<bool>(false);

  /// The confirm map's marks for MapKit to draw itself on the Apple base, so
  /// the marks, the route and Apple's roads all share one projection and line
  /// up (a flutter_map marker over a native route drifts off it). Empty off the
  /// Apple base, off the confirm map, or until the images are rendered. The
  /// flutter_map badges (below) are hidden while these are drawn.
  final _appleAnnotations = ValueNotifier<Set<am.Annotation>>(const {});

  /// The marks key the current [_appleAnnotations] were built for (null: none),
  /// and the latest key asked for. [_movingLayers] shows native marks only when
  /// the built key matches what it wants, so it never hides the flutter badges
  /// before the native ones are up.
  final _marksKey = ValueNotifier<String?>(null);
  String? _marksWant;
  int _annSeq = 0;

  void _syncApple() {
    _appleRoute.value = _appleRouteLine(widget);
    _appleMe.value = widget.me != null && widget.nativeMe && widget.showMeDot;
  }

  /// The route line for MapKit. The live trip line is always MapKit's, locked to
  /// the roads as the map pans. The confirm map (dotPins) switches to MapKit's
  /// line only once its native marks are up ([_marksKey]), so the route and the
  /// marks move onto the Apple base together; until then its flutter_map line is
  /// drawn (below) alongside the flutter_map marks.
  MapRouteLine? _appleRouteLine(RideMap w) {
    if (w.route.length < 2) return null;
    if (!w.dotPins) return MapRouteLine(points: w.route, color: const Color(0xFF2DABE2), width: 5);
    if (_marksKey.value == null) return null;
    return MapRouteLine(points: w.route, color: _markerInk(context).fill, width: 4);
  }

  /// A value key for the confirm marks MapKit should draw: the theme and each
  /// mark's point, or null when native marks don't apply (off the Apple base,
  /// off the confirm map, or no marks). Pure given the map profile + theme.
  String? _wantMarksKey(BuildContext context, RideMap w) {
    if (!w.dotPins) return null;
    if (!appleRouteBaseActive(context, satellite: w.satellite)) return null;
    final b = StringBuffer(mapIsDark(context) ? 'd' : 'l');
    var any = false;
    if (w.pickup != null && w.showPickup) {
      any = true;
      b.write('|p:${w.pickup!.latitude},${w.pickup!.longitude}');
    }
    for (var i = 0; i < w.stops.length; i++) {
      any = true;
      b.write('|s$i:${w.stops[i].latitude},${w.stops[i].longitude}');
    }
    if (w.drop != null) {
      any = true;
      b.write('|d:${w.drop!.latitude},${w.drop!.longitude}');
    }
    return any ? b.toString() : null;
  }

  /// Renders the confirm marks to native annotations and brings up the native
  /// route with them, or clears them — whenever what [_movingLayers] wants
  /// ([want]) changes. Async (the images need the engine); guarded by a sequence
  /// so a stale render never lands. On any failure the flutter marks/line stay.
  void _ensureApple(BuildContext context, RideMap w, String? want) {
    if (want == _marksWant) return;
    _marksWant = want;
    final seq = ++_annSeq;
    if (want == null) {
      scheduleMicrotask(() {
        if (seq != _annSeq || !mounted) return;
        _appleAnnotations.value = const {};
        _marksKey.value = null;
        _syncApple();
      });
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final ink = _markerInk(context);
    () async {
      try {
        final set = await _renderMarks(w, ink, dpr);
        if (seq != _annSeq || !mounted) return;
        _appleAnnotations.value = set;
        _marksKey.value = want;
        _syncApple();
      } catch (_) {
        if (seq == _annSeq) _marksWant = null; // let a later build try again
      }
    }();
  }

  /// The confirm marks as MapKit annotations (pickup a waving rider, stops their
  /// numbers, drop-off a flag), each anchored so its dot sits on the point.
  Future<Set<am.Annotation>> _renderMarks(RideMap w, ({Color fill, Color ink}) c, double dpr) async {
    final out = <am.Annotation>{};
    Future<void> add(String id, LatLng p, {IconData? glyph, String? number, double glyphSize = 22, double square = confirmBadgeSize, bool withDot = true}) async {
      final png = await renderConfirmBadgePng(
        glyph: glyph,
        number: number,
        fill: c.fill,
        ink: c.ink,
        square: square,
        glyphSize: glyphSize,
        withDot: withDot,
        scale: dpr,
      );
      final m = badgeImageMetrics(square: square, withDot: withDot);
      out.add(am.Annotation(
        annotationId: am.AnnotationId(id),
        position: am.LatLng(p.latitude, p.longitude),
        anchor: m.anchor,
        icon: am.BitmapDescriptor.fromBytes(png),
      ));
    }

    if (w.pickup != null && w.showPickup) await add('pickup', w.pickup!, glyph: Icons.emoji_people, glyphSize: 24);
    for (var i = 0; i < w.stops.length; i++) {
      await add('stop-$i', w.stops[i], number: '${i + 1}', glyphSize: 14, square: 26, withDot: false);
    }
    if (w.drop != null) await add('drop', w.drop!, glyph: Icons.flag, glyphSize: 22);
    return out;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncApple();
  }

  /// The parts of the map kept from one build to the next (see [_shown]).
  MapOptions? _options;
  Widget? _base, _credit;
  bool? _baseSatellite;
  (bool, bool)? _creditFor;
  FlutterMap? _map;
  // Also rebuilds when the map set loads/changes: whether the route line is
  // the flutter_map overlay or MapKit's own (appleRouteBaseActive) turns on
  // which base is drawn, so a profile arriving late must redraw these layers.
  late final Widget _layers = ListenableBuilder(
    listenable: Listenable.merge([_shown, mapProfileListenable, _marksKey]),
    builder: (context, _) => _movingLayers(context, _shown.value),
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
            // North stays up unless the map opts into rotation ([rotate]): two
            // fingers pinch and pan, and turn the map only where it is allowed
            // (the driver's idle home map). A trip map that follows the car
            // still turns it itself.
            interactionOptions: InteractionOptions(
              flags: widget.rotate ? InteractiveFlag.all : (InteractiveFlag.all & ~InteractiveFlag.rotate),
              keyboardOptions: mapKeyboardOptions,
            ),
            onTap: _onTap,
            onPositionChanged: _onPositionChanged,
            onMapReady: _onMapReady,
          );
        }();
        // The base tiles follow the theme and Admin → Settings → Maps by
        // themselves; only satellite makes new ones.
        if (_baseSatellite != widget.satellite) {
          _baseSatellite = widget.satellite;
          _base = baseTileLayer(
            context,
            satellite: widget.satellite,
            route: _appleRoute,
            showMe: _appleMe,
            annotations: _appleAnnotations,
          );
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
    // The confirm map (dotPins) draws its route and its pickup/drop marks as
    // MapKit's own on the Apple base, so they and Apple's roads share one
    // projection and line up. [_ensureApple] renders the marks (async); once
    // they are up (nativeMarks) the flutter_map line and badges below are
    // hidden and MapKit's take over. Until then — and everywhere but the Apple
    // base — the flutter_map line and badges are drawn, each in one projection
    // with the other.
    final appleActive = appleRouteBaseActive(context, satellite: w.satellite);
    final want = _wantMarksKey(context, w);
    _ensureApple(context, w, want);
    final nativeMarks = want != null && _marksKey.value == want;
    // The flutter_map line: on every base except where MapKit draws it — the
    // live trip on the Apple base, and the confirm map once its native marks are up.
    final appleDrawsLine = appleActive && (!w.dotPins || nativeMarks);
    // Where a native map draws the location dot itself (the partner map on the
    // Apple or Google base), it is locked to the base and stays on the real
    // spot while the map pans and zooms; the flutter_map dot would slide off it
    // (the base follows a frame late, and the two projections diverge away from
    // the centre — worse zoomed out). Everywhere else it is the flutter_map dot.
    final flutterDot = w.showMeDot &&
        !(w.nativeMe && (appleActive || googleNativeBaseActive(context, satellite: w.satellite)));
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (w.route.length > 1 && !appleDrawsLine)
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
        // The location dot kept up with a frame at a time ([RideMap.meLive]):
        // under the pins, as the dot below is, and in a layer of its own so a
        // new position redraws the dot and nothing else — not the pins and
        // labels beside it, nor the native map under them.
        if (flutterDot && w.meLive != null)
          RepaintBoundary(
            child: ValueListenableBuilder<LatLng?>(
              valueListenable: w.meLive!,
              builder: (context, live, _) {
                final at = live ?? w.me;
                if (at == null) return const SizedBox.shrink();
                return MarkerLayer(rotate: true, markers: [_liveMeDot(at)]);
              },
            ),
          ),
        MarkerLayer(
          // Pins stand upright on a map turned to the car's heading…
          rotate: true,
          markers: [
            if (flutterDot && w.meLive == null && w.me != null) _meDot(w.me!),
            // Hidden while MapKit draws these marks itself (nativeMarks) so the
            // two never show at once.
            if (w.dotPins && !nativeMarks) ...[
              if (w.pickup != null && w.showPickup)
                _pointBadge(w.pickup!, 'pickup', ink, Icon(Icons.emoji_people, color: ink.ink, size: 24)),
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
                _pointBadge(w.drop!, 'drop', ink, Icon(Icons.flag, color: ink.ink, size: 22)),
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
            if (w.driver != null && w.driverLive == null) carMarker(w.driver!, carMark(w.driverHeading, w.driverIcon)),
          ],
        ),
        // The car kept up with a frame at a time ([RideMap.driverLive]): over
        // the pins, as the car above is, and in a layer of its own so a new
        // frame redraws the car and nothing else.
        if (w.driverLive != null)
          RepaintBoundary(
            child: _LiveCar(live: w.driverLive!, at: w.driver, heading: w.driverHeading, icon: w.driverIcon),
          ),
        if (w.topMarkers.isNotEmpty) MarkerLayer(rotate: true, markers: w.topMarkers),
      ],
    );
  }

  /// The car's marker at [at]. Pins stand upright on a map turned to the car's
  /// heading, but the car turns with the map, so it keeps pointing the way it
  /// drives.
  static Marker carMarker(LatLng at, Widget mark) =>
      Marker(point: at, rotate: false, width: 40, height: 40, child: mark);

  /// The car as drawn: its service's Map Icon ([icon]) for [heading], or the
  /// built-in mark turned to it.
  static Widget carMark(double? heading, String? icon) => MapVehicleIcon(
    key: const ValueKey('driver-car'),
    icon: icon,
    heading: heading,
    size: 40,
    fallback: CircleAvatar(
      backgroundColor: Colors.black,
      child: heading == null
          ? const Icon(Icons.local_taxi, color: Color(0xFFFFD400), size: 22)
          : Transform.rotate(
              key: const ValueKey('driver-heading'),
              angle: heading * math.pi / 180,
              child: const Icon(Icons.navigation, color: Color(0xFFFFD400), size: 22),
            ),
    ),
  );

  /// The device's own location: a blue dot ringed in white, on its point.
  static const _meDotSize = 22.0;

  static Widget _meDotMark() => Container(
    key: const ValueKey('map-me-dot'),
    decoration: BoxDecoration(
      color: Colors.blue,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
    ),
  );

  static Marker _meDot(LatLng at) => Marker(point: at, width: _meDotSize, height: _meDotSize, child: _meDotMark());

  /// The same dot for a position that changes every frame ([RideMap.meLive]):
  /// in a layer of its own, with room in it for the dot's shadow, so it is
  /// drawn once and moved rather than painted, shadow and all, every frame.
  static Marker _liveMeDot(LatLng at) => Marker(
    point: at,
    width: _meDotSize + 24,
    height: _meDotSize + 24,
    child: RepaintBoundary(
      child: Center(child: SizedBox.square(dimension: _meDotSize, child: _meDotMark())),
    ),
  );

  /// inDrive's confirm map: black marks with white glyphs on a light map,
  /// and the reverse on a dark one (as [PickupPin]); the route in the same.
  static ({Color fill, Color ink}) _markerInk(BuildContext context) =>
      mapIsDark(context)
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

  /// A confirm-map mark ([glyph] in a rounded square) stood just above a ringed
  /// dot that sits on the point itself (inDrive's). The pickup (a waving rider)
  /// and the drop-off (a flag) both use it, so they line up the same way over
  /// the route however far the map is zoomed out.
  static Marker _pointBadge(LatLng p, String name, ({Color fill, Color ink}) c, Widget glyph) {
    const gap = confirmPickupGap, dot = confirmPickupDot;
    const h = confirmBadgeSize + gap + dot;
    return Marker(
      point: p,
      width: confirmBadgeSize,
      height: h,
      // The dot's centre, not the box's, sits on the point.
      alignment: const Alignment(0, -(h - dot) / h),
      child: Column(
        key: ValueKey('map-dot-$name'),
        children: [
          Container(
            width: confirmBadgeSize,
            height: confirmBadgeSize,
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(confirmBadgeSize * 0.28),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
            child: glyph,
          ),
          const SizedBox(height: gap),
          Container(
            key: ValueKey('map-dot-$name-point'),
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

/// The car where [live] has it, a frame at a time ([RideMap.driverLive]); at
/// [at], facing [heading], while [live] holds nothing.
///
/// The car's picture is kept from one frame to the next while it faces the
/// same way — along a straight road only its place on the map changes — so a
/// frame moves a picture already drawn.
class _LiveCar extends StatefulWidget {
  const _LiveCar({required this.live, required this.at, required this.heading, required this.icon});
  final ValueListenable<CarOnMap?> live;
  final LatLng? at;
  final double? heading;
  final String? icon;

  @override
  State<_LiveCar> createState() => _LiveCarState();
}

class _LiveCarState extends State<_LiveCar> {
  Widget? _mark;
  (double?, String?)? _markFor;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<CarOnMap?>(
    valueListenable: widget.live,
    builder: (context, live, _) {
      final at = live?.at ?? widget.at;
      if (at == null) return const SizedBox.shrink();
      final looks = (live == null ? widget.heading : live.heading, widget.icon);
      if (_mark == null || _markFor != looks) {
        _markFor = looks;
        _mark = RepaintBoundary(child: _RideMapState.carMark(looks.$1, looks.$2));
      }
      return MarkerLayer(markers: [_RideMapState.carMarker(at, _mark!)]);
    },
  );
}
