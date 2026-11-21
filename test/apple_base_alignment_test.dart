// The app's own layers (the location dot, the pins, the route) are drawn over
// Apple's map, so they are only where they say if Apple's map shows exactly the
// area the app's camera shows (apple_native_layer.dart, [MapKitFit]).
//
// MapKit fits an area it is asked for into what it takes to be the visible
// part of its view, and for a full-screen map that leaves out the status bar
// and the home indicator: the map came out lower and smaller than the app drew
// over it. The dot and the pin then sat a fixed few points off Apple's roads —
// a few metres zoomed in, a street away zoomed out.
//
// A MapKit is stood in for here that does just that, and the app's camera is
// compared, point for point, with where it draws the ground.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/apple_native_layer.dart';
import 'package:latlong2/latlong.dart';

/// An iPhone with a Dynamic Island: 393 × 852 points, 59 kept clear at the top
/// and 34 at the bottom.
const _phone = Size(393, 852);
const _safeArea = EdgeInsets.only(top: 59, bottom: 34);

const _home = LatLng(2.9347, 101.8632);
const _crs = Epsg3857();

/// The world, flat, at a zoom fine enough to measure in.
Offset _flat(LatLng p) => _crs.latLngToOffset(p, 22);

/// How a stand-in MapKit fits an area into its view.
enum _Fits {
  /// As asked: into the whole view.
  whole,

  /// Into the part of the view inside its margins, shrunk to fit.
  insideMargins,

  /// At the size asked for, but centred inside its margins.
  centredInMargins,
}

/// MapKit, stood in for: it shows the area it was last asked for the way
/// [fits] says, and tells where on its view it draws a point of the ground.
class _MapKit {
  _MapKit(this.fits, {this.closest});

  _Fits fits;
  final EdgeInsets margins = _safeArea;
  final Size size = _phone;

  /// The zoom it will not go in past, when it has one: asked for less ground
  /// than that shows, it shows that much all the same.
  final double? closest;

  /// What the map was created with (the plugin's options).
  Map<Object?, Object?> options = const {};

  /// Every camera update it was sent.
  final moves = <List<Object?>>[];

  // The picture: [_centre] of the flat world drawn at [_at], [_scale] points
  // of screen to one of the flat world.
  Offset _centre = _flat(_home), _at = _phone.center(Offset.zero);
  double _scale = 1;

  /// Whether the view's margins follow the safe area (the plugin's
  /// `insetsLayoutMarginsFromSafeArea`, on unless switched off).
  bool get _marginsOn => options['insetsLayoutMarginsFromSafeArea'] != false;

  Rect get _visible => fits == _Fits.whole || !_marginsOn ? Offset.zero & size : margins.deflateRect(Offset.zero & size);

  void showArea(LatLng southwest, LatLng northeast) {
    final a = _flat(LatLng(northeast.latitude, southwest.longitude)), b = _flat(LatLng(southwest.latitude, northeast.longitude));
    final area = Rect.fromPoints(a, b);
    final visible = _visible;
    final into = fits == _Fits.centredInMargins ? size : visible.size;
    _scale = math.min(into.width / area.width, into.height / area.height);
    if (closest case final z?) _scale = math.min(_scale, math.pow(2, z - 22).toDouble());
    _centre = area.center;
    _at = visible.center;
  }

  Offset pointOf(LatLng p) => _at + (_flat(p) - _centre) * _scale;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'camera#move':
        final update = (call.arguments as Map)['cameraUpdate'] as List<Object?>;
        moves.add(update);
        if (update.first == 'newLatLngBounds') {
          final corners = update[1]! as List<Object?>;
          final sw = corners[0]! as List<Object?>, ne = corners[1]! as List<Object?>;
          showArea(LatLng(sw[0]! as double, sw[1]! as double), LatLng(ne[0]! as double, ne[1]! as double));
        }
        return null;
      case 'camera#convert':
        final at = (call.arguments as Map)['annotation'] as List<Object?>;
        final p = pointOf(LatLng(at[0]! as double, at[1]! as double));
        return {
          'point': [p.dx, p.dy],
        };
    }
    return null;
  }
}

