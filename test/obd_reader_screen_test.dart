import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/ble.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/features/meter/obd_reader_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ble_scanner.dart';
import 'support/fake_elm.dart';

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
        bleScannerProvider.overrideWithValue(FakeBleScanner(readerSightings)),
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
        bleScannerProvider.overrideWithValue(
            FakeBleScanner(const [], error: StateError('Bluetooth is off. Turn it on to use a Bluetooth device.'))),
      ],
      child: const MaterialApp(home: ObdReaderScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth reader'));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth is off. Turn it on to use a Bluetooth device.'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
  });
}
