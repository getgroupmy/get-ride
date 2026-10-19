import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:get_ride/src/core/obd_adapters.dart';
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
    expect(find.text('192.168.0.10:35000'), findsOneWidget);
    expect(find.text('60 km/h'), findsOneWidget);
    expect(find.text('Odometer 128,450.6 km'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Not connected'), findsOneWidget);
    expect(elm.connected, isFalse);
  });

  testWidgets('an electric car: connected, says the car is not answering, never "reconnecting"', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final elm = FakeElm()..electric = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [obdTransportFactoryProvider.overrideWithValue((_) => elm)],
        child: const MaterialApp(home: ObdReaderScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wi-Fi reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save & connect'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byKey(const ValueKey('obd-vehicle-silent')), findsOneWidget);
    // A while later: still connected, still not "reconnecting".
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byKey(const ValueKey('obd-reconnecting')), findsNothing);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
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
    expect(find.text('AA:BB:CC:00:00:01'), findsOneWidget);
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

  const saved = SavedObdAdapter(
    id: 'a1',
    name: 'Cab dongle',
    transport: 'wifi',
    host: '192.168.0.10',
    port: 35000,
    createdAt: '2026-10-01T00:00:00Z',
  );

  Map<String, Object> savedPrefs() => {
    ObdAdapterStore.listKey: jsonEncode([saved.toJson()]),
    ObdAdapterStore.selectedKey: 'a1',
  };

  testWidgets('opening the page connects the selected reader', (tester) async {
    SharedPreferences.setMockInitialValues(savedPrefs());
    final elm = FakeElm(speed: 30);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [obdTransportFactoryProvider.overrideWithValue((_) => elm)],
        child: const MaterialApp(home: ObdReaderScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('30 km/h'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
  });

  test('a saved reader reads as its link, then its address apart', () {
    expect(describeAdapterParts(saved), (transport: 'Wi-Fi', address: '192.168.0.10:35000'));
    expect(describeAdapter(saved), 'Wi-Fi · 192.168.0.10:35000');
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('the saved reader row keeps its address whole on its own line ($scale x, ${dark ? 'dark' : 'light'})',
          (tester) async {
        tester.view.physicalSize = const Size(412, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        SharedPreferences.setMockInitialValues(savedPrefs());
        final elm = FakeElm(speed: 30);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [obdTransportFactoryProvider.overrideWithValue((_) => elm)],
            child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: const ObdReaderScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final address = tester.widget<Text>(find.byKey(const ValueKey('obd-address-a1')));
        expect(address.data, '192.168.0.10:35000');
        expect(address.maxLines, 1, reason: 'never broken inside the address');
        expect(address.softWrap, isFalse);
        expect(address.overflow, TextOverflow.ellipsis);
        expect(find.text('Wi-Fi'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Disconnect'));
        await tester.pump(const Duration(milliseconds: 10));
      });
    }
  }

  testWidgets('a car that never answers the odometer is said so, after two reads', (tester) async {
    SharedPreferences.setMockInitialValues(savedPrefs());
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          obdTransportFactoryProvider.overrideWithValue((_) => FakeElm(speed: 0)),
          readerOdometerProvider.overrideWithValue(() async {
            reads++;
            return null;
          }),
        ],
        child: const MaterialApp(home: ObdReaderScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(reads, 1);
    expect(find.byKey(const ValueKey('reader-odometer')), findsNothing, reason: 'one miss is not proof');
    await tester.pump(const Duration(seconds: 30));
    expect(reads, 2);
    expect(find.text('This vehicle does not publish its odometer (PID A6).'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
  });

  // Web round 40 (182): from 600 wide Add reader is in the app bar, not
  // over the Connected card's speed and coolant; on a phone it floats.
  for (final dark in [false, true]) {
    for (final size in const [Size(915, 412), Size(360, 640)]) {
      testWidgets('182: Add reader at ${size.width.toInt()}x${size.height.toInt()} (${dark ? 'dark' : 'light'})',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [obdTransportFactoryProvider.overrideWithValue((_) => FakeElm(speed: 60))],
            child: MaterialApp(
              theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
              home: const ObdReaderScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey('obd-add'));
        expect(add, findsOneWidget);
        final inBar = find.descendant(of: find.byType(AppBar), matching: add);
        if (size.width >= 600) {
          expect(inBar, findsOneWidget);
          expect(find.byType(FloatingActionButton), findsNothing);
        } else {
          expect(inBar, findsNothing);
          expect(find.byType(FloatingActionButton), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
