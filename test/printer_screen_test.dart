import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/data/ble.dart';
import 'package:get_ride/src/data/printer/printer_service.dart';
import 'package:get_ride/src/features/meter/printer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ble_scanner.dart';
import 'support/fake_printer.dart';

void main() {
  testWidgets('a Wi-Fi printer is added, selected and test-printed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final printer = FakePrinter();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        printerSinkFactoryProvider.overrideWithValue((_) => printer),
        printerSettleProvider.overrideWithValue(Duration.zero),
      ],
      child: const MaterialApp(home: PrinterScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No printer yet'), findsOneWidget);

    await tester.tap(find.text('Add printer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wi-Fi printer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text("Enter the printer's IP address."), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'IP address'), '192.168.0.50');
    await tester.enterText(find.widgetWithText(TextField, 'Name (optional)'), 'Dash printer');
    await tester.tap(find.text('80mm'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Dash printer'), findsOneWidget);
    expect(find.text('Wi-Fi · 192.168.0.50:9100 · 80mm\nReceipts print here'), findsOneWidget);

    await tester.tap(find.text('Test print'));
    await tester.pumpAndSettle();
    expect(printer.jobs.single, contains('80mm (48 cols)'));
    expect(find.text('Test page sent to Dash printer.'), findsOneWidget);

    await tester.tap(find.text('Print last receipt'));
    await tester.pumpAndSettle();
    expect(find.text('No hires on this device yet.'), findsOneWidget);
    expect(printer.jobs, hasLength(1));
  });

  testWidgets('a printer that cannot be reached says so', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrinterStore.listKey: '[{"id":"p1","name":"Dash printer","transport":"wifi","host":"10.0.0.2","port":9100,'
          '"paperWidth":"58mm","createdAt":"t"}]',
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        printerSinkFactoryProvider.overrideWithValue((_) => FakePrinter(refuse: true)),
        printerSettleProvider.overrideWithValue(Duration.zero),
      ],
      child: const MaterialApp(home: PrinterScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test print'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not print'), findsOneWidget);
  });

  testWidgets('a Bluetooth printer is found by scan, named, and test-printed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final printer = FakePrinter();
    SavedPrinter? linked;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleScannerProvider.overrideWithValue(FakeBleScanner(const [
          (deviceId: 'DC:0D:30:00:00:01', name: 'MTP-II', services: <String>[], rssi: -55),
          (deviceId: '5A:00:00:00:00:02', name: null, services: <String>[], rssi: -30),
        ])),
        printerSinkFactoryProvider.overrideWithValue((p) {
          linked = p;
          return printer;
        }),
        printerSettleProvider.overrideWithValue(Duration.zero),
      ],
      child: const MaterialApp(home: PrinterScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add printer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth printer'));
    await tester.pumpAndSettle();

    expect(find.text('MTP-II'), findsOneWidget);
    expect(find.text('Unnamed device'), findsNothing, reason: 'a nameless beacon is not a printer');
    await tester.tap(find.text('MTP-II'));
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth printer'), findsOneWidget, reason: 'the name and paper dialog');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Dash printer');
    await tester.tap(find.text('80mm'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth LE · DC:0D:30:00:00:01 · 80mm\nReceipts print here'), findsOneWidget);

    await tester.tap(find.text('Test print'));
    await tester.pumpAndSettle();
    expect(linked?.address, 'DC:0D:30:00:00:01');
    expect(printer.jobs.single, contains('80mm (48 cols)'));
    expect(find.text('Test page sent to Dash printer.'), findsOneWidget);
  });
}
