// The rider's gate picker on a phone, as TestFlight build 167 showed it
// broken at KLIA: the map, then nothing under it (no place name, no wheel,
// no Done), the map far out, and every piece of the airport outlined.
//
// The panel went because the map sat in a rounded clip: on an iPhone the map
// is Apple's own native view, and a rounded clip on a native view makes
// Flutter clip everything painted after it to that shape. These tests build
// the picker as on an iPhone (Apple's map as a native view) at iPhone sizes,
// light and dark, normal and large text, and check that the panel is there,
// that nothing outside the map is painted after the native view, that the
// map opens close in on the chosen gate, and that only one outline is drawn.
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as am;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/core/gate_snap.dart';
import 'package:get_ride/src/features/ride/gate_picker.dart';
import 'package:get_ride/src/widgets/apple_native_layer.dart';
import 'package:latlong2/latlong.dart';

const _veryLong =
    'Kuala Lumpur International Airport Terminal 1, Arrival Hall Level 3, Public Transport Pickup Bay, '
    'Door 7 beside the Information Counter';

AirportDoor _door(
  String id,
  String name,
  DoorKind kind, {
  double? lat,
  double? lng,
  String group = '',
  int guideSteps = 0,
  num sort = 9999,
}) => AirportDoor(
  id: id,
  airportId: 'klia',
  name: name,
  kind: kind,
  lat: lat,
  lng: lng,
  group: group,
  sortOrder: sort,
  guide: [for (var i = 0; i < guideSteps; i++) GuideStep(text: 'Step ${i + 1}')],
);

// KLIA-like: Terminal 1 and Terminal 2 a couple of kilometres apart, gates
// with and without a group, pickup and drop-off sides, one with no point.
final _doors = [
  for (var i = 0; i < 6; i++)
    _door(
      't1-$i',
      'T1 Pickup - Level ${i % 2 + 1}, Door ${i + 1}',
      i.isEven ? DoorKind.pick : DoorKind.both,
      lat: 2.7560 + i * 0.00015,
      lng: 101.7060 + i * 0.0001,
      group: 'KLIA T1',
      guideSteps: i == 3 ? 2 : 0,
      sort: i,
    ),
  for (var i = 0; i < 3; i++)
    _door(
      't2-$i',
      'T2 Pickup - Transportation Hub, Level ${i + 1}',
      DoorKind.pick,
      lat: 2.7440 + i * 0.00015,
      lng: 101.6860 + i * 0.0001,
      group: 'KLIA T2',
      sort: 10 + i,
    ),
  _door('x-long', _veryLong, DoorKind.pick, lat: 2.7570, lng: 101.7070, sort: 20),
  _door('x-nopoint', 'Meeting point (ask the counter)', DoorKind.both, sort: 21),
  _door('d-0', 'T1 Departures - Level 5, Door 2', DoorKind.drop, lat: 2.7565, lng: 101.7065, group: 'KLIA T1', sort: 30),
  _door('d-1', 'T2 Departures - Level 3, Door 1', DoorKind.drop, lat: 2.7445, lng: 101.6865, group: 'KLIA T2', sort: 31),
];

final _pickGates = doorsFor(_doors, 'klia', AirportSide.pick);
final _dropGates = doorsFor(_doors, 'klia', AirportSide.drop);

List<LatLng> _box(double s, double w, double n, double e) => [LatLng(n, w), LatLng(n, e), LatLng(s, e), LatLng(s, w)];

// The whole airport, Terminal 1, Terminal 2 and a runway: one area's pieces.
final _airport = _box(2.70, 101.65, 2.80, 101.75);
final _t1 = _box(2.7550, 101.7050, 2.7580, 101.7080);
final _t2 = _box(2.7430, 101.6850, 2.7460, 101.6880);
final _runway = _box(2.7200, 101.7100, 2.7800, 101.7150);
final _rings = [_airport, _t1, _t2, _runway];

const _sizes = [Size(390, 844), Size(430, 932)];