MapCamera _camera(double zoom, {LatLng at = _home, Size size = _phone}) =>
    MapCamera(crs: _crs, center: at, zoom: zoom, rotation: 0, nonRotatedSize: size);

/// The furthest, in points of the screen, that [mapKit] draws any point of
/// the ground from where [c] draws it, over the whole view.
double _worstApart(MapCamera c, _MapKit mapKit) {
  var worst = 0.0;
  for (var x = 0.0; x <= 1; x += 0.125) {
    for (var y = 0.0; y <= 1; y += 0.125) {
      final onScreen = Offset(c.nonRotatedSize.width * x, c.nonRotatedSize.height * y);
      worst = math.max(worst, (mapKit.pointOf(c.screenOffsetToLatLng(onScreen)) - onScreen).distance);
    }
  }
  return worst;
}

/// Metres on the ground to a point of the screen at [zoom], at this latitude.
double _metresAPoint(double zoom) => 156543.03392 * math.cos(_home.latitude * math.pi / 180) / math.pow(2, zoom);

/// One check, as the layer makes it: MapKit shows what [fit] asks for [c], is
/// asked where it drew two points, and the fit is corrected by its answer.
MapKitFit _checked(MapKitFit fit, MapCamera c, _MapKit mapKit) {
  final area = fit.areaFor(c);
  mapKit.showArea(area.southWest, area.northEast);
  final size = c.nonRotatedSize;
  final app1 = Offset(size.width / 4, size.height / 4), app2 = Offset(size.width * 3 / 4, size.height * 3 / 4);
  return fit.corrected(
    size,
    app1: app1,
    app2: app2,
    mapKit1: mapKit.pointOf(c.screenOffsetToLatLng(app1)),
    mapKit2: mapKit.pointOf(c.screenOffsetToLatLng(app2)),
  )!;
}

