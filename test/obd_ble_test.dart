import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/core/obd_ble.dart';

BleCharacteristicInfo _c(String uuid, {bool w = false, bool wnr = false, bool n = false, bool i = false}) =>
    BleCharacteristicInfo(uuid, write: w, writeWithoutResponse: wnr, notify: n, indicate: i);

void main() {
  group('UUIDs', () {
    test('short and long spellings of the same UUID are equal', () {
      expect(normalizeBleUuid('FFF0'), '0000fff0-0000-1000-8000-00805f9b34fb');
      expect(normalizeBleUuid('0000FFF0'), '0000fff0-0000-1000-8000-00805f9b34fb');
      expect(sameBleUuid('fff1', '0000FFF1-0000-1000-8000-00805F9B34FB'), isTrue);
      expect(sameBleUuid('fff1', 'fff2'), isFalse);
      expect(sameBleUuid('', ''), isFalse);
    });
  });

  group('the scan filter', () {
    test('known dongle names are offered, whatever the case', () {
      expect(matchesElmAdvertisement(name: 'OBDII'), isTrue);
      expect(matchesElmAdvertisement(name: 'vLinker MC+'), isTrue);
      expect(matchesElmAdvertisement(name: 'IOS-Vlink'), isTrue);
      expect(matchesElmAdvertisement(name: 'Pixel Buds'), isFalse);
      expect(matchesElmAdvertisement(), isFalse);
    });

    test('a nameless dongle is offered when it advertises a serial service', () {
      expect(matchesElmAdvertisement(services: ['FFF0']), isTrue);
      expect(matchesElmAdvertisement(services: ['6E400001-B5A3-F393-E0A9-E50E24DCCA9E']), isTrue);
      expect(matchesElmAdvertisement(services: ['180D']), isFalse, reason: 'a heart-rate strap');
    });
  });

  group('the serial link', () {
    test('the common FFF0 profile: write FFF2, replies on FFF1', () {
      final p = resolveBleProfile([
        (uuid: '1800', characteristics: [_c('2a00', w: true, n: true)]),
        (uuid: '0000fff0-0000-1000-8000-00805f9b34fb', characteristics: [_c('fff1', n: true), _c('fff2', wnr: true)]),
      ])!;
      expect(p.label, 'ELM327 (FFF0)');
      expect(p.write, 'fff2');
      expect(p.notify, 'fff1');
      expect(p.writeWithResponse, isFalse);
      expect(p.indicate, isFalse);
    });

    test('an HM-10 module writes and notifies on one characteristic', () {
      final p = resolveBleProfile([
        (uuid: 'ffe0', characteristics: [_c('ffe1', w: true, wnr: true, n: true)]),
      ])!;
      expect(p.label, 'HM-10 serial (FFE0)');
      expect(p.write, p.notify);
      expect(p.writeWithResponse, isTrue);
    });

    test('a clone with uncatalogued UUIDs connects through the fallback, skipping the standard services', () {
      final p = resolveBleProfile([
        (uuid: '180a', characteristics: [_c('2a29', w: true, n: true)]),
        (uuid: 'e7810a71-73ae-499d-8c15-faa9aef0c3f2', characteristics: [_c('bef8d6c9-9c21-4c9e-b632-bd58c1009f9f', w: true, i: true)]),
      ])!;
      expect(p.label, 'Generic serial');
      expect(p.service, 'e7810a71-73ae-499d-8c15-faa9aef0c3f2');
      expect(p.indicate, isTrue, reason: 'replies arrive as indications');
    });

    test('a known profile missing a direction is not used', () {
      expect(resolveBleProfile([(uuid: 'fff0', characteristics: [_c('fff2', w: true)])]), isNull);
      expect(resolveBleProfile(const []), isNull);
    });

    test('long writes are split into 20-byte packets', () {
      final packets = chunkBleWrite(List.generate(45, (i) => i));
      expect(packets.map((p) => p.length), [20, 20, 5]);
      expect(packets.expand((p) => p), List.generate(45, (i) => i));
      expect(chunkBleWrite('ATZ\r'.codeUnits), hasLength(1));
    });
  });

  group('saved Bluetooth readers', () {
    test('take the advertised name, and are told apart by peripheral', () {
      final a = normalizeBleAdapter(id: 'a', createdAt: 't', deviceId: 'AA:BB', advertisedName: 'OBDII').value!;
      expect(a.name, 'OBDII');
      expect(a.transport, 'bluetooth');
      expect(describeAdapter(a), 'Bluetooth LE · AA:BB');
      expect(normalizeBleAdapter(id: 'a', createdAt: 't', deviceId: 'CC').value!.name, 'Bluetooth OBD-II reader');
      expect(normalizeBleAdapter(id: 'a', createdAt: 't', deviceId: ' ').error, isNotNull);

      final again = normalizeBleAdapter(id: 'b', createdAt: 't', deviceId: 'AA:BB', name: 'Taxi').value!;
      expect(upsertAdapter([a], again).single.id, 'a');
      final other = normalizeBleAdapter(id: 'c', createdAt: 't', deviceId: 'CC:DD').value!;
      expect(upsertAdapter([a], other), hasLength(2));
      final wifi = normalizeWifiAdapter(id: 'w', createdAt: 't').value!;
      expect(upsertAdapter([a], wifi), hasLength(2));
    });

    test('survive storage', () {
      final a = normalizeBleAdapter(id: 'a', createdAt: 't', deviceId: 'AA:BB').value!;
      expect(SavedObdAdapter.fromJson(a.toJson())!.deviceId, 'AA:BB');
    });
  });
}
