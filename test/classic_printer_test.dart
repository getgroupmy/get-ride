import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/escpos.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/data/printer/classic_bluetooth.dart';
import 'package:get_ride/src/data/printer/printer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_classic_bluetooth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugPrinterPlatform = null);

  group('availability', () {
    test('classic Bluetooth is Android only, and says why elsewhere', () {
      expect(printerTransportAvailability(classicPrinterTransport, PrinterPlatform.android).available, isTrue);
      final ios = printerTransportAvailability(classicPrinterTransport, PrinterPlatform.ios);
      expect(ios.available, isFalse);
      expect(ios.reason, contains('MFi'));
      final desktop = printerTransportAvailability(classicPrinterTransport, PrinterPlatform.desktop);
      expect(desktop.available, isFalse);
      expect(desktop.reason, contains('Android'));
      final web = printerTransportAvailability(classicPrinterTransport, PrinterPlatform.web);
      expect(web.available, isFalse);
      expect(web.reason, contains('browser'));
    });

    test('Wi-Fi and Bluetooth LE work on every native platform, nothing in a browser', () {
      for (final t in ['wifi', 'bluetooth']) {
        for (final p in [PrinterPlatform.android, PrinterPlatform.ios, PrinterPlatform.desktop]) {
          expect(printerTransportAvailability(t, p).available, isTrue, reason: '$t on $p');
        }
        expect(printerTransportAvailability(t, PrinterPlatform.web).available, isFalse);
      }
      expect(printerTransportAvailability('usb', PrinterPlatform.android).available, isFalse);
    });
  });

  SavedObdAdapter reader() => SavedObdAdapter.fromJson({
    'id': 'r',
    'name': 'OBDII',
    'transport': 'bluetooth',
    'deviceId': '00:1D:A5:00:00:01',
    'createdAt': 't',
  })!;

  group('saved classic printers', () {
    test('a paired printer keeps its address, its paired name and paper', () {
      final p = normalizeClassicPrinter(
        id: 'c',
        createdAt: 't',
        address: '66:22:aa:bb:cc:01',
        pairedName: 'BlueTooth Printer',
        paper: PaperWidth.mm80,
      ).value!;
      expect(p.transport, classicPrinterTransport);
      expect(p.address, '66:22:AA:BB:CC:01');
      expect(p.name, 'BlueTooth Printer');
      expect(describePrinter(p), 'Bluetooth (classic) · 66:22:AA:BB:CC:01 · 80mm');
      final back = SavedPrinter.fromJson(p.toJson())!;
      expect(back.transport, classicPrinterTransport);
      expect(back.address, p.address);
    });

    test('only a Bluetooth address is accepted', () {
      expect(normalizeClassicPrinter(id: 'c', createdAt: 't', address: '').error, isNotNull);
      expect(normalizeClassicPrinter(id: 'c', createdAt: 't', address: 'printer').error, isNotNull);
      expect(normalizeClassicPrinter(id: 'c', createdAt: 't', address: '66:22:AA:BB:CC').error, isNotNull);
      expect(
        normalizeClassicPrinter(id: 'c', createdAt: 't', address: '66:22:AA:BB:CC:01', name: 'x' * 61).error,
        isNotNull,
      );
      expect(
        normalizeClassicPrinter(id: 'c', createdAt: 't', address: '66:22:AA:BB:CC:01').value!.name,
        'Bluetooth printer',
      );
    });

    test('re-adding the same paired printer keeps its entry; LE and classic stay apart', () {
      final p = normalizeClassicPrinter(id: 'c', createdAt: 't', address: '66:22:AA:BB:CC:01').value!;
      final again = normalizeClassicPrinter(
        id: 'd',
        createdAt: 't2',
        address: '66:22:aa:bb:cc:01',
        name: 'Dash',
      ).value!;
      final list = upsertPrinter([p], again);
      expect(list.single.id, 'c');
      expect(list.single.name, 'Dash');
      final le = normalizeBlePrinter(id: 'e', createdAt: 't', deviceId: '66:22:AA:BB:CC:01').value!;
      expect(upsertPrinter(list, le), hasLength(2));
    });

    test('a paired OBD-II reader is never a printer', () {
      final p = normalizeClassicPrinter(id: 'c', createdAt: 't', address: '00:1d:a5:00:00:01').value!;
      expect(printerIsObdReader(p, [reader()]), isTrue);
    });
  });

  test('paired devices are ranked printers first, headsets last, readers and duplicates dropped', () {
    final ranked = rankBondedPrinters(
      [
        (address: 'AA:00:00:00:00:01', name: 'Car kit', majorClass: 0x0400),
        (address: 'AA:00:00:00:00:02', name: 'Zebra', majorClass: null),
        (address: 'AA:00:00:00:00:03', name: 'MTP-II', majorClass: bluetoothMajorImaging),
        (address: '00:1D:A5:00:00:01', name: 'OBDII', majorClass: 0x1F00),
        (address: 'AA:00:00:00:00:04', name: 'Another', majorClass: 0x1F00),
        (address: 'aa:00:00:00:00:04', name: 'Another', majorClass: 0x1F00),
        (address: '', name: 'Ghost', majorClass: null),
      ],
      readers: [reader()],
    );
    expect([for (final d in ranked) d.name], ['MTP-II', 'Another', 'Zebra', 'Car kit']);
  });

  test('classic failures name what to do', () {
    expect(describeClassicPrinterError('not_bonded', 'P'), contains('Pair the printer in Android Bluetooth settings'));
    expect(describeClassicPrinterError('connect_failed', 'P'), contains('P is off or out of range'));
    expect(describeClassicPrinterError('timeout', 'P'), contains('off or out of range'));
    expect(describeClassicPrinterError('bluetooth_off', 'P'), contains('Bluetooth is off'));
    expect(describeClassicPrinterError('permission', 'P'), contains('Nearby devices'));
    expect(describeClassicPrinterError('write_failed', 'P'), contains('dropped'));
    expect(describeClassicPrinterError('weird', 'P', message: 'boom'), 'Could not print to P: boom.');
    final p = normalizeClassicPrinter(id: 'c', createdAt: 't', address: '66:22:AA:BB:CC:01', name: 'Dash').value!;
    expect(describePrintError(const ClassicBluetoothException('not_bonded'), p), contains('Pair the printer'));
    expect(describePrintError(Exception('?'), p), contains('Could not print to Dash'));
  });

  group('printing over classic Bluetooth', () {
    late FakeClassicBluetooth bt;
    late ProviderContainer container;
    final saved = normalizeClassicPrinter(id: 'c', createdAt: 't', address: '66:22:AA:BB:CC:01', name: 'Dash').value!;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      bt = FakeClassicBluetooth();
      container = ProviderContainer(
        overrides: [
          classicBluetoothProvider.overrideWithValue(bt),
          printerSettleProvider.overrideWithValue(Duration.zero),
        ],
      );
      addTearDown(container.dispose);
      await container.read(printerStoreProvider).save([saved]);
    });

    test('a job connects, writes the whole document in chunks and closes', () async {
      debugPrinterPlatform = PrinterPlatform.android;
      final doc = buildTestPrintEscpos(paper: PaperWidth.mm58) * 4;
      expect(doc.length, greaterThan(classicPrinterChunkSize), reason: 'long enough to need chunks');
      expect(await container.read(printerServiceProvider).send(saved, doc), isNull);
      expect(bt.connected, ['66:22:AA:BB:CC:01']);
      expect(bt.writes.length, greaterThan(1));
      expect(bt.writes.every((w) => w.length <= classicPrinterChunkSize), isTrue);
      expect(bt.printed, doc);
      expect(bt.open, isFalse);
      expect(bt.closes, 1);
    });

    test('an unpaired or switched-off printer says what to do, and the link is closed', () async {
      debugPrinterPlatform = PrinterPlatform.android;
      bt.connectError = 'not_bonded';
      expect(await container.read(printerServiceProvider).send(saved, 'X'), contains('Pair the printer'));
      bt.connectError = 'connect_failed';
      expect(await container.read(printerServiceProvider).send(saved, 'X'), contains('Dash is off or out of range'));
      expect(bt.writes, isEmpty);
      expect(bt.closes, 2);
    });

    test('off Android the saved classic printer is reported unavailable, with nothing sent', () async {
      debugPrinterPlatform = PrinterPlatform.ios;
      expect(await container.read(printerServiceProvider).send(saved, 'X'), contains('MFi'));
      expect(bt.connected, isEmpty);
    });
  });

  group('platform channel', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        classicBluetoothMethods,
        (call) async {
          calls.add(call);
          return switch (call.method) {
            'bonded' => [
              {'address': '66:22:AA:BB:CC:01', 'name': 'MTP-II', 'majorClass': 0x0600},
              {'address': 'AA:00:00:00:00:02', 'name': null, 'majorClass': null},
              {'name': 'no address'},
            ],
            'connect' => throw PlatformException(code: 'not_bonded', message: 'not paired'),
            _ => null,
          };
        },
      );
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        classicBluetoothMethods,
        null,
      ),
    );

    test('the bonded list is read off the channel on Android', () async {
      debugPrinterPlatform = PrinterPlatform.android;
      const bt = MethodChannelClassicBluetooth();
      final list = await bt.bondedDevices();
      expect(list, hasLength(2));
      expect(list.first.name, 'MTP-II');
      expect(list.first.majorClass, bluetoothMajorImaging);
      expect(list.last.name, isNull);
    });

    test('connect sends the SPP UUID and a timeout, and maps platform errors', () async {
      debugPrinterPlatform = PrinterPlatform.android;
      const bt = MethodChannelClassicBluetooth();
      await expectLater(
        bt.connect('66:22:AA:BB:CC:01', timeout: const Duration(seconds: 5)),
        throwsA(isA<ClassicBluetoothException>().having((e) => e.code, 'code', 'not_bonded')),
      );
      final connect = calls.singleWhere((c) => c.method == 'connect');
      expect(connect.arguments, {'address': '66:22:AA:BB:CC:01', 'uuid': classicSppUuid, 'timeoutMs': 5000});
    });

    test('off Android nothing reaches the channel', () async {
      debugPrinterPlatform = PrinterPlatform.ios;
      const bt = MethodChannelClassicBluetooth();
      expect(bt.bondedDevices, throwsUnsupportedError);
      expect(await bt.openSettings(), isFalse);
      await bt.close();
      expect(calls, isEmpty);
    });
  });
}