void main() {
  group('what went wrong', () {
    test('a full-screen map with margins for the safe area draws the ground off where the app does', () {
      // Where the home map keeps the pickup pin: well above the middle.
      const pin = Offset(196.5, 180);
      for (final fits in [_Fits.insideMargins, _Fits.centredInMargins]) {
        final mapKit = _MapKit(fits);
        final metres = <double, double>{};
        for (final zoom in [19.5, 17.0, 15.0]) {
          final c = _camera(zoom);
          final area = c.visibleBounds;
          mapKit.showArea(area.southWest, area.northEast);
          final off = (mapKit.pointOf(c.screenOffsetToLatLng(pin)) - pin).distance;
          expect(off, greaterThan(10), reason: '$fits at zoom $zoom: the same on the screen at any zoom');
          metres[zoom] = off * _metresAPoint(zoom);
        }
        // The same few points are a few metres zoomed in and a street zoomed out.
        expect(metres[19.5], lessThan(12), reason: '$fits: "in the right position" zoomed in');
        expect(metres[15.0], greaterThan(50), reason: '$fits: "looks off" zoomed out');
      }
    });
  });

  group('MapKitFit', () {
    test('MapKit drawing what it is asked: nothing to correct, and the same area asked for as before', () {
      final mapKit = _MapKit(_Fits.whole);
      final c = _camera(17);
      // The area the camera shows (to the pixel: `visibleBounds` rounds its centre to one).
      final asked = MapKitFit.exact.areaFor(c), shown = c.visibleBounds;
      expect(asked.north, closeTo(shown.north, 1e-5));
      expect(asked.south, closeTo(shown.south, 1e-5));
      expect(asked.west, closeTo(shown.west, 1e-5));
      expect(asked.east, closeTo(shown.east, 1e-5));
      expect(_checked(MapKitFit.exact, c, mapKit), MapKitFit.exact);
      expect(_worstApart(c, mapKit), lessThan(0.01));
    });

    for (final fits in [_Fits.insideMargins, _Fits.centredInMargins]) {
      test('$fits: one reading puts every point of the ground where the app draws it, at any zoom', () {
        final mapKit = _MapKit(fits);
        final first = _camera(17);
        final area = first.visibleBounds;
        mapKit.showArea(area.southWest, area.northEast);
        expect(_worstApart(first, mapKit), greaterThan(10), reason: 'off before it is measured');

        // The one reading.
        final fit = _checked(MapKitFit.exact, first, mapKit);
        expect(fit.drawn, isNotNull);
        // A second finds nothing left to correct.
        expect(_checked(fit, first, mapKit), fit);

        // What was learnt at one camera holds for every other: zoomed in and
        // out, and somewhere else altogether.
        for (final c in [_camera(19.7), _camera(17), _camera(15.2), _camera(13), _camera(16.4, at: const LatLng(3.1579, 101.7116))]) {
          final asked = fit.areaFor(c);
          mapKit.showArea(asked.southWest, asked.northEast);
          expect(_worstApart(c, mapKit), lessThan(0.01), reason: 'zoom ${c.zoom}');
        }
      });
    }

    test('where MapKit draws the middle of what it is asked: the middle of the part it draws into', () {
      expect(MapKitFit.exact.centreIn(_phone), _phone.center(Offset.zero));
      final fit = _checked(MapKitFit.exact, _camera(17), _MapKit(_Fits.insideMargins));
      // Halfway between the status bar and the home indicator: 12.5 points
      // below the middle of the screen.
      expect(fit.centreIn(_phone).dx, closeTo(196.5, 0.01));
      expect(fit.centreIn(_phone).dy, closeTo(426 + 12.5, 0.01));
    });

    test('a reading that cannot be right teaches nothing', () {
      const app1 = Offset(98, 213), app2 = Offset(295, 639);
      MapKitFit? read(Offset mapKit1, Offset mapKit2) =>
          MapKitFit.exact.corrected(_phone, app1: app1, app2: app2, mapKit1: mapKit1, mapKit2: mapKit2);
      // Agreeing to within half a point: lined up, nothing to change.
      expect(read(app1 + const Offset(0.2, -0.3), app2 + const Offset(-0.1, 0.4)), MapKitFit.exact);
      // Not laid out yet: everything at the corner.
      expect(read(Offset.zero, Offset.zero), isNull);
      expect(read(const Offset(double.nan, 0), app2), isNull);
      // Held at the end of its zoom: far bigger or smaller than asked.
      expect(read(app1 * 2, app2 * 2), isNull);
      expect(read(app1 * 0.5, app2 * 0.5), isNull);
      // Stretched one way and not the other.
      expect(read(app1, Offset(app2.dx, app2.dy * 1.1)), isNull);
      // Half a screen away.
      expect(read(app1 + const Offset(0, 500), app2 + const Offset(0, 500)), isNull);
    });
  });

  group('the layer', () {
    late _MapKit mapKit;
    late MapController controller;

    setUp(() {
      debugAppleNativeSupported = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      controller = MapController();
    });

    /// A map the size of the phone over the stand-in MapKit.
    Future<void> pump(WidgetTester tester, _Fits fits, {double zoom = 17, double? closest}) async {
      mapKit = _MapKit(fits, closest: closest);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = _phone;
      addTearDown(tester.view.reset);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // The native view: MapKit comes up with the options the app gave it.
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
        if (call.method == 'create') {
          final args = call.arguments as Map;
          final params = const StandardMessageCodec().decodeMessage(ByteData.sublistView(args['params'] as Uint8List)) as Map;
          mapKit.options = params['options'] as Map<Object?, Object?>;
          messenger.setMockMethodCallHandler(
            MethodChannel('apple_maps_plugin.luisthein.de/apple_maps_${args['id']}'),
            mapKit.handle,
          );
        }
        return null;
      });
      messenger.setMockMethodCallHandler(appleMapAppearanceChannel, (call) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        messenger.setMockMethodCallHandler(appleMapAppearanceChannel, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FlutterMap(
            mapController: controller,
            options: MapOptions(initialCenter: _home, initialZoom: zoom),
            children: const [AppleNativeBaseLayer(fallback: SizedBox.shrink())],
          ),
        ),
      );
      // The map is created, and given the camera once more when it has its size.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
    }

    /// Lets the camera rest long enough to be checked, and the check answer.
    Future<void> rest(WidgetTester tester) async {
      await tester.pump(mapKitCheckAfter + const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(mapKitCheckAfter + const Duration(milliseconds: 50));
      await tester.pump();
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      debugAppleNativeSupported = null;
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets('MapKit is told to keep no margins for the safe area: the whole view is the map', (tester) async {
      await pump(tester, _Fits.insideMargins);
      expect(mapKit.options['insetsLayoutMarginsFromSafeArea'], isFalse);
      expect(mapKit.options['padding'], [0.0, 0.0, 0.0, 0.0]);
      // A MapKit that does as it is told draws the ground where the app does
      // from the first, with nothing to correct after.
      expect(_worstApart(controller.camera, mapKit), lessThan(1.0));
      final sent = mapKit.moves.length;
      await rest(tester);
      expect(mapKit.moves, hasLength(sent), reason: 'checked, found right, left alone');
      for (final zoom in [19.5, 15.0, 13.0]) {
        controller.move(_home, zoom);
        await tester.pump();
        await tester.pump();
        expect(_worstApart(controller.camera, mapKit), lessThan(1.0), reason: 'zoom $zoom');
      }
      await done(tester);
    });

    for (final fits in [_Fits.insideMargins, _Fits.centredInMargins]) {
      testWidgets('a MapKit that keeps its margins all the same ($fits) is measured, and allowed for', (tester) async {
        await pump(tester, fits);
        // As if the option did nothing: its margins stay.
        mapKit.options = const {};
        controller.move(_home, 17.01);
        await tester.pump();
        await tester.pump();
        expect(_worstApart(controller.camera, mapKit), greaterThan(10), reason: 'off, as it was on the phone');

        await rest(tester);
        expect(_worstApart(controller.camera, mapKit), lessThan(1.0), reason: 'measured at rest, and put right');

        // From then on it is right as the map moves: zoomed out, zoomed in,
        // dragged away — at once, not only after the next rest.
        for (final (at, zoom) in [(_home, 15.0), (_home, 19.5), (const LatLng(2.94, 101.87), 16.3), (_home, 13.0)]) {
          controller.move(at, zoom);
          await tester.pump();
          await tester.pump();
          expect(_worstApart(controller.camera, mapKit), lessThan(1.0), reason: 'zoom $zoom');
        }
        final sent = mapKit.moves.length;
        await rest(tester);
        expect(mapKit.moves, hasLength(sent), reason: 'nothing more to correct');
        await done(tester);
      });
    }

    testWidgets('zoomed in as far as MapKit goes, it shows more than it is asked: not taken for a margin', (tester) async {
      // A MapKit that does as it is told, but will not go in past zoom 18.6.
      await pump(tester, _Fits.whole, closest: 18.6);
      expect(_worstApart(controller.camera, mapKit), lessThan(0.01));

      // Zoomed in past where it stops, and left there: it shows more ground
      // than the app does, and no asking changes that.
      controller.move(_home, 18.9);
      await tester.pump();
      await tester.pump();
      expect(_worstApart(controller.camera, mapKit), greaterThan(10));
      await rest(tester);
      await rest(tester);
      expect(_worstApart(controller.camera, mapKit), greaterThan(10), reason: 'it cannot be made to');

      // Zoomed back out: right at once — nothing wrong was learnt from that.
      for (final zoom in [17.0, 15.0]) {
        controller.move(_home, zoom);
        await tester.pump();
        await tester.pump();
        expect(_worstApart(controller.camera, mapKit), lessThan(0.01), reason: 'zoom $zoom');
      }
      await done(tester);
    });

    testWidgets('no reading is taken while the map is on the move', (tester) async {
      await pump(tester, _Fits.insideMargins);
      mapKit.options = const {};
      // Dragged about for a second, a move every 100 ms: never at rest.
      for (var i = 0; i < 10; i++) {
        controller.move(LatLng(_home.latitude + i * 0.0001, _home.longitude), 17);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        mapKit.moves.where((m) => m.first == 'newLatLngBounds').length,
        lessThanOrEqualTo(13),
        reason: 'one area a move (and the two as the map came up): none re-sent as a correction',
      );
      await rest(tester);
      expect(_worstApart(controller.camera, mapKit), lessThan(1.0), reason: 'once it stops, it is measured');
      await done(tester);
    });
  });
}
