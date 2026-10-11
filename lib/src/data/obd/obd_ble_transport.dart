import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/obd.dart';
import '../../core/obd_ble.dart';
import '../ble.dart';
import 'obd_transport.dart';

/// How long a reader is left after its replies are subscribed to before the
/// first command: several BLE clones drop whatever arrives while they are
/// still settling the link, so the reset was never heard.
const bleSettleDelay = Duration(milliseconds: 500);

/// How long a write-without-response is waited on. iOS only reports one done
/// when its send queue had filled, so a short command's write never
/// completes on its own and held every later command behind it; the bytes
/// are already on their way once the platform has them.
const bleUnacknowledgedWriteWait = Duration(milliseconds: 800);

/// An ELM327 over Bluetooth LE (Expo `BleTransport`): connects to the
/// peripheral picked from the scan, finds its serial characteristics and
/// streams the replies. A reader that doesn't answer one way is tried the
/// next ([retune], [bleLinkCandidates]).
class BleObdTransport implements ObdTransport, ObdRetunable {
  BleObdTransport(this.deviceId, {this.name, this.connectTimeout = const Duration(seconds: 20)});

  final String deviceId;
  final String? name;
  final Duration connectTimeout;

  List<ResolvedBleProfile> _candidates = const [];
  int _index = 0;
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
    // A scan still running (the add-reader sheet's) is stopped first: the
    // plugin asks for no scan while connecting.
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    // Any link the phone still holds to the reader is dropped first, as Expo
    // does: after Bluetooth was toggled, or with another app on this phone
    // holding the reader, the platform reports "already connected" and hands
    // back a link that never delivers a reply, so every command (ATZ first)
    // times out while the reader looks connected.
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
    await UniversalBle.connect(deviceId, timeout: connectTimeout);
    final services = await UniversalBle.discoverServices(deviceId);
    _candidates = bleLinkCandidates([
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
    if (_candidates.isEmpty) {
      throw StateError('Connected, but this device has no ELM327 serial link. Is it an OBD-II reader?');
    }
    _index = 0;
    await _use(_candidates.first);
  }

  /// Listens on [profile]'s reply characteristic and lets the reader settle.
  Future<void> _use(ResolvedBleProfile profile) async {
    _profile = profile;
    await _sub?.cancel();
    _sub = UniversalBle.characteristicValueStream(deviceId, profile.notify)
        .listen((bytes) => _data.add(latin1.decode(bytes)));
    profile.indicate
        ? await UniversalBle.subscribeIndications(deviceId, profile.service, profile.notify)
        : await UniversalBle.subscribeNotifications(deviceId, profile.service, profile.notify);
    await Future<void>.delayed(bleSettleDelay);
  }

  @override
  Future<bool> retune() async {
    final current = _profile;
    if (current == null || _index + 1 >= _candidates.length) return false;
    _index++;
    final next = _candidates[_index];
    if (!sameBleUuid(next.notify, current.notify)) {
      try {
        await UniversalBle.unsubscribe(deviceId, current.service, current.notify);
      } catch (_) {}
    }
    try {
      await _use(next);
    } catch (_) {
      return retune();
    }
    return true;
  }

  Future<void> _findAgain() => findBlePeripheral(deviceId,
      notFound: 'Could not find the reader. Check it is plugged in and the ignition is on.');

  @override
  Future<void> write(String command) async {
    final p = _profile;
    if (p == null) throw StateError('not connected');
    for (final packet in chunkBleWrite(ascii.encode('$command$elmCr'))) {
      if (p.writeWithResponse) {
        await UniversalBle.write(deviceId, p.service, p.write, Uint8List.fromList(packet));
        continue;
      }
      try {
        await UniversalBle.write(deviceId, p.service, p.write, Uint8List.fromList(packet),
            withoutResponse: true, timeout: bleUnacknowledgedWriteWait);
      } on TimeoutException {
        // Sent; iOS just never said so (see bleUnacknowledgedWriteWait).
      }
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