void _phone(WidgetTester tester, Size size, {double textScale = 1}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Apple's map as on an iPhone: a native view, its channels answered.
void _asIphone(WidgetTester tester) {
  debugAppleNativeSupported = true;
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform_views, (_) async => null);
  messenger.setMockMethodCallHandler(appleMapAppearanceChannel, (_) async => null);
  for (var id = 0; id < 64; id++) {
    messenger.setMockMethodCallHandler(MethodChannel('apple_maps_plugin.luisthein.de/apple_maps_$id'), (_) async => null);
  }
}

void _notIphone() {
  debugAppleNativeSupported = null;
  debugDefaultTargetPlatformOverride = null;
}

List<Object> _errors(WidgetTester tester) {
  final out = <Object>[];
  for (Object? e = tester.takeException(); e != null; e = tester.takeException()) {
    out.add(e);
  }
  return out;
}

/// The home screen behind, with the picker opened over it as the app does.
Future<Future<GatePick?>> _open(
  WidgetTester tester,
  Brightness b, {
  List<AirportDoor>? gates,
  String? selectedId = 't1-3',
  bool required = false,
  AirportSide side = AirportSide.pick,
  bool guides = true,
  String placeName = 'Kuala Lumpur International Airport (KLIA)',
}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(b),
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return const ColoredBox(color: Colors.teal, child: SizedBox.expand());
          },
        ),
      ),
    ),
  );
  final result = showGatePicker(
    ctx,
    placeName: placeName,
    gates: gates ?? _pickGates,
    rings: _rings,
    selectedId: selectedId,
    required: required,
    side: side,
    guides: guides,
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return result;
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('gate-picker-close')));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

