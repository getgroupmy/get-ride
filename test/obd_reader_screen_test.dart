import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/obd/obd_ble_transport.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/features/meter/obd_reader_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_elm.dart';

/// Plays a scan back: what a phone in a car park would see.
class _FakeScanner implements ObdBleScanner {
  _FakeScanner({this.error});
  final Object? error;

  @override
  Stream<ObdBleSighting> scan({Duration duration = const Duration(seconds: 12)}) async* {
    if (error != null) throw error!;
    yield (deviceId: 'AA:BB:CC:00:00:01', name: null, services: const <String>[], rssi: -60);
    // The name arrives in a later advertisement.
    yield (deviceId: 'AA:BB:CC:00:00:01', name: 'OBDII', services: const <String>[], rssi: -58);
    yield (deviceId: '11:22:33:44:55:66', name: 'Pixel Buds', services: const <String>[], rssi: -40);
  }
}

void main() {
  testWidgets('a Wi-Fi reader is added, connected and shows live data', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final elm = FakeElm(speed: 60);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [obdTransportFactoryProvider.overrideWithValue((_) => elm)],
        child: const MaterialApp(home: ObdReaderScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No reader yet'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);

    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wi-Fi reader'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Port'), 'abc');
    await tester.tap(find.text('Save & connect'));
    await tester.pump();
    expect(find.text('Port must be a whole number between 1 and 65535.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Port'), '');
    await tester.enterText(find.widgetWithText(TextField, 'Name (optional)'), 'Taxi dongle');
    await tester.tap(find.text('Save & connect'));
    await tester.pump();
    // The dialog closing, and the handshake.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Taxi dongle'), findsNWidgets(2), reason: 'on the status card and in the list');
    expect(find.text('Wi-Fi · 192.168.0.10:35000'), findsOneWidget);
    expect(find.text('60 km/h'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Not connected'), findsOneWidget);
    expect(elm.connected, isFalse);
  });

  testWidgets('a Bluetooth reader is found by scan, saved and connected', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final elm = FakeElm(speed: 48);
    String? connectedTo;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        obdBleScannerProvider.overrideWithValue(_FakeScanner()),
        obdTransportFactoryProvider.overrideWithValue((a) {
          connectedTo = a.deviceId;
          return elm;
        }),
      ],
      child: const MaterialApp(home: ObdReaderScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth reader'));
    await tester.pumpAndSettle();

    expect(find.text('OBDII'), findsOneWidget);
    expect(find.text('Pixel Buds'), findsNothing, reason: 'not an OBD-II reader');
    await tester.tap(find.text('Show all Bluetooth devices'));
    await tester.pumpAndSettle();
    expect(find.text('Pixel Buds'), findsOneWidget);

    await tester.tap(find.text('OBDII'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(connectedTo, 'AA:BB:CC:00:00:01');
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Bluetooth LE · AA:BB:CC:00:00:01'), findsOneWidget);
    expect(find.text('48 km/h'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('Bluetooth switched off is said plainly', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        obdBleScannerProvider.overrideWithValue(
            _FakeScanner(error: StateError('Bluetooth is off. Turn it on to use a Bluetooth reader.'))),
      ],
      child: const MaterialApp(home: ObdReaderScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth reader'));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth is off. Turn it on to use a Bluetooth reader.'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
  });
}
