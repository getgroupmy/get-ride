import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/core/meter_console.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/core/street_hail.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/data/printer/printer_service.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/meter/meter_leave_launcher.dart';
import 'package:get_ride/src/features/meter/meter_providers.dart';
import 'package:get_ride/src/core/teksi_tariff.dart';
import 'package:get_ride/src/features/meter/meter_receipt_pdf.dart';
import 'package:get_ride/src/features/meter/meter_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/meter_session_store.dart';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_elm.dart';
import 'support/fake_printer.dart';
import 'notice.dart';

class _FakeLocation implements MeterLocation {
  final controller = StreamController<MeterFix>.broadcast();
  String? problem;

  @override
  Future<String?> prepare() async => problem;

  @override
  Stream<MeterFix> fixes() => controller.stream;

  var settingsOpened = 0;
  @override
  Future<void> openSettings() async => settingsOpened++;
}

/// Records what the meter asked of the device's rotation.
class _FakeOrientation implements MeterOrientation {
  final calls = <String>[];
  @override
  Future<void> lockLandscape() async => calls.add('lock');
  @override
  Future<void> release() async => calls.add('release');
}

/// Records what the leave popup asked of the device.
class _FakeLauncher implements MeterLeaveLauncher {
  _FakeLauncher({this.os = 'android', this.opens = const {}});
  @override
  final String os;
  final Set<String> opens;
  final calls = <String>[];

  @override
  bool get canExit => os == 'android';

  @override
  Future<void> exit() async => calls.add('exit');

  @override
  Future<bool> open(String url) async {
    calls.add(url);
    return opens.contains(url);
  }
}

/// Noon, so the DAY key is preselected.
var _clock = DateTime(2026, 10, 4, 12).millisecondsSinceEpoch;

/// ~11.1 m per 0.0001° of latitude.
MeterFix _fixAt(double northM) => MeterFix(latitude: 3.0 + northM / 111195, longitude: 101.0, at: _clock, accuracyM: 5);

MeterProfile _card({String source = 'gps'}) => defaultMeterProfile.copyWith(
  id: 'm1',
  level: 'master',
  label: () => 'Global (TEKSI old rates)',
  sourceMode: source,
);

