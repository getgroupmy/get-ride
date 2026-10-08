import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/map_drag_pin.dart';
import 'package:get_ride/src/widgets/map_sheet_layout.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

const start = LatLng(3.1340, 101.6860);

class _Host extends StatefulWidget {
  const _Host({required this.map, required this.drops, this.pinKey});
  final MapController map;
  final List<LatLng> drops;
  final Key? pinKey;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  LatLng pickup = start;
  bool moving = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: MapDragPin(
        key: widget.pinKey,
        controller: widget.map,
        pin: pickup,
        onMoving: (v) => setState(() => moving = v),
        onDropped: (p) {
          widget.drops.add(p);
          setState(() => pickup = p);
        },
        child: RideMap(
          controller: widget.map,
          pickup: pickup,
          showPickup: !moving,
          autoFit: false,
          extraMarkers: [
            if (!moving) labelAbovePin(pickup, const SizedBox(key: ValueKey('box'), width: 200, height: 50)),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('dragging the map lifts the pin, hides the box, and drops it on a new pickup', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final map = MapController();
    addTearDown(map.dispose);
    final drops = <LatLng>[];
    await tester.pumpWidget(_Host(map: map, drops: drops));
    await tester.pump();

    final pinRect = tester.getRect(find.byType(PickupPin));
    expect(find.byKey(const ValueKey('box')), findsOneWidget);

    // Hold the map and move it slowly, so it doesn't fling.
    final g = await tester.startGesture(const Offset(200, 600));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-8, -10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));

    // Lifted: one pin only (the floating one), raised above its point, and
    // no address box; held down, it hasn't dropped yet.
    expect(find.byKey(const ValueKey('drag-pin')), findsOneWidget);
    expect(find.byType(PickupPin), findsOneWidget);
    expect(find.byKey(const ValueKey('box')), findsNothing);
    final lifted = tester.getRect(find.byType(PickupPin));
    expect(lifted.left, closeTo(pinRect.left, 0.5), reason: 'the pin stays put while the map moves');
    expect(pinRect.top - lifted.top, closeTo(MapDragPin.lift, 0.5));
    expect(drops, isEmpty);

    await g.up();
    await tester.pump(const Duration(milliseconds: 250));
    expect(drops, hasLength(1));
    // The map moved up-left under a still pin: the pickup is down-right of where it was.
    expect(drops.single.latitude, lessThan(start.latitude));
    expect(drops.single.longitude, greaterThan(start.longitude));

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('drag-pin')), findsNothing);
    expect(find.byKey(const ValueKey('box')), findsOneWidget);
    // Landed where the floating pin stood, so the map's own pin takes over without a jump.
    expect(tester.getRect(find.byType(PickupPin)).topLeft, offsetMoreOrLessEquals(pinRect.topLeft, epsilon: 1));
  });

  testWidgets('moving the map from code does not pick the pin up', (tester) async {
    final map = MapController();
    addTearDown(map.dispose);
    final drops = <LatLng>[];
    await tester.pumpWidget(_Host(map: map, drops: drops));
    await tester.pump();
    map.move(const LatLng(3.2, 101.7), 15);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('drag-pin')), findsNothing);
    expect(drops, isEmpty);
  });

  testWidgets('the recenter button drops the pin on the fix: it floats up, then lands there', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final map = MapController();
    addTearDown(map.dispose);
    final drops = <LatLng>[];
    final pin = GlobalKey<MapDragPinState>();
    await tester.pumpWidget(_Host(map: map, drops: drops, pinKey: pin));
    await tester.pump();
    const here = LatLng(3.2, 101.7);
    map.move(here, 15);
    await tester.pump();
    pin.currentState!.dropAt(here);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('drag-pin')), findsOneWidget, reason: 'lifted');
    expect(drops, isEmpty);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(drops, [here]);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('drag-pin')), findsNothing, reason: 'landed');
    expect(find.byKey(const ValueKey('box')), findsOneWidget);
  });

  testWidgets('a hidden sheet slides out of sight below the screen and back', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    Widget host(bool hidden) => MaterialApp(
      home: Scaffold(
        body: MapSheetLayout(
          map: const SizedBox.expand(),
          sheet: const SizedBox(key: ValueKey('body'), height: 400),
          min: 0.22,
          initial: 0.22,
          hidden: hidden,
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    final shown = tester.getRect(find.byKey(const ValueKey('map-sheet-handle'))).top;
    expect(shown, lessThan(800));
    await tester.pumpWidget(host(true));
    await tester.pump(MapSheetLayout.hideDuration);
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('map-sheet-handle'))).top, greaterThan(800));
    await tester.pumpWidget(host(false));
    await tester.pump(MapSheetLayout.hideDuration);
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('map-sheet-handle'))).top, closeTo(shown, 0.5));
  });

  testWidgets('the map credit slides down off the map and hides while the map is dragged, then returns', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    Widget host(bool hidden) => MaterialApp(
      home: Scaffold(
        body: MapSheetLayout(
          map: RideMap(me: const LatLng(3.15, 101.71), hideCredit: hidden),
          sheet: const SizedBox(height: 400),
          min: 0.22,
          initial: 0.22,
          hidden: hidden,
        ),
      ),
    );
    final info = find.byIcon(Icons.info_outlined);
    await tester.pumpWidget(host(false));
    final shown = tester.getRect(info).top;
    expect(shown, lessThan(800 * (1 - 0.22)), reason: 'above the sheet');
    await tester.pumpWidget(host(true));
    await tester.pump(MapSheetLayout.hideDuration);
    await tester.pump();
    expect(tester.getRect(info).top, greaterThan(800), reason: 'down off the map with the sheet');
    final fade = tester.widget<Opacity>(
      find.ancestor(of: find.byKey(const ValueKey('map-credit')), matching: find.byType(Opacity)).first,
    );
    expect(fade.opacity, 0);
    await tester.pumpWidget(host(false));
    await tester.pump(MapSheetLayout.hideDuration);
    await tester.pump();
    expect(tester.getRect(info).top, closeTo(shown, 0.5));
  });
}