/// Every render object under [root] in paint order (children in the order
/// their parent paints them).
List<RenderObject> _paintOrder(RenderObject root) {
  final out = <RenderObject>[];
  void walk(RenderObject o) {
    out.add(o);
    o.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// The two rules that keep the panel on screen over a native map.
void _expectNativeMapSafe(WidgetTester tester) {
  final native = tester.renderObject<RenderBox>(find.byType(UiKitView));
  final nativeRect = MatrixUtils.transformRect(native.getTransformTo(null), Offset.zero & native.size);

  // 1. No rounded (non-rect) clip around the native view.
  for (RenderObject? o = native.parent; o != null; o = o.parent) {
    expect(
      o is RenderClipRRect || o is RenderClipPath || o is RenderClipOval || o is RenderClipRSuperellipse,
      isFalse,
      reason: 'a ${o.runtimeType} around Apple\'s map clips the panel away on an iPhone',
    );
  }

  // 2. Nothing outside the map is painted after the native view.
  final sheet = tester.renderObject(find.byType(GatePickerSheet));
  final order = _paintOrder(sheet);
  final after = order.sublist(order.indexOf(native) + 1);
  for (final o in after) {
    if (o is! RenderParagraph && o is! RenderDecoratedBox && o is! RenderPhysicalShape && o is! RenderPhysicalModel) {
      continue;
    }
    final box = o as RenderBox;
    if (!box.hasSize || box.size.isEmpty) continue;
    final r = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    expect(
      nativeRect.inflate(1).contains(r.topLeft) && nativeRect.inflate(1).contains(r.bottomRight),
      isTrue,
      reason: '${o.runtimeType} at $r is painted after Apple\'s map ($nativeRect) but outside it',
    );
  }
}

/// The panel under the map: place name, close, the gate wheel, Done, and
/// Any gate unless [required]; all on screen and under the map.
void _expectPanel(WidgetTester tester, Size size, {required bool required, bool wheel = true}) {
  final view = Offset.zero & size;
  final map = _rect(tester, 'gate-picker-map-clip');
  final panel = _rect(tester, 'gate-picker-panel');
  expect(map.height, greaterThanOrEqualTo(size.height * 0.3), reason: 'the map keeps its share');
  expect(panel.top, moreOrLessEquals(map.bottom, epsilon: 0.5));
  expect(panel.bottom, lessThanOrEqualTo(size.height + 0.5));
  for (final key in [
    'gate-picker-title',
    'gate-picker-close',
    'gate-picker-done',
  ]) {
    expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    final r = _rect(tester, key);
    expect(view.contains(r.topLeft) && view.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue, reason: '$key at $r');
    expect(r.top, greaterThanOrEqualTo(map.bottom - 0.5), reason: '$key under the map');
  }
  // Any gate is the wheel's first row (it may be scrolled past), never a
  // separate button; a required place has none.
  if (required) expect(find.byKey(const ValueKey('gate-picker-any')), findsNothing);
  if (wheel) {
    final w = tester.getRect(find.byType(ListWheelScrollView).last);
    expect(w.top, lessThan(_rect(tester, 'gate-picker-done').top), reason: 'the wheel shows over Done');
    expect(w.top, greaterThanOrEqualTo(_rect(tester, 'gate-picker-close').bottom - 0.5));
  }
}

void main() {
  tearDown(_notIphone);

  group('on an iPhone (Apple\'s map, a native view)', () {
    for (final size in _sizes) {
      for (final b in Brightness.values) {
        for (final scale in const [1.0, 2.0]) {
          testWidgets('${size.width.toInt()}x${size.height.toInt()} ${b.name}, text x$scale: the panel shows', (
            tester,
          ) async {
            _phone(tester, size, textScale: scale);
            _asIphone(tester);
            try {
              await _open(tester, b);
              expect(_errors(tester), isEmpty);
              expect(find.byType(UiKitView), findsOneWidget);
              _expectNativeMapSafe(tester);
              _expectPanel(tester, size, required: false);
              // Grouped (T1, T2, Other): a wheel of groups beside the gates.
              expect(find.byKey(const ValueKey('gate-picker-groups')), findsOneWidget);
              // Apple's map opens close in, on the chosen gate.
              final apple = tester.widget<am.AppleMap>(find.byType(am.AppleMap));
              expect(apple.initialCameraPosition.zoom, gatePickerZoom);
              expect(apple.initialCameraPosition.target.latitude, closeTo(2.7560 + 3 * 0.00015, 1e-9));
              await _close(tester);
              expect(_errors(tester), isEmpty);
            } finally {
              _notIphone();
            }
          });
        }
      }
    }

    testWidgets('required, drop-off side, chosen gate gone, long names: the panel shows', (tester) async {
      for (final size in _sizes) {
        _phone(tester, size, textScale: 1.3);
        _asIphone(tester);
        try {
          await _open(
            tester,
            Brightness.dark,
            gates: _dropGates,
            selectedId: 'gone',
            required: true,
            side: AirportSide.drop,
            placeName: '$_veryLong $_veryLong',
          );
          expect(_errors(tester), isEmpty);
          _expectNativeMapSafe(tester);
          _expectPanel(tester, size, required: true);
          expect(find.text('Which gate are you going to?'), findsNothing, reason: 'inDrive: name, wheel, Done only');
          expect(find.byKey(const ValueKey('gate-picker-guide')), findsNothing);
          // The chosen gate is gone: it opens on the first, and Done works.
          expect(tester.widget<FilledButton>(find.byKey(const ValueKey('gate-picker-done'))).onPressed, isNotNull);
          await _close(tester);
        } finally {
          _notIphone();
        }
      }
    });

    testWidgets('no gates for the side: a line saying so, Any gate, no wheel, no error', (tester) async {
      _phone(tester, _sizes.first);
      _asIphone(tester);
      try {
        final result = await _open(tester, Brightness.light, gates: const [], selectedId: null, required: true);
        expect(_errors(tester), isEmpty);
        _expectNativeMapSafe(tester);
        expect(find.byKey(const ValueKey('gate-picker-empty')), findsOneWidget);
        expect(find.byType(ListWheelScrollView), findsNothing);
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('gate-picker-done'))).onPressed, isNull);
        expect(find.byKey(const ValueKey('gate-picker-title')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('gate-picker-any')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final pick = await result;
        expect(pick, isNotNull);
        expect(pick!.door, isNull);
      } finally {
        _notIphone();
      }
    });
  });

  group('the picker\'s own map', () {
    Widget sheet(Brightness b, {List<AirportDoor>? gates, String? selectedId = 't1-3', ValueChanged<GatePick>? onDone}) =>
        MaterialApp(
          theme: appTheme(b),
          home: Scaffold(
            body: GatePickerSheet(
              placeName: 'KLIA',
              gates: gates ?? _pickGates,
              rings: _rings,
              selectedId: selectedId,
              guides: true,
              tiles: false,
              onDone: onDone ?? (_) {},
              onClose: () {},
            ),
          ),
        );

    MapCamera camera(WidgetTester tester) => MapCamera.of(tester.element(find.byType(GateDot).first));

    List<Polygon> outlines(WidgetTester tester) => tester.widget<PolygonLayer>(find.byType(PolygonLayer)).polygons;

    for (final b in Brightness.values) {
      testWidgets('${b.name}: opens at street level on the chosen gate, and only its outline', (tester) async {
        _phone(tester, _sizes.last);
        await tester.pumpWidget(sheet(b));
        await tester.pumpAndSettle();
        expect(_errors(tester), isEmpty);
        expect(gatePickerZoom, inInclusiveRange(17.5, 18));
        expect(camera(tester).zoom, gatePickerZoom);
        expect(camera(tester).center.latitude, closeTo(2.7560 + 3 * 0.00015, 1e-9));
        expect(camera(tester).center.longitude, closeTo(101.7060 + 3 * 0.0001, 1e-9));
        // One outline: Terminal 1's, not the airport's, T2's and the runway's.
        expect(outlines(tester), hasLength(1));
        expect(outlines(tester).single.points, _t1);
        // Turning the wheel to Terminal 2 outlines Terminal 2 instead.
        await tester.drag(find.byKey(const ValueKey('gate-picker-groups')), const Offset(0, -46));
        await tester.pumpAndSettle();
        expect(outlines(tester).single.points, _t2);
        expect(_errors(tester), isEmpty);
      });
    }

    testWidgets('zoomed out by hand, the next gate brings it back to street level', (tester) async {
      _phone(tester, _sizes.first);
      await tester.pumpWidget(sheet(Brightness.light));
      await tester.pumpAndSettle();
      MapController.of(tester.element(find.byType(GateDot).first)).move(camera(tester).center, 13);
      await tester.pump();
      expect(camera(tester).zoom, 13);
      await tester.drag(find.byKey(const ValueKey('gate-picker-gates-0')), const Offset(0, -46));
      await tester.pumpAndSettle();
      expect(camera(tester).zoom, gatePickerZoom);
      expect(camera(tester).center.latitude, closeTo(2.7560 + 4 * 0.00015, 1e-9));
      expect(_errors(tester), isEmpty);
    });

    testWidgets('a chosen gate no longer listed: opens on the first gate with a point', (tester) async {
      _phone(tester, _sizes.first);
      GatePick? done;
      await tester.pumpWidget(sheet(Brightness.dark, selectedId: 'gone', onDone: (p) => done = p));
      await tester.pumpAndSettle();
      expect(camera(tester).center.latitude, closeTo(2.7560, 1e-9));
      await tester.tap(find.byKey(const ValueKey('gate-picker-done')));
      expect(done?.door?.id, 't1-0');
      expect(_errors(tester), isEmpty);
    });
  });

  group('ringsAround', () {
    test('the smallest piece holding the point', () {
      expect(ringsAround(_rings, const LatLng(2.7565, 101.7065)), [_t1]);
      expect(ringsAround(_rings, const LatLng(2.7445, 101.6865)), [_t2]);
      // In the airport but in no terminal: the airport's outline.
      expect(ringsAround(_rings, const LatLng(2.71, 101.66)), [_airport]);
    });

    test('outside every piece: the nearest; no point or one piece: all of them', () {
      expect(ringsAround([_t1, _t2], const LatLng(2.7600, 101.7060)), [_t1]);
      expect(ringsAround(_rings, null), _rings);
      expect(ringsAround([_t2], const LatLng(2.7600, 101.7060)), [_t2]);
      expect(ringsAround(const [], const LatLng(0, 0)), isEmpty);
      // A broken piece (under three corners) is never drawn.
      expect(ringsAround([_t1.take(2).toList(), _t2], null), [_t2]);
    });
  });
}
