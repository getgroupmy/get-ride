// Apple's own map in the iPhone app (Admin → Settings → Maps, migration
// 0214) as a FlutterMap's base layer: MapKit draws it under the app's own
// layers and follows the app's camera; the app's map takes every gesture.
// Built into the phone, so no key. It is also the iPhone's fallback when the
// map set for it can't draw (see map_tiles.dart).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as am;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'map_brightness.dart';

/// Whether this device can draw Apple's map: iPhone and iPad.
bool get appleNativeSupported => debugAppleNativeSupported ?? (!kIsWeb && Platform.isIOS);

/// A route line drawn by MapKit itself, on the native Apple map, so it moves in
/// perfect sync with the base instead of lagging it as a flutter_map overlay
/// does (the base follows the Flutter camera a frame late). [AppleNativeBaseLayer]
/// takes it live through a listenable; the caller hides its own flutter_map
/// line while this is drawn (ride_map.dart).
@immutable
class MapRouteLine {
  const MapRouteLine({required this.points, required this.color, required this.width});
  final List<LatLng> points;
  final Color color;
  final int width;

  @override
  bool operator ==(Object other) =>
      other is MapRouteLine && other.color == color && other.width == width && listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(color, width, Object.hashAll(points));
}

/// Tests set this to build Apple's map (a native view) as an iPhone would.
@visibleForTesting
bool? debugAppleNativeSupported;

/// Where MapKit draws the area it is asked to show.
///
/// The app's own layers (the location dot, the pins, the route) are drawn by
/// the app over Apple's map, so the two only line up if Apple's map shows
/// exactly the area the app's camera shows. Asked for an area, MapKit fits it
/// into what it takes to be the visible part of its view — and a full-screen
/// map's view runs under the status bar and the home indicator, which MapKit
/// leaves out (its layout margins follow the safe area). The area then lands
/// lower and smaller than the app drew over it: every dot and pin sat a fixed
/// few points off Apple's roads, which is a few metres zoomed in and a street
/// away zoomed out.
///
/// The margins are switched off ([AppleNativeBaseLayer] builds the map with
/// `insetsLayoutMarginsFromSafeArea: false`). And rather than trust that, the
/// layer asks MapKit where it really drew two points of the app's camera once
/// the map has come to rest: [corrected] turns the answer into the part of the
/// view MapKit draws into ([drawn]), and [areaFor] asks it for the ground the
/// app shows in just that part, which MapKit then draws where the app does.
/// A correction is kept only once MapKit is seen to obey it: zoomed in as far
/// as it will go it shows more than it is asked whatever it is asked, and
/// that is not a margin to allow for.
/// Pure; see test/apple_base_alignment_test.dart.
@immutable
class MapKitFit {
  const MapKitFit(this.drawn);

  /// MapKit draws what it is asked: the whole view.
  static const exact = MapKitFit(null);

  /// The part of the view (in its own points) MapKit draws a requested area of
  /// the view's shape into; null for the whole view.
  final Rect? drawn;

  /// Points of the screen a reading may be out by and still count as lined up.
  static const tolerance = 0.5;

  /// The area to ask MapKit for, so that it shows what [c] shows: the ground
  /// the app draws inside [drawn]. North up only (a turned map is not given an
  /// area: apple_native_layer.dart's `_follow`).
  ///
  /// Worked out from the corners of the screen themselves rather than taken
  /// from the camera's `visibleBounds`, which is measured from the nearest
  /// whole pixel to the centre and so comes out up to a pixel off.
  LatLngBounds areaFor(MapCamera c) {
    final r = drawn ?? Offset.zero & c.nonRotatedSize;
    final topLeft = c.screenOffsetToLatLng(r.topLeft), bottomRight = c.screenOffsetToLatLng(r.bottomRight);
    return LatLngBounds(
      LatLng(bottomRight.latitude, topLeft.longitude),
      LatLng(topLeft.latitude, bottomRight.longitude),
    );
  }

  /// Where MapKit draws the centre of what it is asked for: the middle of
  /// [drawn] (the middle of a view [size] when it draws what it is asked).
  Offset centreIn(Size size) => drawn?.center ?? size.center(Offset.zero);

