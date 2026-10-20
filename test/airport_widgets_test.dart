import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/service_order_screen.dart';
import 'package:get_ride/src/admin/screens/geo/airport_tabs.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/data/airport_repository.dart' show AirportZone;
import 'package:get_ride/src/features/partner/airport_queue_card.dart';
import 'package:get_ride/src/features/ride/airport_door_sheet.dart';

const _doors = [
  AirportDoor(
    id: 'd2',
    airportId: 'a',
    name: 'Terminal 1 Arrivals, Door 3',
    kind: DoorKind.pick,
    guide: [
      GuideStep(text: 'After baggage claim, turn right.'),
      GuideStep(text: 'Take the escalator down to Level 1.'),
      GuideStep(text: 'Go out through Door 3.'),
    ],
  ),
  AirportDoor(
    id: 'd3',
    airportId: 'a',
    name: 'klia2 Arrivals, Door 2',
    kind: DoorKind.both,
  ),
];

Widget _app(Brightness b, Widget child) => MaterialApp(
  theme: appTheme(b),
  home: Scaffold(body: child),
);

void main() {
  for (final b in Brightness.values) {
    group('${b.name} mode', () {
      setUp(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.physicalSize = const Size(
          900,
          2400,
        );
        binding.platformDispatcher.views.first.devicePixelRatio = 1;
      });
      tearDown(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.resetPhysicalSize();
        binding.platformDispatcher.views.first.resetDevicePixelRatio();
      });
      testWidgets(
        'rider pickup door sheet: doors, guide link, charge, confirm',
        (tester) async {
          AirportDoor? chosen;
          await tester.pumpWidget(
            _app(
              b,
              SingleChildScrollView(
                child: AirportDoorSheet(
                  airportName: 'KL International Airport',
                  side: AirportSide.pick,
                  doors: _doors,
                  charge: const AirportCharge(
                    on: true,
                    name: 'Airport pickup fee',
                    amount: 6,
                  ),
                  onDone: (d) => chosen = d,
                ),
              ),
            ),
          );
          expect(
            find.text('Where should the driver pick you up?'),
            findsOneWidget,
          );
          expect(
            find.text('KL International Airport · pickup'),
            findsOneWidget,
          );
          expect(find.text('How to get there · 3 steps ›'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('airport-door-charge')),
            findsOneWidget,
          );
          expect(find.textContaining('6.00'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('airport-door-confirm')),
                )
                .onPressed,
            isNull,
          );
          await tester.tap(find.byKey(const ValueKey('airport-door-d3')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('airport-door-confirm')));
          expect(chosen?.id, 'd3');
        },
      );

      testWidgets('rider drop-off door sheet asks which door, without guides', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(
            b,
            SingleChildScrollView(
              child: AirportDoorSheet(
                airportName: 'KLIA',
                side: AirportSide.drop,
                doors: const [
                  AirportDoor(
                    id: 'd1',
                    airportId: 'a',
                    name: 'Departures, Door 5',
                    kind: DoorKind.drop,
                  ),
                ],
                onDone: (_) {},
              ),
            ),
          ),
        );
        expect(find.text('Which door are you going to?'), findsOneWidget);
        expect(find.text('Confirm drop-off'), findsOneWidget);
        expect(find.textContaining('How to get there'), findsNothing);
        expect(find.byKey(const ValueKey('airport-door-charge')), findsNothing);
      });

      testWidgets(
        'guide viewer: steps, Back / Next, "Pick up here" chooses the door',
        (tester) async {
          AirportDoor? chosen;
          await tester.pumpWidget(
            _app(
              b,
              SingleChildScrollView(
                child: AirportDoorSheet(
                  airportName: 'KLIA',
                  side: AirportSide.pick,
                  doors: _doors,
                  onDone: (d) => chosen = d,
                ),
              ),
            ),
          );
          await tester.tap(find.byKey(const ValueKey('airport-guide-d2')));
          await tester.pump();
          expect(find.text('Step 1 of 3'), findsOneWidget);
          expect(find.text('After baggage claim, turn right.'), findsOneWidget);
          expect(
            tester
                .widget<OutlinedButton>(
                  find.byKey(const ValueKey('airport-guide-prev')),
                )
                .onPressed,
            isNull,
          );
          await tester.tap(find.byKey(const ValueKey('airport-guide-next')));
          await tester.pump();
          expect(find.text('Step 2 of 3'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('airport-guide-prev')));
          await tester.pump();
          expect(find.text('Step 1 of 3'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('airport-guide-next')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('airport-guide-next')));
          await tester.pump();
          expect(find.text('Step 3 of 3'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('airport-guide-next')),
            findsNothing,
          );
          await tester.tap(find.byKey(const ValueKey('airport-guide-done')));
          await tester.pump();
          // Back on the doors, with this one chosen.
          expect(
            find.text('Where should the driver pick you up?'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('airport-door-confirm')));
          expect(chosen?.id, 'd2');
        },
      );

      testWidgets(
        'admin pickup rules: restrict, sources, empty action, nearby minutes',
        (tester) async {
          var s = const AirportSettings(airportId: 'a');
          await tester.pumpWidget(
            _app(
              b,
              StatefulBuilder(
                builder: (_, set) => AirportRulesTab(
                  settings: s,
                  onChanged: (v) => set(() => s = v),
                ),
              ),
            ),
          );
          expect(
            find.text(
              'Who gets a pickup inside the airport (pick one or both)',
            ),
            findsNothing,
          );
          await tester.tap(find.byType(Switch).first);
          await tester.pump();
          expect(s.restrictPickups, isTrue);
          await tester.tap(find.byKey(const ValueKey('airport-from-zone')));
          await tester.pump();
          expect(s.pickupFrom, {PickupSource.queue, PickupSource.zone});
          expect(
            find.textContaining('Both: the queue is offered first'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('airport-from-queue')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('airport-from-zone')));
          await tester.pump();
          expect(s.pickupFrom, {
            PickupSource.zone,
          }, reason: 'the last source stays on');
          await tester.tap(find.byKey(const ValueKey('airport-empty-nearby')));
          await tester.pump();
          expect(s.emptyAction, EmptyAction.nearby);
          await tester.tap(find.byTooltip('Lower nearby wait'));
          await tester.pump();
          expect(s.nearbyAfterMin, 4);
        },
      );

      testWidgets(
        'admin waiting queue: zones with their source, switches and limits',
        (tester) async {
          var s = const AirportSettings(airportId: 'a');
          await tester.pumpWidget(
            _app(
              b,
              StatefulBuilder(
                builder: (_, set) => AirportQueueTab(
                  settings: s,
                  zones: const [
                    AirportZone(
                      id: 'z',
                      airportId: 'a',
                      name: 'Holding bay',
                      shape: {'source': 'region:city'},
                    ),
                  ],
                  onChanged: (v) => set(() => s = v),
                  onAddZone: () {},
                  onRemoveZone: (_) {},
                ),
              ),
            ),
          );
          expect(find.text('Holding bay'), findsOneWidget);
          expect(find.text('Saved city'), findsOneWidget);
          expect(find.text('60 min'), findsOneWidget);
          await tester.tap(find.byTooltip('Raise join window'));
          await tester.pump();
          expect(s.joinWindowMin, 75);
          await tester.tap(find.byTooltip('Lower grace'));
          await tester.pump();
          expect(s.leaveGraceMin, 2);
          await tester.scrollUntilVisible(
            find.text(
              'A declined or missed offer sends the driver to the back',
            ),
            100,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.byType(Switch).last);
          await tester.pump();
          expect(s.backOnDecline, isFalse);
        },
      );

      testWidgets('admin fares: bands added and removed, the trial fare', (
        tester,
      ) async {
        var s = const AirportSettings(
          airportId: 'a',
          pickFee: AirportCharge(
            on: true,
            name: 'Airport pickup fee',
            amount: 6,
          ),
          fares: AirportFares(
            base: {'comfort': 8},
            band: DistanceBand(
              on: true,
              tiers: [BandTier(uptoKm: 10, flat: 45)],
            ),
          ),
        );
        await tester.pumpWidget(
          _app(
            b,
            StatefulBuilder(
              builder: (_, set) => AirportFaresTab(
                settings: s,
                services: const ['Ride', 'Comfort'],
                zones: const [],
                onChanged: (v) => set(() => s = v),
                onAddZone: () {},
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('airport-band-remove-0')),
          findsNothing,
          reason: 'the last band stays',
        );
        await tester.tap(find.byKey(const ValueKey('airport-band-add')));
        await tester.pump();
        expect(s.fares.band.tiers.length, 2);
        expect(
          find.byKey(const ValueKey('airport-band-remove-1')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('airport-band-remove-1')));
        await tester.pump();
        expect(s.fares.band.tiers.length, 1);
        // Ride, from the airport, 12 km past the 10 km band: 45 + 1.75 x 2 = 48.50 + 6 = 54.50 → 55.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('airport-fare-trial-total')),
            matching: find.textContaining('55.00'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Round up the fare'));
        await tester.tap(
          find.byType(Switch).at(find.byType(Switch).evaluate().length - 1),
        );
        await tester.pump();
        expect(s.fares.roundUp, isFalse);
      });

      testWidgets('admin charges: switch one on, name and amount', (
        tester,
      ) async {
        var s = const AirportSettings(airportId: 'a');
        await tester.pumpWidget(
          _app(
            b,
            StatefulBuilder(
              builder: (_, set) => AirportChargesTab(
                settings: s,
                onChanged: (v) => set(() => s = v),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(Switch).last);
        await tester.pump();
        expect(s.pickFee.on, isTrue);
        expect(s.pickFee.amount, 5);
        await tester.enterText(
          find.byKey(const ValueKey('airport-charge-amount-pick')).first,
          '6.5',
        );
        await tester.pump();
        expect(s.pickFee.amount, 6.5);
        await tester.enterText(
          find.byKey(const ValueKey('airport-charge-name-pick')).first,
          'Airport pickup fee',
        );
        expect(s.pickFee.name, 'Airport pickup fee');
      });

      testWidgets('admin gates & doors with the guide editor', (tester) async {
        var steps = _doors.first.guide;
        DoorKind? kind;
        await tester.pumpWidget(
          _app(
            b,
            StatefulBuilder(
              builder: (_, set) => AirportDoorsTab(
                doors: _doors,
                settings: const AirportSettings(airportId: 'a'),
                onSettings: (_) {},
                onKind: (_, k) => kind = k,
                onGuide: (_) {},
                openGuideId: 'd2',
                guideEditor: AirportGuideEditor(
                  door: AirportDoor(
                    id: 'd2',
                    airportId: 'a',
                    name: 'Door 3',
                    kind: DoorKind.pick,
                    guide: steps,
                  ),
                  onChanged: (v) => set(() => steps = v),
                  onPreview: () {},
                ),
              ),
            ),
          ),
        );
        expect(find.text('Synced'), findsNWidgets(2));
        expect(find.text('How-to guide · 3 steps · Open'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('airport-door-kind-d3-drop')),
        );
        expect(kind, DoorKind.drop);
        await tester.tap(find.byTooltip('Move step 1 down'));
        await tester.pump();
        expect(steps.first.text, 'Take the escalator down to Level 1.');
        await tester.tap(find.byTooltip('Delete step 3'));
        await tester.pump();
        expect(steps.length, 2);
        await tester.tap(find.byKey(const ValueKey('airport-guide-add-step')));
        await tester.pump();
        expect(steps.length, 3);
        expect(find.text('Preview as rider'), findsOneWidget);
      });

      testWidgets(
        'admin service order: lowest to highest, moved with the arrows',
        (tester) async {
          var order = const ServiceOrder(['r', 'c', 'p']);
          const services = [
            (id: 'r', name: 'Ride'),
            (id: 'c', name: 'Comfort'),
            (id: 'p', name: 'Premium'),
          ];
          await tester.pumpWidget(
            _app(
              b,
              StatefulBuilder(
                builder: (_, set) => SingleChildScrollView(
                  child: ServiceOrderEditor(
                    services: services,
                    order: order,
                    onChanged: (o) => set(() => order = o),
                  ),
                ),
              ),
            ),
          );
          expect(find.text('1. Ride'), findsOneWidget);
          expect(find.text('3. Premium'), findsOneWidget);
          await tester.tap(find.byTooltip('Move Ride higher'));
          await tester.pump();
          expect(order.ids, ['c', 'r', 'p']);
          expect(find.text('1. Comfort'), findsOneWidget);
          expect(
            tester
                .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.arrow_upward).first,
                )
                .onPressed,
            isNull,
          );
        },
      );

      testWidgets('driver airport card', (tester) async {
        await tester.pumpWidget(
          _app(
            b,
            const Column(
              children: [
                AirportQueueView(
                  state: DriverAirportState(
                    stage: DriverAirportStage.queued,
                    service: 'Comfort',
                    position: 2,
                    total: 5,
                  ),
                ),
                AirportQueueView(
                  state: DriverAirportState(
                    stage: DriverAirportStage.refused,
                    code: 'KUL',
                  ),
                ),
              ],
            ),
          ),
        );
        expect(find.text('#2'), findsOneWidget);
        expect(find.text('In the Comfort queue'), findsOneWidget);
        expect(
          find.text(
            'Only drivers who dropped off at KUL can wait for airport orders.',
          ),
          findsOneWidget,
        );
      });
    });
  }
}
