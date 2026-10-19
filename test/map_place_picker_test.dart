// Choose on map: while a dragged spot is being named the last name stays,
// greyed, with a small spinner; a dot on the ground marks the exact point;
// Done is dimmed with "Finding address…" under it; "Use my location" moves
// the pin onto the phone's fix.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/ride/map_place_picker.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _start = LatLng(2.9300, 101.8300);
const _here = LatLng(3.1579, 101.7116);

/// A geocoder that answers when told: the first spot is "Spot 1", the next
/// "Spot 2", and so on.
class _Geo extends GeoService {
  _Geo() : super(client: MockClient((_) async => http.Response('', 500)));

  final pending = <Completer<void>>[];
  final asked = <LatLng>[];
  var held = false;

  @override
  Future<Place> reverse(LatLng p) async {
    asked.add(p);
    final n = asked.length;
    if (held) {
      final c = Completer<void>();
      pending.add(c);
      await c.future;
    }
    return Place(name: 'Spot $n', address: 'Semenyih', point: p);
  }
}

Future<_Geo> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Future<LatLng?> Function()? position,
  LatLng? me,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 915);
  addTearDown(tester.view.reset);
  final geo = _Geo();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      geoServiceProvider.overrideWithValue(geo),
      pickerPositionProvider.overrideWithValue(position ?? () async => null),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MapPlacePicker(start: _start, me: me),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return geo;
}

MapCamera _camera(WidgetTester tester) => MapCamera.of(tester.element(find.byKey(const ValueKey('map-picker-credit'))));

FilledButton _done(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const ValueKey('map-picker-done')));

void main() {
  for (final b in Brightness.values) {
    testWidgets('while a dragged spot is looked up, the last name stays greyed with a spinner (${b.name})',
        (tester) async {
      final geo = await _pump(tester, brightness: b);
      expect(find.text('Spot 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-picker-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-picker-looking')), findsNothing);
      expect(_done(tester).onPressed, isNotNull);
      final caption = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('map-picker-caption')), matching: find.byType(AnimatedOpacity)),
      );
      expect(caption.opacity, 0, reason: 'nothing to explain once the spot is named');

      // The ground dot sits on the exact point: the middle of the map.
      final map = tester.getRect(find.byType(FlutterMap));
      final ground = tester.getCenter(find.byKey(const ValueKey('map-picker-ground')));
      expect((ground - map.center).distance, lessThan(0.5));

      // Drag, and hold the lookup.
      geo.held = true;
      await tester.drag(find.byType(FlutterMap), const Offset(-120, 80));
      await tester.pump();
      expect(find.text('Spot 1'), findsOneWidget, reason: 'the last name stays while the map moves');
      expect(find.byKey(const ValueKey('map-picker-name-stale')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-picker-looking')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-picker-ground')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(geo.asked, hasLength(2), reason: 'the settled spot is looked up');
      await tester.pump(const Duration(milliseconds: 200));

      // Still looking: greyed name, inline spinner, dimmed Done with a caption.
      expect(find.text('Spot 1'), findsOneWidget);
      final stale = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('map-picker-name-stale')), matching: find.byType(AnimatedOpacity)),
      );
      expect(stale.opacity, lessThan(1));
      expect(find.byKey(const ValueKey('map-picker-looking')), findsOneWidget);
      expect(_done(tester).onPressed, isNull);
      expect(find.text(MapPlacePicker.findingCaption), findsOneWidget);
      final under = tester.getRect(find.byKey(const ValueKey('map-picker-caption')));
      expect(under.top, greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('map-picker-done'))).bottom),
          reason: 'the caption sits under Done');
      expect(under.bottom, lessThanOrEqualTo(915));

      // Named: the new name, Done back on, no caption.
      geo.pending.single.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Spot 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-picker-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-picker-looking')), findsNothing);
      expect(find.text(MapPlacePicker.findingCaption), findsNothing);
      expect(_done(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Use my location" moves the pin onto the fix and names it (${b.name})', (tester) async {
      final geo = await _pump(tester, brightness: b, position: () async => _here);
      expect(find.text('Use my location'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-recenter')), findsNothing, reason: 'one my-location control, not two');
      // Clear of the map credit and of Done.
      final button = tester.getRect(find.byKey(const ValueKey('map-picker-my-location')));
      expect(button.bottom, lessThan(tester.getRect(find.byKey(const ValueKey('map-picker-done'))).top));
      final credit = tester.getRect(find.byIcon(Icons.info_outlined)).inflate(12);
      expect(button.overlaps(credit), isFalse, reason: 'the map credit stays reachable');
      expect(button.right, lessThanOrEqualTo(412 - 16));

      await tester.tap(find.byKey(const ValueKey('map-picker-my-location')));
      await tester.pump();
      await tester.pump();
      expect(const Distance()(_camera(tester).center, _here), lessThan(1));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(const Distance()(geo.asked.last, _here), lessThan(1));
      expect(find.text('Spot 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('with no fix, "Use my location" falls back to where the picker opened from, else says why',
      (tester) async {
    await _pump(tester, me: _here);
    await tester.tap(find.byKey(const ValueKey('map-picker-my-location')));
    await tester.pump();
    await tester.pump();
    expect(const Distance()(_camera(tester).center, _here), lessThan(1));

    await tester.pumpWidget(const SizedBox());
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('map-picker-my-location')));
    await tester.pump();
    await tester.pump();
    expect(find.text(MapPlacePicker.noFixMessage), findsOneWidget);
    expect(const Distance()(_camera(tester).center, _start), lessThan(1));
  });
}
