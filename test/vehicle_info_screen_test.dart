import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/data/vehicle_fuel_store.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/data/obd/obd_transport.dart';
import 'package:get_ride/src/features/meter/vehicle_info_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An ELM327 on a car that supports engine speed, vehicle speed and the
/// monitor status, has one stored fault and answers a VIN.
class _ScriptedElm implements ObdTransport {
  _ScriptedElm({this.speed = 0});
  int speed;
  final written = <String>[];
  final _data = StreamController<String>.broadcast();
  bool cleared = false;

  String _reply(String cmd) => switch (cmd) {
    'ATZ' || 'ATI' => 'ELM327 v1.5',
    'ATDPN' => 'A6',
    'ATDP' => 'ISO 15765-4 (CAN 11/500)',
    'ATRV' => '12.6V',
    '0100' => '41 00 80 18 00 01',
    '0120' => '41 20 00 02 00 00',
    '012F' => '41 2F 80',
    '0101' => '41 01 81 07 65 00',
    '010C' => '41 0C 1A F8',
    '010D' => '41 0D ${speed.toRadixString(16).padLeft(2, '0').toUpperCase()}',
    '0105' => '41 05 7B',
    '0900' => '49 00 40 00 00 00',
    '0902' => '49 02 01 31 48 47 43 4D 38 32 36 33 33 41 30 30 34 33 35 32',
    '03' => cleared ? '43 00' : '43 01 33 00 00 00 00',
    '04' => () {
      cleared = true;
      return '44';
    }(),
    _ when cmd.startsWith('AT') => 'OK',
    _ => 'NO DATA',
  };

  @override
  String get kind => 'wifi';

  @override
  Stream<String> get data => _data.stream;

  @override
  Future<String> connect() async => '192.168.0.10:35000';

  @override
  Future<void> write(String command) async {
    written.add(command);
    final reply = '${_reply(command)}\r\r>';
    scheduleMicrotask(() => _data.add(reply));
  }

  @override
  Future<void> disconnect() async {}
}

const _adapter = SavedObdAdapter(
  id: 'a1',
  name: 'Taxi dongle',
  transport: 'wifi',
  host: '192.168.0.10',
  port: 35000,
  createdAt: '2026-10-01T00:00:00Z',
);

Future<ProviderContainer> _pump(WidgetTester tester, _ScriptedElm elm) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 8000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [obdTransportFactoryProvider.overrideWithValue((_) => elm)]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: VehicleInfoScreen()),
    ),
  );
  await tester.pump();
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('without a reader it points at the reader screen', (tester) async {
    await _pump(tester, _ScriptedElm());
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('OBD-II reader'), findsOneWidget);
    expect(find.text('Clear trouble codes'), findsOneWidget);
    expect(find.text('Connect the OBD-II reader first.'), findsWidgets);
  });

  testWidgets('reads the vehicle on a live link and clears codes when parked', (tester) async {
    final elm = _ScriptedElm();
    final container = await _pump(tester, elm);
    unawaited(container.read(obdSessionProvider.notifier).connect(_adapter));
    await _settle(tester);

    expect(find.text('Connected — Taxi dongle'), findsOneWidget);
    expect(find.text('Engine speed'), findsOneWidget);
    expect(find.text('Vehicle speed'), findsOneWidget);
    expect(find.textContaining('1HGCM82633A004352'), findsWidgets);
    expect(find.textContaining('P0133'), findsOneWidget);
    expect(find.text('Check-engine light'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Clear trouble codes'), 300);
    await tester.tap(find.text('Clear trouble codes'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.text('Clear diagnostic trouble codes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear codes'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('write-result')), findsOneWidget);
    expect(find.textContaining('Codes cleared.'), findsOneWidget);
    expect(elm.written, contains('04'));

    await tester.tap(find.text('Close'));
    await _settle(tester);
    // The codes were re-read after the write.
    expect(find.textContaining('P0133'), findsNothing);
    await container.read(obdSessionProvider.notifier).disconnect();
  });

  testWidgets('ECU writes are refused while the vehicle moves', (tester) async {
    final elm = _ScriptedElm(speed: 40);
    final container = await _pump(tester, elm);
    unawaited(container.read(obdSessionProvider.notifier).connect(_adapter));
    await _settle(tester);
    // Let the 1 Hz sweep pick the speed up.
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);

    await tester.scrollUntilVisible(find.text('Clear trouble codes'), 300);
    final tile = tester.widget<ListTile>(find.byKey(const ValueKey('write-clear-dtc')));
    expect(tile.enabled, isFalse);
    final reset = tester.widget<ListTile>(find.byKey(const ValueKey('write-reset-adapter')));
    expect(reset.enabled, isTrue, reason: 'reader-only writes stay available');
    expect(elm.written, isNot(contains('04')));
    await container.read(obdSessionProvider.notifier).disconnect();
  });

  testWidgets('fuel card: level from the bus, range from the tank the driver enters', (tester) async {
    final elm = _ScriptedElm();
    final container = await _pump(tester, elm);
    unawaited(container.read(obdSessionProvider.notifier).connect(_adapter));
    await _settle(tester);

    String text(String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;
    expect(text('fuel-level'), '50');
    expect(text('fuel-odometer'), '—', reason: 'this car does not publish PID A6');
    final before = text('fuel-range');
    expect(before, isNot('—'));
    expect(find.textContaining('This vehicle does not answer the odometer parameter'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fuel-edit')));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.enterText(find.byKey(const ValueKey('fuel-tank')), '3');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.textContaining('5'), findsWidgets, reason: 'the limit is named');
    expect(find.text('Tank & consumption'), findsWidgets, reason: 'the editor stays open');

    await tester.enterText(find.byKey(const ValueKey('fuel-tank')), '90');
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('fuel-tank')), findsNothing);
    expect((await container.read(vehicleFuelStoreProvider).load()).tankCapacityL, 90);
    expect(text('fuel-range'), isNot(before), reason: 'a bigger tank goes further');
    await container.read(obdSessionProvider.notifier).disconnect();
  });
}