Future<_FakeLocation> _pump(
  WidgetTester tester, {
  MeterProfile? card,
  bool noCard = false,
  _FakeLocation? location,
  FakeElm? reader,
  FakePrinter? printer,
  Size size = const Size(900, 1600),
  _FakeOrientation? orientation,
  Widget? app,
  MeterLeaveLauncher? launcher,
  List<String>? systemPrints,
  List<AssignableVehicle>? fleet,
  List<String>? claims,
  MeterDriverIdentity driver = const MeterDriverIdentity(name: 'Aina'),
  List<Override> extra = const [],
}) async {
  // A reader is "saved" on the phone when the test brings one.
  SharedPreferences.setMockInitialValues({
    if (reader != null)
      ObdAdapterStore.listKey: jsonEncode([normalizeWifiAdapter(id: 'r1', createdAt: 't').value!.toJson()]),
    if (printer != null)
      PrinterStore.listKey: jsonEncode([
        normalizeWifiPrinter(id: 'p1', createdAt: 't', host: '10.0.0.2').value!.toJson(),
      ]),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _clock = DateTime(2026, 10, 4, 12).millisecondsSinceEpoch;
  final loc = location ?? _FakeLocation();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meterLocationProvider.overrideWithValue(loc),
        meterClockProvider.overrideWithValue(() => _clock),
        obdClockProvider.overrideWithValue(() => _clock),
        obdTransportFactoryProvider.overrideWithValue((_) => reader ?? FakeElm()),
        printerSinkFactoryProvider.overrideWithValue((_) => printer ?? FakePrinter()),
        printerSettleProvider.overrideWithValue(Duration.zero),
        meterCardsProvider.overrideWith((_) async => noCard ? const <MeterProfile>[] : [card ?? _card()]),
        // The geocoder is unreachable in tests: ends stay as coordinates.
        geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
        partnerProvider.overrideWith((_) async => Partner({'id': 'p1', 'name': 'Aina', 'plate': 'WXY 1'})),
        meterOrientationProvider.overrideWithValue(orientation ?? _FakeOrientation()),
        meterLeaveLauncherProvider.overrideWithValue(launcher ?? _FakeLauncher()),
        meterLicenceProvider.overrideWith((_) async => 'Licence TX-123'),
        // Unreadable unless the test brings a fleet: nothing is asked.
        meterFleetProvider.overrideWith((_) async => fleet),
        meterClaimVehicleProvider.overrideWithValue((id) async => claims?.add(id)),
        meterDriverProvider.overrideWith((_) async => driver),
        meterSystemPrintProvider.overrideWithValue((trip, {subtitle}) async {
          systemPrints?.add('${trip.plate} $subtitle');
          return true;
        }),
        ...extra,
      ],
      child: app ?? const MaterialApp(home: MeterScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
  // Lets a saved reader finish its handshake.
  if (reader != null) await tester.pump(const Duration(milliseconds: 10));
  return loc;
}

/// One second of driving north at 36 km/h (10 m per tick).
Future<void> _driveSecond(WidgetTester tester, _FakeLocation loc, double northM) async {
  _clock += 1000;
  loc.controller.add(_fixAt(northM));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a hire is metered on GPS, declared and recorded with a receipt', (tester) async {
    final loc = await _pump(tester);
    expect(find.text('FOR HIRE'), findsOneWidget);
    expect(find.text('Global (TEKSI old rates)'), findsOneWidget);
    expect(find.text('4.00'), findsOneWidget, reason: 'the flag fall shows before the hire starts');

    loc.controller.add(_fixAt(0));
    await tester.pump();
    await tester.tap(find.text('START'));
    await tester.pump();
    expect(find.textContaining('HIRED'), findsOneWidget);

    // 1.6 km at 10 m/s. The first second after START only sets the GPS
    // baseline (as in the Expo meter), so 161 fixes cover 1600 m. The first
    // km is the flag fall; then 600 m is three 200 m blocks at 35 sen, which
    // beats the two 36 s blocks of time past the first km.
    for (var i = 1; i <= 161; i++) {
      await _driveSecond(tester, loc, i * 10.0);
    }
    expect(find.text('1.60'), findsOneWidget);
    expect(find.text('5.05'), findsOneWidget);

    await tester.tap(find.text('END'));
    await tester.pumpAndSettle();
    expect(find.text('Hire ended · fare RM 5.05'), findsOneWidget);
    expect(find.text('Still to declare: passengers · luggage · airport'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, 'CONFIRM & RECORD');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    // "2" is on both rows; passengers come first.
    await tester.tap(find.widgetWithText(ChoiceChip, '2').first);
    await tester.tap(find.widgetWithText(ChoiceChip, 'None'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Airport drop-off'));
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Vehicle WXY 1'), findsOneWidget);
    expect(find.text('RM 8.05'), findsOneWidget, reason: 'fare 5.05 + airport surcharge 3.00');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('FOR HIRE'), findsOneWidget);

    await tester.tap(find.text('Trip log'));
    await tester.pumpAndSettle();
    expect(find.text('1 hire · 1.60 km'), findsOneWidget);
  });

  for (final size in const [Size(852, 393), Size(667, 375)]) {
    testWidgets('SET is 44 on the screen on a phone on its side ($size)', (tester) async {
      await _pump(tester, size: size);
      await tester.pumpAndSettle();
      // It read 39 on an iPhone 15: a 44 button in a console scaled to fit.
      final set = tester.getRect(find.byKey(const ValueKey('meter-destination')));
      expect(set.shortestSide, greaterThanOrEqualTo(44 - 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a street hail goes to its destination: quoted, metered, and both on the receipt', (tester) async {
    final orientation = _FakeOrientation();
    final router = GoRouter(
      initialLocation: '/meter',
      routes: [
        GoRoute(path: '/meter', builder: (_, _) => const MeterScreen()),
        GoRoute(
          path: '/meter/destination',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.pop(
                const HailDestination(
                  name: 'KL Sentral',
                  latitude: 3.1340,
                  longitude: 101.6860,
                  routeKm: 8.2,
                  routeMin: 18,
                ),
              ),
              child: const Text('PICK KL SENTRAL'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    final loc = await _pump(
      tester,
      size: const Size(1600, 900),
      orientation: orientation,
      app: MaterialApp.router(routerConfig: router),
    );
    expect(find.text('NO DESTINATION'), findsOneWidget);
    // SET is a finger-sized target, and so is the vehicle chip's tap area.
    // 44 as it is on the screen, the console's scaling taken into account.
    final set = tester.getRect(find.byKey(const ValueKey('meter-destination')));
    expect(set.shortestSide, greaterThanOrEqualTo(44 - 0.01));
    expect(tester.getSize(find.byKey(const ValueKey('meter-plate'))).height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const ValueKey('meter-destination')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PICK KL SENTRAL'));
    await tester.pumpAndSettle();
    expect(orientation.calls, ['lock', 'release', 'lock'], reason: 'the map gets the app rotation');
    expect(find.text('KL Sentral · 8.2 km · ~18 min · est. RM 16.60'), findsOneWidget);

    loc.controller.add(_fixAt(0));
    await tester.pump();
    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 1; i <= 11; i++) {
      await _driveSecond(tester, loc, i * 10.0);
    }
    await tester.tap(find.text('END'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '1').first);
    await tester.tap(find.widgetWithText(ChoiceChip, 'None'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'No airport'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'CONFIRM & RECORD'));
    await tester.pumpAndSettle();
    expect(find.text('KL Sentral'), findsOneWidget);
    expect(find.text('RM 16.60'), findsOneWidget, reason: 'the quote');
    expect(find.text('RM 4.00'), findsWidgets, reason: 'what was metered: the flag fall');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('NO DESTINATION'), findsOneWidget, reason: 'the next hire starts without one');
  });

  group('TEKSI tariffs', () {
    testWidgets('with no operator card the driver keys OLD or NEW RATES, frozen for a hire', (tester) async {
      final loc = await _pump(tester, noCard: true);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('OLD RATES'), findsOneWidget);
      expect(find.text('Old Tariff'), findsOneWidget, reason: 'Old, as Expo starts on');
      await tester.tap(find.text('NEW RATES'));
      await tester.pump();
      expect(find.text('New Tariff'), findsOneWidget);
      loc.controller.add(_fixAt(0));
      await tester.pump();
      await tester.tap(find.text('START'));
      await tester.pump();
      await tester.tap(find.text('OLD RATES'));
      await tester.pump();
      expect(find.text('New Tariff'), findsOneWidget, reason: 'a hire keeps the tariff it opened on');
    });

    testWidgets("an operator's card has no tariff keys", (tester) async {
      await _pump(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('meter-tariff')), findsNothing);
      expect(find.text('Global (TEKSI old rates)'), findsOneWidget);
    });

    testWidgets('Start on the TEKSI trip opens the meter running, on its tariff and destination', (tester) async {
      final loc = await _pump(
        tester,
        noCard: true,
        app: const MaterialApp(
          home: MeterScreen(
            launch: MeterLaunch(
              tariff: TeksiTariff.newTariff,
              destination: HailDestination(
                name: 'KLCC',
                latitude: 3.158,
                longitude: 101.712,
                routeKm: 8.2,
                routeMin: 18,
              ),
              startHire: true,
            ),
          ),
        ),
      );
      loc.controller.add(_fixAt(0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('HIRED'), findsOneWidget);
      expect(find.text('New Tariff'), findsOneWidget);
      expect(find.textContaining('KLCC'), findsWidgets);
    });

    testWidgets('the tariff keys fit a small landscape phone', (tester) async {
      await _pump(tester, noCard: true, size: const Size(640, 320));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('NEW RATES'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('RESUME HIRE puts the passenger back without billing the form', (tester) async {
    final loc = await _pump(tester);
    loc.controller.add(_fixAt(0));
    await tester.pump();
    await tester.tap(find.text('START'));
    await tester.pump();
    await _driveSecond(tester, loc, 10);
    await tester.tap(find.text('END'));
    await tester.pumpAndSettle();
    // A long time on the form is not billed.
    _clock += 120000;
    await tester.tap(find.text('RESUME HIRE'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HIRED'), findsOneWidget);
    // Trip time is still one second (the baseline second also reads as
    // waiting, hence two readouts).
    expect(find.text('00:00:01'), findsNWidgets(2));
    expect(find.text('00:02:01'), findsNothing);
  });

  testWidgets('an OBD-only rate card cannot be billed on GPS', (tester) async {
    final loc = await _pump(tester, card: _card(source: 'obd'));
    loc.controller.add(_fixAt(0));
    await tester.pump();
    expect(find.textContaining("bills on the vehicle's OBD-II reader only"), findsOneWidget);
    await tester.tap(find.text('START'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('meter-start-gate')), findsOneWidget);
    expect(find.text('No vehicle link'), findsOneWidget);
    expect(find.byKey(const ValueKey('meter-gate-gps')), findsNothing, reason: 'the card took GPS away');
    expect(find.text('ADD A READER'), findsOneWidget, reason: 'no reader is saved on this phone');
    await tester.tap(find.byKey(const ValueKey('meter-gate-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('FOR HIRE'), findsOneWidget);
  });

  testWidgets('an OBD-only rate card starts on the reader and bills on its speed', (tester) async {
    final elm = FakeElm(speed: 36);
    await _pump(
      tester,
      card: _card(source: 'obd'),
      reader: elm,
    );
    expect(find.text('OBD-II'), findsOneWidget, reason: 'the connection type, GPS taken away by the card');
    await tester.tap(find.text('START'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(elm.written, contains('01A6'), reason: 'the pickup odometer is read before the fare opens');
    expect(find.textContaining('HIRED'), findsOneWidget);

    // 36 km/h is 10 m a second: 100 seconds is a kilometre.
    for (var i = 0; i < 100; i++) {
      _clock += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('1.00'), findsOneWidget);
    expect(find.text('HIRED · OBD-II'), findsOneWidget, reason: 'billed on the vehicle speed');

    await tester.tap(find.text('END'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '1').first);
    await tester.tap(find.widgetWithText(ChoiceChip, 'None'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'No airport'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'CONFIRM & RECORD'));
    await tester.pumpAndSettle();
    expect(find.text('Pickup odometer'), findsOneWidget);
    expect(find.text('128 450.6 km'), findsWidgets);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  /// A one-second hire, declared and recorded, leaving the receipt open.
  Future<void> recordShortHire(WidgetTester tester, _FakeLocation loc) async {
    loc.controller.add(_fixAt(0));
    await tester.pump();
    await tester.tap(find.text('START'));
    await tester.pump();
    await _driveSecond(tester, loc, 10);
    await tester.tap(find.text('END'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '1').first);
    await tester.tap(find.widgetWithText(ChoiceChip, 'None'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'No airport'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'CONFIRM & RECORD'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsOneWidget);
  }

  testWidgets('the receipt prints straight to the saved printer', (tester) async {
    final printer = FakePrinter();
    final loc = await _pump(tester, printer: printer);
    await recordShortHire(tester, loc);
    await tester.tap(find.widgetWithText(TextButton, 'Print'));
    await tester.pumpAndSettle();
    expect(printer.jobs.single, contains('Vehicle WXY 1'));
    expect(printer.jobs.single, contains('Thank you for riding.'));
    expect(find.text('Receipt sent to Wi-Fi printer.'), findsOneWidget);
  });

  testWidgets('with no printer set up, Print offers the setup screen', (tester) async {
    final loc = await _pump(tester);
    await recordShortHire(tester, loc);
    await tester.tap(find.widgetWithText(TextButton, 'Print'));
    // Print shows its spinner until the dialog is answered, so it never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('No printer set up'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsOneWidget, reason: 'the receipt stays open to copy');
  });

  testWidgets('the paper receipt carries the driver\'s licence', (tester) async {
    final printer = FakePrinter();
    final loc = await _pump(tester, printer: printer);
    await recordShortHire(tester, loc);
    await tester.tap(find.widgetWithText(TextButton, 'Print'));
    await tester.pumpAndSettle();
    expect(printer.jobs.single, contains('Licence TX-123'));
    expect(find.text('Receipt'), findsNothing, reason: 'printed, the hire is finished and the receipt closes');
  });

  testWidgets('the receipt of a hire just ended is not tapped away', (tester) async {
    final loc = await _pump(tester);
    await recordShortHire(tester, loc);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receipt-done')));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsNothing);
  });

  testWidgets('a printer that can\'t be reached offers the phone\'s print service', (tester) async {
    final prints = <String>[];
    final loc = await _pump(tester, printer: FakePrinter(refuse: true), systemPrints: prints);
    await recordShortHire(tester, loc);
    await tester.tap(find.widgetWithText(TextButton, 'Print'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Printer not reachable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receipt-system-print')));
    await tester.pumpAndSettle();
    expect(prints, ['WXY 1 Licence TX-123']);
    expect(find.text('Receipt'), findsNothing);
  });

  testWidgets('with no printer set up, the phone\'s print service is offered too', (tester) async {
    final prints = <String>[];
    final loc = await _pump(tester, systemPrints: prints);
    await recordShortHire(tester, loc);
    await tester.tap(find.widgetWithText(TextButton, 'Print'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('receipt-system-print')));
    await tester.pumpAndSettle();
    expect(prints, hasLength(1));
  });

  testWidgets('the console says where receipts print', (tester) async {
    await _pump(tester, printer: FakePrinter());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Printing to Wi-Fi printer'), findsOneWidget);
  });

  group('the landscape console', () {
    testWidgets('pins landscape while open and hands rotation back on the way out', (tester) async {
      final orientation = _FakeOrientation();
      await _pump(tester, orientation: orientation);
      expect(orientation.calls, ['lock']);
      await tester.pumpWidget(const SizedBox());
      expect(orientation.calls, ['lock', 'release']);
    });

    testWidgets('a portrait viewport turns the console a quarter turn, dialogs included', (tester) async {
      await _pump(tester, card: _card(source: 'obd'));
      final stage = find.byType(RotatedBox);
      expect(tester.widget<RotatedBox>(stage).quarterTurns, 1);
      await tester.tap(find.text('START'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: stage, matching: find.text('No vehicle link')), findsOneWidget);
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();
      expect(find.text('No vehicle link'), findsNothing);
    });

    testWidgets('a landscape phone gets the console as is, fitted without overflow', (tester) async {
      // An OBD-only card shows the longest key panel: the start block.
      await _pump(
        tester,
        size: const Size(844, 390),
        card: _card(source: 'obd'),
      );
      expect(find.byType(RotatedBox), findsNothing);
      expect(find.text('START'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a running hire fits a small landscape phone', (tester) async {
      final loc = await _pump(tester, size: const Size(640, 320));
      loc.controller.add(_fixAt(0));
      await tester.pump();
      await tester.tap(find.text('START'));
      await tester.pump();
      await _driveSecond(tester, loc, 10);
      expect(find.text('END'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('back from the trip log returns to the meter', (tester) async {
      await _pump(tester, size: const Size(1600, 900));
      await tester.tap(find.text('Trip log'));
      await tester.pumpAndSettle();
      expect(find.text('No hires on this device yet.'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('FOR HIRE'), findsOneWidget);
    });

    testWidgets('a settings screen gets the app rotation back, and the console re-pins it', (tester) async {
      final orientation = _FakeOrientation();
      final router = GoRouter(
        initialLocation: '/meter',
        routes: [
          GoRoute(path: '/meter', builder: (_, _) => const MeterScreen()),
          GoRoute(
            path: '/meter/printer',
            builder: (_, _) => const Scaffold(body: Text('PRINTER SETUP')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(
        tester,
        size: const Size(1600, 900),
        orientation: orientation,
        app: MaterialApp.router(routerConfig: router),
      );
      await tester.tap(find.byKey(const ValueKey('meter-panel-printer')));
      await tester.pumpAndSettle();
      expect(find.text('PRINTER SETUP'), findsOneWidget);
      expect(orientation.calls, ['lock', 'release']);
      router.pop();
      await tester.pumpAndSettle();
      expect(orientation.calls, ['lock', 'release', 'lock']);
    });
  });

  testWidgets('no location permission means no hire', (tester) async {
    final loc = await _pump(
      tester,
      location: _FakeLocation()..problem = 'Location permission is needed to meter on GPS.',
    );
    expect(find.text('NO SIGNAL'), findsOneWidget);
    await tester.tap(find.text('START'));
    await tester.pumpAndSettle();
    expect(find.text('Location is off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('meter-gate-location')));
    await tester.pumpAndSettle();
    expect(loc.settingsOpened, 1, reason: 'the popup points at location permission');
    expect(find.text('FOR HIRE'), findsOneWidget);
  });

  testWidgets('a running hire rebuilds its readouts each second, not the console', (tester) async {
    final loc = await _pump(tester, size: const Size(1600, 900));
    loc.controller.add(_fixAt(0));
    await tester.pump();
    await tester.tap(find.text('START'));
    await tester.pump();
    await _driveSecond(tester, loc, 10);
    var builds = 0;
    debugOnRebuildDirtyWidget = (_, _) => builds++;
    for (var i = 2; i <= 6; i++) {
      await _driveSecond(tester, loc, i * 10.0);
    }
    debugOnRebuildDirtyWidget = null;
    // The whole console was about 3,000 element builds over these five
    // seconds; the readouts alone are a few dozen a second.
    expect(builds, lessThan(600));
    expect(find.text('0.05'), findsOneWidget, reason: 'the distance still moves');
    expect(find.text('00:00:06'), findsOneWidget, reason: 'and the time');
    expect(find.textContaining('HIRED · GPS'), findsOneWidget);
  });

  testWidgets('extras step and are included in the fare shown', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('More extra'));
    await tester.tap(find.byTooltip('More extra'));
    await tester.pump();
    expect(find.text('1.00'), findsOneWidget);
    expect(find.text('5.00'), findsOneWidget);
    expect(find.text('incl. extras RM 1.00'), findsOneWidget);
  });

  group('leaving the meter', () {
    GoRouter routerFor() => GoRouter(
      initialLocation: '/meter',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('PASSENGER HOME')),
        ),
        GoRoute(
          path: '/drive',
          builder: (_, _) => const Scaffold(body: Text('E-HAILING QUEUE')),
        ),
        GoRoute(path: '/meter', builder: (_, _) => const MeterScreen()),
      ],
    );

    testWidgets('back asks where to; staying keeps the console', (tester) async {
      final router = routerFor();
      addTearDown(router.dispose);
      await _pump(
        tester,
        size: const Size(1600, 900),
        app: MaterialApp.router(routerConfig: router),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Leave the meter?'), findsOneWidget);
      expect(find.text('PASSENGER MODE'), findsOneWidget);
      expect(find.text('E-HAILING'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('meter-leave-stay')));
      await tester.pumpAndSettle();
      expect(find.text('FOR HIRE'), findsOneWidget);
    });

    testWidgets('the in-app keys go to passenger mode or the e-hailing queue', (tester) async {
      final router = routerFor();
      addTearDown(router.dispose);
      await _pump(
        tester,
        size: const Size(1600, 900),
        app: MaterialApp.router(routerConfig: router),
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meter-leave-ehailing')));
      await tester.pumpAndSettle();
      expect(find.text('E-HAILING QUEUE'), findsOneWidget);
    });

    testWidgets('a running hire cannot be left', (tester) async {
      final loc = await _pump(tester, size: const Size(1600, 900));
      loc.controller.add(_fixAt(0));
      await tester.pump();
      await tester.tap(find.text('START'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Leave the meter?'), findsNothing);
      await pumpNotice(tester);
      expect(find.text('End the hire before leaving the meter.'), findsOneWidget);
    });

    testWidgets("the card's dispatch app opens, and its store when it isn't installed", (tester) async {
      final launcher = _FakeLauncher(opens: {'https://play.google.com/store/apps/details?id=com.jobtepi.app'});
      final card = _card().copyWith(
        leave: const MeterLeaveConfig(passenger: 'exit', ehailing: 'link', ehailingAppId: 'gvride'),
      );
      await _pump(tester, size: const Size(1600, 900), card: card, launcher: launcher);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('EXIT'), findsOneWidget);
      expect(find.text('GVRIDE'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('meter-leave-ehailing')));
      await tester.pumpAndSettle();
      expect(launcher.calls, [
        'intent://#Intent;package=com.jobtepi.app;end',
        'https://play.google.com/store/apps/details?id=com.jobtepi.app',
      ]);
      expect(find.text('Could not open the app'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meter-leave-passenger')));
      await tester.pumpAndSettle();
      expect(launcher.calls.last, 'exit');
    });

    testWidgets('iOS is told how to leave instead of the app closing itself', (tester) async {
      final launcher = _FakeLauncher(os: 'ios');
      final card = _card().copyWith(leave: const MeterLeaveConfig(passenger: 'exit'));
      await _pump(tester, size: const Size(1600, 900), card: card, launcher: launcher);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meter-leave-passenger')));
      await tester.pumpAndSettle();
      expect(launcher.calls, isEmpty);
      expect(find.textContaining('iOS does not let an app close itself'), findsOneWidget);
    });
  });

  testWidgets('the rate card hides and locks console panels', (tester) async {
    await _pump(
      tester,
      card: _card().copyWith(
        panels: {
          ...allPanelsOn(),
          'trips': const MeterPanelAccess(show: false, tap: false),
          'printer': const MeterPanelAccess(show: true, tap: false),
          'obd': const MeterPanelAccess(show: false, tap: false),
        },
      ),
    );
    await tester.pump();
    expect(find.text('Trip log'), findsNothing);
    expect(find.byKey(const ValueKey('meter-panel-obd')), findsNothing);
    final printer = tester.widget<IconButton>(find.byKey(const ValueKey('meter-panel-printer')));
    expect(printer.onPressed, isNull);
  });

  group('Batch 1 parity', () {
    AssignableVehicle car(String id, String plate, AssignableStatus status) => AssignableVehicle(
      vehicle: {'id': id, 'plate': plate, 'make': 'Proton', 'model': 'Saga'},
      role: VehicleRole.driver,
      status: status,
    );

    testWidgets('a car this driver already holds binds silently', (tester) async {
      await _pump(tester, fleet: [car('v1', 'VBD 1', AssignableStatus.inUseByYou)]);
      await tester.pumpAndSettle();
      expect(find.text('Choose a vehicle'), findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('meter-plate')), matching: find.text('VBD 1')),
        findsOneWidget,
      );
    });

    testWidgets('with no car held the driver is asked, and the pick is claimed', (tester) async {
      final claims = <String>[];
      await _pump(tester, fleet: [car('v2', 'VAV 2', AssignableStatus.available)], claims: claims);
      await tester.pumpAndSettle();
      expect(find.text('Choose a vehicle'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-v2')));
      await tester.pumpAndSettle();
      expect(claims, ['v2']);
      expect(
        find.descendant(of: find.byKey(const ValueKey('meter-plate')), matching: find.text('VAV 2')),
        findsOneWidget,
      );
    });

    testWidgets('the picker is dismissible, and the plate chip reopens it', (tester) async {
      await _pump(tester, fleet: [car('v2', 'VAV 2', AssignableStatus.available)]);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Choose a vehicle'), findsNothing);
      expect(find.text('SELECT'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('meter-plate')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a vehicle'), findsOneWidget);
    });

    testWidgets('an unreadable fleet asks nothing', (tester) async {
      await _pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('Choose a vehicle'), findsNothing);
      expect(find.text('SELECT'), findsOneWidget);
    });

    testWidgets('the driver strip reads the permit', (tester) async {
      await _pump(
        tester,
        driver: const MeterDriverIdentity(name: 'Siti Aminah', licence: 'TX-123'),
      );
      expect(find.text('SITI AMINAH'), findsOneWidget);
      expect(find.text('TX-123'), findsOneWidget);
    });

    testWidgets('a GPS-only card holds START for the first fix, then opens by itself', (tester) async {
      final loc = await _pump(tester);
      await tester.tap(find.text('START'));
      // The popup's spinner never settles while it waits.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Acquiring GPS…'), findsOneWidget);
      loc.controller.add(_fixAt(0));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('meter-start-gate')), findsNothing);
      expect(find.textContaining('HIRED'), findsOneWidget);
      expect(find.byKey(const ValueKey('meter-pickup')), findsOneWidget, reason: 'where the passenger got in');
    });

    testWidgets('a reader that will not answer offers GPS on a card that bills on both', (tester) async {
      final loc = await _pump(
        tester,
        card: _card(source: 'gps+obd'),
        reader: FakeElm()..refuseConnect = true,
      );
      loc.controller.add(_fixAt(0));
      await tester.pump();
      await tester.tap(find.text('START'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('meter-start-gate')), findsOneWidget);
      expect(find.text('START ON GPS'), findsOneWidget);
      await tester.tap(find.text('START ON GPS'));
      await tester.pumpAndSettle();
      expect(find.textContaining('HIRED'), findsOneWidget);
    });

    testWidgets('the settings panel names the card, charge by charge, and the sensors', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('meter-tab-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Global (TEKSI old rates)'), findsOneWidget);
      expect(find.textContaining('• '), findsWidgets);
      expect(find.text('Waiting for a fix…'), findsOneWidget);
    });
  });

  group('Meter on/off (Meter at sign-in)', () {
    for (final b in Brightness.values) {
      Future<_FakeLocation> pumpWith(WidgetTester tester, String mode) async {
        final router = GoRouter(
          initialLocation: '/meter',
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('HOME'))),
            GoRoute(path: '/meter', builder: (_, _) => const MeterScreen()),
          ],
        );
        addTearDown(router.dispose);
        final loc = await _pump(
          tester,
          size: const Size(1600, 900),
          app: MaterialApp.router(theme: appTheme(b), routerConfig: router),
          extra: [
            meterAtSignInProvider.overrideWith((_) async => mode),
            meterLaunchSessionProvider.overrideWithValue('u1|09:00'),
          ],
        );
        await tester.pumpAndSettle();
        return loc;
      }

      testWidgets('turns the meter off for the sign-in and opens the app (${b.name})', (tester) async {
        await pumpWith(tester, 'ask');
        expect(find.byKey(const ValueKey('meter-session-switch')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('meter-session-switch')));
        await tester.pumpAndSettle();
        expect(find.text('HOME'), findsOneWidget);
        expect(await MeterSessionStore().read('u1|09:00'), isFalse);
      });

      testWidgets('no switch where the card leaves it to Open the meter on launch (${b.name})', (tester) async {
        await pumpWith(tester, 'off');
        expect(find.byKey(const ValueKey('meter-session-switch')), findsNothing);
      });

      testWidgets('a hire in progress stays on the meter (${b.name})', (tester) async {
        final loc = await pumpWith(tester, 'always');
        loc.controller.add(_fixAt(0));
        await tester.pump();
        await tester.tap(find.text('START'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('meter-session-switch')));
        await tester.pumpAndSettle();
        expect(find.text('End the hire before turning the meter off.'), findsOneWidget);
        expect(find.text('HOME'), findsNothing);
        expect(await MeterSessionStore().read('u1|09:00'), isNull);
      });
    }
  });
}
