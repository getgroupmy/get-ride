import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/place_area_tabs.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/gate_picker.dart';
import 'package:get_ride/src/features/ride/pickup_guide_card.dart';
import 'package:latlong2/latlong.dart';

const _long = 'Lapangan Terbang Antarabangsa Kuala Lumpur, Balai Ketibaan Antarabangsa, Pintu 3';

const _gates = [
  AirportDoor(id: 'a', airportId: 'p', name: 'Lobby, Main entrance', kind: DoorKind.both, lat: 3.1100, lng: 101.6100),
  AirportDoor(
    id: 'b',
    airportId: 'p',
    name: 'Taxi bay, Level G',
    kind: DoorKind.pick,
    lat: 3.1104,
    lng: 101.6106,
    guide: [GuideStep(text: 'Walk to the taxi bay.'), GuideStep(text: 'Wait at the blue sign.')],
  ),
  AirportDoor(id: 'c', airportId: 'p', name: _long, kind: DoorKind.pick, lat: 3.1096, lng: 101.6094),
];

const _ring = [
  [LatLng(3.111, 101.609), LatLng(3.111, 101.611), LatLng(3.109, 101.611), LatLng(3.109, 101.609)],
];

Widget _app(Brightness b, Widget child) => MaterialApp(theme: appTheme(b), home: Scaffold(body: child));

Finder _wheelText(String wheel, int i) => find.byKey(ValueKey('$wheel-$i'));