  /// The fit after a check, with MapKit showing [areaFor] a camera whose map is
  /// [size]: the app draws two points of the ground at [app1] and [app2] on
  /// the screen, and MapKit says it drew them at [mapKit1] and [mapKit2].
  ///
  /// This fit itself when they agree (within [tolerance]); null when the
  /// reading cannot be right — MapKit still laying out, or held at the edge of
  /// how far it can zoom — so nothing is learnt from it.
  MapKitFit? corrected(Size size, {required Offset app1, required Offset app2, required Offset mapKit1, required Offset mapKit2}) {
    if (!mapKit1.isFinite || !mapKit2.isFinite) return null;
    if ((mapKit1 - app1).distance <= tolerance && (mapKit2 - app2).distance <= tolerance) return this;
    final acrossApp = app2.dx - app1.dx, downApp = app2.dy - app1.dy;
    if (acrossApp.abs() < 1 || downApp.abs() < 1) return null;
    // How MapKit's picture sits against the app's: scaled, and moved.
    final scaleX = (mapKit2.dx - mapKit1.dx) / acrossApp, scaleY = (mapKit2.dy - mapKit1.dy) / downApp;
    final moveX = mapKit1.dx - scaleX * app1.dx, moveY = mapKit1.dy - scaleY * app1.dy;
    // A map shown a quarter bigger or smaller, stretched, or half a screen
    // away is not a margin: it is a reading to leave alone.
    if (scaleX < 0.75 || scaleX > 1.25 || (scaleX - scaleY).abs() > 0.03) return null;
    if (moveX.abs() > size.width / 2 || moveY.abs() > size.height / 2) return null;
    final asked = drawn ?? Offset.zero & size;
    return MapKitFit(
      Rect.fromLTRB(
        scaleX * asked.left + moveX,
        scaleY * asked.top + moveY,
        scaleX * asked.right + moveX,
        scaleY * asked.bottom + moveY,
      ),
    );
  }

  @override
  bool operator ==(Object other) => other is MapKitFit && other.drawn == drawn;

  @override
  int get hashCode => drawn.hashCode;

  @override
  String toString() => 'MapKitFit(${drawn ?? 'exact'})';
}

/// How long the app's camera must have been still before MapKit is asked where
/// it drew it: not while the map is being dragged or is gliding somewhere.
const mapKitCheckAfter = Duration(milliseconds: 350);

/// The zooms between which MapKit is checked: outside them it stops at the end
/// of its own range and shows something else, which is not for correcting.
const mapKitCheckMinZoom = 5.0, mapKitCheckMaxZoom = 19.0;

/// Sets Apple's maps light or dark (ios/Runner/AppDelegate.swift).
const appleMapAppearanceChannel = MethodChannel('get_ride/map_appearance');

class AppleNativeBaseLayer extends StatefulWidget {
  const AppleNativeBaseLayer({
    super.key,
    required this.fallback,
    this.satellite = false,
    this.mapType,
    this.route,
    this.showMe,
    this.annotations,
  });

  final bool satellite;

  /// The route line MapKit draws on the map itself (null for none): locked to
  /// the base, so it never slides off the roads while the map is panned.
  final ValueListenable<MapRouteLine?>? route;

  /// Marks MapKit draws on the map itself (the confirm map's pickup/drop/stops),
  /// locked to the base like the route so they sit on it instead of drifting as
  /// flutter_map markers do. Empty for none. The caller hides its own flutter_map
  /// marks while these are drawn (ride_map.dart).
  final ValueListenable<Set<am.Annotation>>? annotations;

  /// Whether MapKit draws the device's own location dot (the standard blue
  /// dot): locked to the base like the route, so it stays on the real spot
  /// while the map is panned instead of sliding as a flutter_map marker does
  /// (the base follows the Flutter camera a frame late). The caller hides its
  /// own flutter_map "me" dot while this is on (ride_map.dart).
  final ValueListenable<bool>? showMe;

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

