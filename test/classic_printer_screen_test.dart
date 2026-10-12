import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/data/printer/classic_bluetooth.dart';
import 'package:get_ride/src/data/printer/printer_service.dart';
import 'package:get_ride/src/features/meter/printer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_classic_bluetooth.dart';

void main() {
  tearDown(() => debugPrinterPlatform = null);

  Future<void> pump(WidgetTester tester, FakeClassicBluetooth bt, {ThemeMode mode = ThemeMode.light}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          classicBluetoothProvider.overrideWithValue(bt),
          printerSettleProvider.overrideWithValue(Duration.zero),
        ],
        child: MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: mode,
          home: const PrinterScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openClassic(WidgetTester tester) async {
    await tester.tap(find.text('Add printer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth (classic / paired)'));
    await tester.pumpAndSettle();
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('a paired classic printer is picked, saved and test-printed (${mode.name})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      debugPrinterPlatform = PrinterPlatform.android;
      final bt = FakeClassicBluetooth(
        devices: [
          (address: 'AA:00:00:00:00:09', name: 'Galaxy Buds', majorClass: 0x0400),
          (address: '66:22:AA:BB:CC:01', name: 'MTP-II', majorClass: bluetoothMajorImaging),
        ],
      );
      await pump(tester, bt, mode: mode);
      await openClassic(tester);

      expect(find.text('Paired Bluetooth printers'), findsOneWidget);
      expect(find.textContaining('Pair the printer in Android Bluetooth settings first'), findsOneWidget);
      final printerY = tester.getTopLeft(find.text('MTP-II')).dy;
      expect(printerY, lessThan(tester.getTopLeft(find.text('Galaxy Buds')).dy), reason: 'printers listed first');

      await tester.tap(find.text('Open Bluetooth settings'));
      await tester.pumpAndSettle();
      expect(bt.settingsOpened, 1);

      await tester.tap(find.text('MTP-II'));
      await tester.pumpAndSettle();
      expect(find.text('Bluetooth printer (classic)'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Dash printer');
      await tester.tap(find.text('80mm'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Bluetooth (classic) · 66:22:AA:BB:CC:01 · 80mm\nReceipts print here'), findsOneWidget);

      await tester.tap(find.text('Test print'));
      await tester.pumpAndSettle();
      expect(bt.connected, ['66:22:AA:BB:CC:01']);
      expect(bt.printed, contains('80mm (48 cols)'));
      expect(bt.open, isFalse);
      expect(find.text('Test page sent to Dash printer.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a printer that is off says so', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrinterStore.listKey:
          '[{"id":"p1","name":"Dash printer","transport":"bluetooth-classic","address":"66:22:AA:BB:CC:01",'
          '"paperWidth":"58mm","createdAt":"t"}]',
    });
    debugPrinterPlatform = PrinterPlatform.android;
    await pump(tester, FakeClassicBluetooth(connectError: 'connect_failed'));
    await tester.tap(find.text('Test print'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Dash printer is off or out of range'), findsOneWidget);
  });

  testWidgets('Bluetooth off is explained in the paired list (dark)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugPrinterPlatform = PrinterPlatform.android;
    await pump(tester, FakeClassicBluetooth(listError: 'bluetooth_off'), mode: ThemeMode.dark);
    await openClassic(tester);
    expect(find.text('Bluetooth is off. Turn it on to print.'), findsOneWidget);
  });

  testWidgets('no paired devices points at Android settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugPrinterPlatform = PrinterPlatform.android;
    await pump(tester, FakeClassicBluetooth());
    await openClassic(tester);
    expect(find.textContaining('No paired devices'), findsOneWidget);
  });

  testWidgets('on an iPhone the classic option is shown disabled with the reason', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugPrinterPlatform = PrinterPlatform.ios;
    final bt = FakeClassicBluetooth();
    await pump(tester, bt);
    await tester.tap(find.text('Add printer'));
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(find.byKey(const ValueKey('add-classic-printer')));
    expect(tile.enabled, isFalse);
    expect(find.textContaining('Apple MFi certified'), findsOneWidget);
    await tester.tap(find.text('Bluetooth (classic / paired)'));
    await tester.pumpAndSettle();
    expect(find.text('Paired Bluetooth printers'), findsNothing);
  });
}
