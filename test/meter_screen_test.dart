import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/data/printer/printer_service.dart';
import 'package:get_ride/src/features/meter/meter_providers.dart';
import 'package:get_ride/src/features/meter/meter_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_elm.dart';
import 'support/fake_printer.dart';

class _FakeLocation implements MeterLocation {
  final controller = StreamController<MeterFix>.broadcast();
  String? problem;

  @override
  Future<String?> prepare() async => problem;

  @override
  Stream<MeterFix> fixes() => controller.stream;
}

/// Records what the meter asked of the device's rotation.
class _FakeOrientation implements MeterOrientation {
  final calls = <String>[];
  @override
  Future<void> lockLandscape() async => calls.add('lock');
  @override
  Future<void> release() async => calls.add('release');
}

/// Noon, so the DAY key is preselected.
var _clock = DateTime(2026, 10, 4, 12).millisecondsSinceEpoch;

/// ~11.1 m per 0.0001° of latitude.
MeterFix _fixAt(double northM) =>
    MeterFix(latitude: 3.0 + northM / 111195, longitude: 101.0, at: _clock, accuracyM: 5);

MeterProfile _card({String source = 'gps'}) => defaultMeterProfile.copyWith(
      id: 'm1',
      level: 'master',
      label: () => 'Global (TEKSI old rates)',
      sourceMode: source,
    );

Future<_FakeLocation> _pump(WidgetTester tester, {
  MeterProfile? card,
  _FakeLocation? location,
  FakeElm? reader,
  FakePrinter? printer,
  Size size = const Size(900, 1600),
  _FakeOrientation? orientation,
  Widget? app,
}) async {
  // A reader is "saved" on the phone when the test brings one.
  SharedPreferences.setMockInitialValues({
    if (reader != null)
      ObdAdapterStore.listKey: jsonEncode([normalizeWifiAdapter(id: 'r1', createdAt: 't').value!.toJson()]),
    if (printer != null)
      PrinterStore.listKey: jsonEncode([normalizeWifiPrinter(id: 'p1', createdAt: 't', host: '10.0.0.2').value!.toJson()]),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _clock = DateTime(2026, 10, 4, 12).millisecondsSinceEpoch;
  final loc = location ?? _FakeLocation();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      meterLocationProvider.overrideWithValue(loc),
      meterClockProvider.overrideWithValue(() => _clock),
      obdClockProvider.overrideWithValue(() => _clock),
      obdTransportFactoryProvider.overrideWithValue((_) => reader ?? FakeElm()),
      printerSinkFactoryProvider.overrideWithValue((_) => printer ?? FakePrinter()),
      printerSettleProvider.overrideWithValue(Duration.zero),
      meterCardsProvider.overrideWith((_) async => [card ?? _card()]),
      // The geocoder is unreachable in tests: ends stay as coordinates.
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      partnerProvider.overrideWith((_) async => Partner({'id': 'p1', 'name': 'Aina', 'plate': 'WXY 1'})),
      meterOrientationProvider.overrideWithValue(orientation ?? _FakeOrientation()),
    ],
    child: app ?? const MaterialApp(home: MeterScreen()),
  ));
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
    await _pump(tester, card: _card(source: 'obd'));
    expect(find.textContaining("bills on the vehicle's OBD-II reader only"), findsOneWidget);
    await tester.tap(find.text('START'));
    await tester.pumpAndSettle();
    expect(find.text('Cannot start the meter'), findsOneWidget);
    expect(find.text('FOR HIRE'), findsOneWidget);
  });

  testWidgets('an OBD-only rate card starts on the reader and bills on its speed', (tester) async {
    final elm = FakeElm(speed: 36);
    await _pump(tester, card: _card(source: 'obd'), reader: elm);
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
    await tester.pumpAndSettle();
    expect(find.text('No printer set up'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsOneWidget, reason: 'the receipt stays open to copy');
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
      expect(find.descendant(of: stage, matching: find.text('Cannot start the meter')), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Cannot start the meter'), findsNothing);
    });

    testWidgets('a landscape phone gets the console as is, fitted without overflow', (tester) async {
      // An OBD-only card shows the longest key panel: the start block.
      await _pump(tester, size: const Size(844, 390), card: _card(source: 'obd'));
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
      final router = GoRouter(initialLocation: '/meter', routes: [
        GoRoute(path: '/meter', builder: (_, _) => const MeterScreen()),
        GoRoute(path: '/meter/printer', builder: (_, _) => const Scaffold(body: Text('PRINTER SETUP'))),
      ]);
      addTearDown(router.dispose);
      await _pump(tester,
          size: const Size(1600, 900), orientation: orientation, app: MaterialApp.router(routerConfig: router));
      await tester.tap(find.byTooltip('Receipt printer'));
      await tester.pumpAndSettle();
      expect(find.text('PRINTER SETUP'), findsOneWidget);
      expect(orientation.calls, ['lock', 'release']);
      router.pop();
      await tester.pumpAndSettle();
      expect(orientation.calls, ['lock', 'release', 'lock']);
    });
  });

  testWidgets('no location permission means no hire', (tester) async {
    await _pump(tester, location: _FakeLocation()..problem = 'Location permission is needed to meter on GPS.');
    expect(find.text('NO SIGNAL'), findsOneWidget);
    await tester.tap(find.text('START'));
    await tester.pumpAndSettle();
    expect(find.text('Cannot start the meter'), findsOneWidget);
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
}
