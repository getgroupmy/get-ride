// Performance probe: rebuilds per second on the meter screen (for hire, hired
// stationary, hired driving), built on meter_screen_test.dart's harness.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:get_ride/src/features/meter/meter_leave_launcher.dart';
import 'package:get_ride/src/features/meter/meter_providers.dart';
import 'package:get_ride/src/core/teksi_tariff.dart';
import 'package:get_ride/src/features/meter/meter_receipt_pdf.dart';
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
  testWidgets('PROBE meter rebuild counts', (tester) async {
    final loc = await _pump(tester);
    var total = 0;
    final counts = <String, int>{};
    void reset() { total = 0; counts.clear(); }
    String top() => (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(8).map((e) => '${e.key}=${e.value}').join(', ');
    debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
      total++;
      final k = e.widget.runtimeType.toString();
      counts[k] = (counts[k] ?? 0) + 1;
    };
    reset();
    // Idle (for hire), 5 s.
    for (var i = 0; i < 5; i++) {
      _clock += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    final idle = total;
    final idleTop = top();
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump();
    reset();
    // Hired, 5 s stationary.
    for (var i = 0; i < 5; i++) {
      _clock += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    final hiredStill = total;
    final stillTop = top();
    reset();
    // Hired, 5 s driving at 36 km/h.
    for (var i = 1; i <= 5; i++) {
      await _driveSecond(tester, loc, 10.0 * i);
    }
    final driving = total;
    final driveTop = top();
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('PROBE meter: for-hire idle 5s -> rebuilds=$idle top: $idleTop');
    // ignore: avoid_print
    print('PROBE meter: hired stationary 5s -> rebuilds=$hiredStill top: $stillTop');
    // ignore: avoid_print
    print('PROBE meter: hired driving 5s (5 fixes) -> rebuilds=$driving top: $driveTop');
  });
}
