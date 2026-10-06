import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/core/obd_mfi.dart';
import 'package:get_ride/src/data/obd/obd_mfi_transport.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/features/meter/obd_reader_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_elm.dart';

MfiAccessory acc(String id, String name, {String serial = '', String protocol = 'com.obdlink'}) =>
    (connectionId: id, name: name, serial: serial, protocol: protocol);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rules', () {
    test('a saved reader links only to its own accessory', () {
      final list = [acc('1', 'AirPods'), acc('2', 'OBDLink MX+', serial: 'SN-123'), acc('3', 'OBDLink LX')];
      expect(pickMfiAccessory(list)?.connectionId, '2', reason: 'first that looks like a reader');
      expect(pickMfiAccessory(list, preferred: 'sn123')?.connectionId, '2', reason: 'serial, punctuation-blind');
      expect(pickMfiAccessory(list, preferred: 'obdlink lx')?.connectionId, '3', reason: 'by name');
      expect(pickMfiAccessory(list, preferred: 'OTHER-9'), isNull, reason: "never another car's dongle");
      expect(pickMfiAccessory([acc('1', 'AirPods')]), isNull);
    });

    test('accessories are remembered by serial, else name', () {
      expect(mfiAccessoryKey(acc('1', 'OBDLink MX+', serial: 'SN-1')), 'SN-1');
      expect(mfiAccessoryKey(acc('1', 'OBDLink MX+')), 'OBDLink MX+');
      expect(isLikelyMfiReader(acc('1', 'STN2120 adapter')), isTrue);
      expect(
        mfiAccessoryFromMap({'id': '7', 'name': 'OBDLink', 'serial': 'S', 'protocol': 'com.obdlink'}),
        acc('7', 'OBDLink', serial: 'S'),
      );
      expect(mfiAccessoryFromMap({'name': 'no id'}), isNull);
    });

    test('a picked accessory becomes a saved MFi reader', () {
      final a = normalizeMfiAdapter(id: 'x', createdAt: 't', key: 'SN-1', accessoryName: 'OBDLink MX+').value!;
      expect(a.transport, 'mfi');
      expect(a.deviceId, 'SN-1');
      expect(describeAdapter(a), 'Bluetooth MFi · SN-1');
      expect(normalizeMfiAdapter(id: 'x', createdAt: 't', key: ' ').error, isNotNull);
    });
  });

  group('transport', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late List<MfiAccessory> paired;
    MockStreamHandlerEventSink? sink;

    setUp(() {
      debugMfiSupported = true;
      calls = [];
      paired = [acc('42', 'OBDLink MX+', serial: 'SN-1')];
      messenger.setMockMethodCallHandler(mfiMethods, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'list':
            return [
              for (final a in paired)
                {'id': a.connectionId, 'name': a.name, 'serial': a.serial, 'protocol': a.protocol},
            ];
          case 'connect':
            return 'OBDLink MX+';
          case 'write':
            sink?.success('OK\r\r>');
            return null;
        }
        return null;
      });
      messenger.setMockStreamHandler(
        mfiEvents,
        MockStreamHandler.inline(onListen: (_, s) => sink = s, onCancel: (_) => sink = null),
      );
    });

    tearDown(() {
      debugMfiSupported = null;
      messenger.setMockMethodCallHandler(mfiMethods, null);
      messenger.setMockStreamHandler(mfiEvents, null);
    });

    test('opens the saved accessory by its current connection id and streams replies', () async {
      final t = MfiObdTransport('SN-1');
      expect(await t.connect(), 'OBDLink MX+');
      expect(calls.map((c) => c.method), ['disconnect', 'list', 'connect']);
      expect(calls.last.arguments, {'id': '42'});
      final reply = t.data.first;
      await t.write('ATZ');
      expect(calls.last.arguments, {'text': 'ATZ\r'});
      expect(await reply, 'OK\r\r>');
      await t.disconnect();
    });

    test('a reader that is not paired says how to pair it', () async {
      paired = [];
      await expectLater(
        MfiObdTransport('SN-1', name: 'Cab dongle').connect(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Pair it in Settings'))),
      );
    });
  });

  testWidgets('an MFi reader is picked from the paired accessories, saved and connected', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugMfiSupported = true;
    addTearDown(() => debugMfiSupported = null);
    final elm = FakeElm(speed: 42);
    SavedObdAdapter? connected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mfiAccessoriesProvider.overrideWithValue(
            () async => [acc('1', 'AirPods'), acc('2', 'OBDLink MX+', serial: 'SN-1')],
          ),
          obdTransportFactoryProvider.overrideWithValue((a) {
            connected = a;
            return elm;
          }),
        ],
        child: const MaterialApp(home: ObdReaderScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-mfi-reader')));
    await tester.pumpAndSettle();
    final names = tester
        .widgetList<Text>(find.descendant(of: find.byKey(const ValueKey('mfi-sheet')), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    expect(names.indexOf('OBDLink MX+'), lessThan(names.indexOf('AirPods')), reason: 'readers first');
    await tester.tap(find.text('OBDLink MX+'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(connected?.transport, 'mfi');
    expect(connected?.deviceId, 'SN-1');
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Bluetooth MFi · SN-1'), findsOneWidget);
    expect(find.text('42 km/h'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('outside iOS there is no MFi option', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ObdReaderScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-mfi-reader')), findsNothing);
  });
}
