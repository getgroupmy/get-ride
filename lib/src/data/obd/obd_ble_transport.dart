import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/obd.dart';
import '../../core/obd_ble.dart';
import '../ble.dart';
import 'obd_transport.dart';

/// An ELM327 over Bluetooth LE (Expo `BleTransport`): connects to the
/// peripheral picked from the scan, finds its serial characteristics and
/// streams the replies.
class BleObdTransport implements ObdTransport {
  BleObdTransport(this.deviceId, {this.name, this.connectTimeout = const Duration(seconds: 20)});

  final String deviceId;
  final String? name;
  final Duration connectTimeout;

  ResolvedBleProfile? _profile;
  StreamSubscription<Uint8List>? _sub;
  final _data = StreamController<String>.broadcast();

  @override
  String get kind => 'bluetooth';

  @override
  Stream<String> get data => _data.stream;

  @override
  Future<String> connect() async {
    await ensureBluetoothReady();
    try {
      await _open();
    } catch (_) {
      // A peripheral the phone has not seen since it restarted may need to
      // be found again before it can be connected to.
      await _release();
      await _findAgain();
      await _open();
    }
    return name ?? deviceId;
  }

  Future<void> _open() async {
    await UniversalBle.connect(deviceId, timeout: connectTimeout);
    final services = await UniversalBle.discoverServices(deviceId);
    final profile = resolveBleProfile([
      for (final s in services)
        (
          uuid: s.uuid,
          characteristics: [
            for (final c in s.characteristics)
              BleCharacteristicInfo(
                c.uuid,
                write: c.properties.contains(CharacteristicProperty.write),
                writeWithoutResponse: c.properties.contains(CharacteristicProperty.writeWithoutResponse),
                notify: c.properties.contains(CharacteristicProperty.notify),
                indicate: c.properties.contains(CharacteristicProperty.indicate),
              ),
          ],
        ),
    ]);
    if (profile == null) {
      throw StateError('Connected, but this device has no ELM327 serial link. Is it an OBD-II reader?');
    }
    _profile = profile;
    _sub = UniversalBle.characteristicValueStream(deviceId, profile.notify)
        .listen((bytes) => _data.add(latin1.decode(bytes)));
    profile.indicate
        ? await UniversalBle.subscribeIndications(deviceId, profile.service, profile.notify)
        : await UniversalBle.subscribeNotifications(deviceId, profile.service, profile.notify);
  }

  Future<void> _findAgain() => findBlePeripheral(deviceId,
      notFound: 'Could not find the reader. Check it is plugged in and the ignition is on.');

  @override
  Future<void> write(String command) async {
    final p = _profile;
    if (p == null) throw StateError('not connected');
    for (final packet in chunkBleWrite(ascii.encode('$command$elmCr'))) {
      await UniversalBle.write(deviceId, p.service, p.write, Uint8List.fromList(packet),
          withoutResponse: !p.writeWithResponse);
    }
  }

  Future<void> _release() async {
    // Not awaited: nothing depends on the cancel.
    unawaited(_sub?.cancel());
    _sub = null;
    _profile = null;
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
  }

  @override
  Future<void> disconnect() => _release();
}