void main() {
  for (final b in Brightness.values) {
    group('${b.name} mode', () {
      setUp(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.physicalSize = const Size(420, 900);
        binding.platformDispatcher.views.first.devicePixelRatio = 1;
      });
      tearDown(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.resetPhysicalSize();
        binding.platformDispatcher.views.first.resetDevicePixelRatio();
      });

      testWidgets('gate picker: map pins, wheel, tap a pin selects it, Done', (tester) async {
        final haptics = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
          return null;
        });
        GatePick? done;
        var closed = false;
        await tester.pumpWidget(
          _app(
            b,
            GatePickerSheet(
              placeName: 'Sunway Pyramid',
              gates: _gates,
              rings: _ring,
              selectedId: 'a',
              guides: true,
              tiles: false,
              onDone: (p) => done = p,
              onClose: () => closed = true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('gate-picker-title')), findsOneWidget);
        expect(find.text('Sunway Pyramid'), findsOneWidget);
        // One wheel (no groups), every gate a dot, the chosen one filled.
        expect(find.byKey(const ValueKey('gate-picker-groups')), findsNothing);
        for (final g in _gates) {
          expect(find.byKey(ValueKey('gate-dot-${g.id}')), findsOneWidget);
        }
        GateDot dot(String id) => tester.widget<GateDot>(
          find.descendant(of: find.byKey(ValueKey('gate-dot-$id')), matching: find.byType(GateDot)),
        );
        expect(dot('a').selected, isTrue);
        expect(dot('b').selected, isFalse);
        expect(dot('a').letter, 'A');
        expect(dot('c').letter, 'C');
        expect(
          find.descendant(of: find.byKey(const ValueKey('gate-picker-chip')), matching: find.text('Lobby, Main entrance')),
          findsOneWidget,
        );
        // Not required: Any gate is offered.
        expect(find.byKey(const ValueKey('gate-picker-any')), findsOneWidget);

        // Tapping a pin selects it: the dot fills, the chip and the wheel follow.
        await tester.tap(find.byKey(const ValueKey('gate-dot-b')));
        await tester.pumpAndSettle();
        expect(dot('b').selected, isTrue);
        expect(dot('a').selected, isFalse);
        expect(
          find.descendant(of: find.byKey(const ValueKey('gate-picker-chip')), matching: find.text('Taxi bay, Level G')),
          findsOneWidget,
        );
        expect(haptics, isNotEmpty);
        // B has a guide and the place shows guides.
        expect(find.byKey(const ValueKey('gate-picker-guide')), findsOneWidget);

        // Scrolling the wheel down a row picks the next gate (the long one,
        // wrapped and shown whole, not cut).
        await tester.drag(find.byKey(const ValueKey('gate-picker-gates-0')), const Offset(0, -46));
        await tester.pumpAndSettle();
        expect(dot('c').selected, isTrue);
        final chipText = tester.widget<Text>(
          find.descendant(of: find.byKey(const ValueKey('gate-picker-chip')), matching: find.byType(Text)),
        );
        expect(chipText.data, _long);
        expect(chipText.maxLines, isNull);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('gate-picker-done')));
        expect(done?.door?.id, 'c');

        await tester.tap(find.byKey(const ValueKey('gate-picker-close')));
        expect(closed, isTrue);
      });

      testWidgets('gate picker: required has no Any gate; groups get their own wheel', (tester) async {
        GatePick? done;
        final gates = [
          for (final g in _gates)
            AirportDoor(
              id: g.id,
              airportId: g.airportId,
              name: g.name,
              kind: g.kind,
              lat: g.lat,
              lng: g.lng,
              group: g.id == 'c' ? 'klia2' : 'KLIA',
            ),
        ];
        await tester.pumpWidget(
          _app(
            b,
            GatePickerSheet(
              placeName: _long,
              gates: gates,
              rings: _ring,
              required: true,
              tiles: false,
              onDone: (p) => done = p,
              onClose: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('gate-picker-any')), findsNothing);
        expect(find.byKey(const ValueKey('gate-picker-groups')), findsOneWidget);
        expect(_wheelText('gate-picker-groups', 0), findsOneWidget);
        expect(find.text('klia2'), findsOneWidget);

        // A pin in the other group turns both wheels to it.
        await tester.tap(find.byKey(const ValueKey('gate-dot-c')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('gate-picker-gates-1')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('gate-picker-done')));
        expect(done?.door?.id, 'c');
        expect(tester.takeException(), isNull);
      });

      testWidgets('gate callout: Pickup point over the gate, tap opens', (tester) async {
        var taps = 0;
        await tester.pumpWidget(_app(b, Center(child: GateCallout(name: _long, onTap: () => taps++))));
        expect(find.text('Pickup point'), findsOneWidget);
        expect(find.text(_long), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('gate-callout')));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('place editor: a switch dims its tool until on; no boundary, nothing works', (tester) async {
        var value = false;
        await tester.pumpWidget(
          _app(
            b,
            StatefulBuilder(
              builder: (context, set) => PlaceFeatureTab(
                switchKey: const ValueKey('place-switch-guide'),
                title: 'Pickup guide',
                subtitle: 'Step-by-step photos',
                value: value,
                onChanged: (v) => set(() => value = v),
                child: PlaceGuideTab(doors: _gates, onGuide: (_) {}),
              ),
            ),
          ),
        );
        double opacity() => tester
            .widget<AnimatedOpacity>(
              find.ancestor(of: find.byType(PlaceGuideTab), matching: find.byType(AnimatedOpacity)).first,
            )
            .opacity;
        IgnorePointer gate() => tester.widget<IgnorePointer>(
          find.ancestor(of: find.byType(PlaceGuideTab), matching: find.byType(IgnorePointer)).first,
        );
        expect(opacity(), lessThan(1));
        expect(gate().ignoring, isTrue);
        await tester.tap(find.byKey(const ValueKey('place-switch-guide')));
        await tester.pumpAndSettle();
        expect(value, isTrue);
        expect(opacity(), 1);
        expect(gate().ignoring, isFalse);
        expect(find.byKey(const ValueKey('place-guide-door-a')), findsOneWidget);

        // Without a boundary the switch can't be used.
        await tester.pumpWidget(
          _app(
            b,
            PlaceFeatureTab(
              switchKey: const ValueKey('place-switch-queue'),
              title: 'Driver waiting queue',
              subtitle: 'Off by default',
              value: true,
              enabled: false,
              onChanged: (_) => fail('switched without a boundary'),
              child: const SizedBox(),
            ),
          ),
        );
        expect(tester.widget<Switch>(find.byKey(const ValueKey('place-switch-queue'))).value, isFalse);
        expect(find.text('Switch the boundary on first (Boundary tab).'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('place-switch-queue')));
        expect(tester.takeException(), isNull);
      });

      testWidgets('place editor: the guide tab lists pickup doors', (tester) async {
        AirportDoor? opened;
        await tester.pumpWidget(_app(b, PlaceGuideTab(doors: _gates, onGuide: (d) => opened = d)));
        expect(find.byKey(const ValueKey('place-guide-door-a')), findsOneWidget);
        expect(find.text('2 steps'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('place-guide-edit-b')));
        expect(opened?.id, 'b');
      });
    });
  }

  test('the guide after booking: only with a guide, the area showing guides, before the trip', () {
    RideRequest ride(String status) => RideRequest({
      'id': 'r',
      'status': status,
      'pickup_door_id': 'b',
      'airport_pickup_id': 'p',
    });
    expect(pickupGuideDoor(ride('accepted'), _gates, const {})?.id, 'b');
    expect(pickupGuideDoor(ride('accepted'), _gates, {'p': const AirportSettings.place('p')}), isNull);
    expect(
      pickupGuideDoor(ride('arrived'), _gates, {'p': const AirportSettings.place('p').copyWith(guideOn: true)})?.id,
      'b',
    );
    expect(pickupGuideDoor(ride('on_trip'), _gates, const {}), isNull);
  });
}