  /// Where MapKit draws what it is asked for ([MapKitFit]): as measured and
  /// seen to hold, and a correction being tried — asked for, and not yet seen
  /// to be obeyed.
  MapKitFit _fit = MapKitFit.exact;
  MapKitFit? _trial;
  MapKitFit get _asking => _trial ?? _fit;

  /// Waits for the camera to rest before asking MapKit where it drew it; and a
  /// camera MapKit would not be corrected at, not tried again while it rests
  /// there.
  Timer? _settle;
  MapCamera? _leftAlone;

  @override
  void initState() {
    super.initState();
    widget.route?.addListener(_redraw);
    widget.showMe?.addListener(_redraw);
    widget.annotations?.addListener(_redraw);
  }

  @override
  void didUpdateWidget(AppleNativeBaseLayer old) {
    super.didUpdateWidget(old);
    if (old.route != widget.route) {
      old.route?.removeListener(_redraw);
      widget.route?.addListener(_redraw);
    }
    if (old.showMe != widget.showMe) {
      old.showMe?.removeListener(_redraw);
      widget.showMe?.addListener(_redraw);
    }
    if (old.annotations != widget.annotations) {
      old.annotations?.removeListener(_redraw);
      widget.annotations?.addListener(_redraw);
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    widget.route?.removeListener(_redraw);
    widget.showMe?.removeListener(_redraw);
    widget.annotations?.removeListener(_redraw);
    super.dispose();
  }

  // The route moved, or the location dot turned on/off, without the camera
  // moving: redraw so MapKit picks it up.
  void _redraw() {
    if (mounted) setState(() {});
  }

  /// The route as MapKit's own polyline, or null when there is nothing to draw.
  Set<am.Polyline>? _polylines() {
    final r = widget.route?.value;
    if (r == null || r.points.length < 2) return null;
    return {
      am.Polyline(
        polylineId: am.PolylineId('route'),
        points: [for (final p in r.points) am.LatLng(p.latitude, p.longitude)],
        color: r.color,
        width: r.width,
      ),
    };
  }

  am.CameraPosition _position(MapCamera c) {
    // MapKit puts a camera's target in the middle of where it draws: the
    // ground the app shows there is the target to give it ([MapKitFit]).
    final at = _asking.drawn == null ? c.center : c.screenOffsetToLatLng(_asking.centreIn(c.nonRotatedSize));
    return am.CameraPosition(
      target: am.LatLng(at.latitude, at.longitude),
      zoom: c.zoom,
      // flutter_map turns the map clockwise by its rotation; Apple faces the
      // heading, turning the map the other way.
      heading: -c.rotation,
    );
  }

  /// The app's camera, moved to at once (no animation: the layers on top
  /// are already there).
  ///
  /// The plugin turns a zoom into a camera height by a rule of thumb, which
  /// leaves Apple's roads a little bigger or smaller than the app's route
  /// and pins on top, more so away from the centre. Unturned, the map is
  /// given the exact area the app shows instead ([MapKitFit.areaFor], which
  /// allows for where MapKit draws it); turned (heading up on a trip), the
  /// zoom is all there is.
  void _follow(MapCamera c) {
    final map = _map;
    if (map == null || _shown == c) return;
    final turned = (_shown?.rotation ?? 0) != 0;
    _shown = c;
    if (c.rotation != 0 || turned) {
      unawaited(map.moveCamera(am.CameraUpdate.newCameraPosition(_position(c))).catchError((_) {}));
    }
    if (c.rotation == 0) {
      final b = _asking.areaFor(c);
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
    // Once it has come to rest, see that MapKit drew it where the app did.
    _settle?.cancel();
    _settle = Timer(mapKitCheckAfter, _check);
  }

  /// Asks MapKit where it drew two points of the camera it was last given, and
  /// when that is not where the app draws them, asks it again for an area that
  /// allows for the difference ([MapKitFit.corrected]) — kept once the next
  /// reading shows MapKit drew that where it was told to, and dropped if not.
  /// North up and at rest only: a reading taken while the camera moves is of
  /// some other camera.
  Future<void> _check() async {
    final map = _map, c = _shown;
    if (!mounted || map == null || c == null || c.rotation != 0) return;
    if (c.zoom < mapKitCheckMinZoom || c.zoom > mapKitCheckMaxZoom) return;
    final size = c.nonRotatedSize;
    if (size.isEmpty) return;
    final app1 = Offset(size.width / 4, size.height / 4), app2 = Offset(size.width * 3 / 4, size.height * 3 / 4);
    final ground1 = c.screenOffsetToLatLng(app1), ground2 = c.screenOffsetToLatLng(app2);
    final Offset? mapKit1, mapKit2;
    try {
      mapKit1 = await map.getScreenCoordinate(am.LatLng(ground1.latitude, ground1.longitude));
      mapKit2 = await map.getScreenCoordinate(am.LatLng(ground2.latitude, ground2.longitude));
    } catch (_) {
      return;
    }
    // Moved on meanwhile: that move has a check of its own coming.
    if (!mounted || _map != map || _shown != c || mapKit1 == null || mapKit2 == null) return;
    final asking = _asking, trial = _trial;
    final read = asking.corrected(size, app1: app1, app2: app2, mapKit1: mapKit1, mapKit2: mapKit2);
    if (read == asking) {
      // Lined up. A correction on trial has been obeyed: it stands.
      if (trial != null) {
        _fit = trial;
        _trial = null;
      }
      return;
    }
    if (trial != null) {
      // Asked for the corrected area, MapKit still drew something else: it is
      // not to be corrected here. Back to what held before.
      _trial = null;
      _leftAlone = c;
      _shown = null;
      _follow(c);
      return;
    }
    if (read == null || _leftAlone == c) return;
    _trial = read;
    _shown = null;
    _follow(c);
  }

  /// The look last handed to MapKit (null: none yet for this map), and the
  /// one the setting asks for now.
  bool? _styled;
  bool _wanted = false;

  /// Tells MapKit to draw light or [dark] (ios/Runner/AppDelegate.swift's
  /// MapAppearancePlugin): left alone, it follows the phone.
  void _style(bool dark) {
    if (_map == null || _styled == dark) return;
    _styled = dark;
    unawaited(
      appleMapAppearanceChannel.invokeMethod<void>('set', {'style': dark ? 'dark' : 'light'}).catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!appleNativeSupported) return widget.fallback;
    final camera = MapCamera.of(context);
    final dark = _wanted = mapIsDark(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _follow(camera);
      _style(dark);
    });
    // Light or dark as Admin → Maps → Map appearance says (map_brightness.
    // dart): MapKit is told which, rather than following the phone. Imagery
    // is dark: the status bar over it goes by what is drawn.
    return MapStatusBarRegion(
      imagery: widget.type != 'roadmap',
      child: IgnorePointer(
        child: SizedBox.fromSize(
          size: camera.nonRotatedSize,
          child: am.AppleMap(
            initialCameraPosition: _position(camera),
            // MapKit draws the route itself, so it stays locked to the base
            // map while it pans (ride_map.dart hides its flutter_map line).
            polylines: _polylines() ?? const <am.Polyline>{},
            // The confirm map's marks, drawn by MapKit so they sit on its route
            // and roads (ride_map.dart hides its flutter_map marks).
            annotations: widget.annotations?.value ?? const <am.Annotation>{},
            onMapCreated: (c) {
              _map = c;
              _shown = null;
              _styled = null;
              _follow(MapCamera.of(context));
              _style(_wanted);
              // A map just created may not have its size yet (in a sheet
              // still sliding up): MapKit then fits the area to nothing and
              // stays far out. Once more when it has settled.
              Future<void>.delayed(const Duration(milliseconds: 400), () {
                if (!mounted || _map != c) return;
                _shown = null;
                _follow(MapCamera.of(this.context));
              });
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
            // MapKit draws the device's location dot itself, so it stays on the
            // real spot while the map pans (ride_map.dart hides its own dot).
            myLocationEnabled: widget.showMe?.value ?? false,
            myLocationButtonEnabled: false,
            // The whole view is the map: nothing set aside for the status bar
            // or the home indicator, which the app's own layers draw under too
            // ([MapKitFit]).
            padding: EdgeInsets.zero,
            insetsLayoutMarginsFromSafeArea: false,
          ),
        ),
      ),
    );
  }
}
