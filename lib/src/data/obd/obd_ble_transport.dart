import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/obd.dart';
import '../../core/obd_ble.dart';
import 'obd_transport.dart';

/// One reader seen by the scan.
typedef ObdBleSighting = ({String deviceId, String? name, List<String> services, int? rssi});

/// Finds Bluetooth LE readers (Expo `scanForBleAdapters`). A seam so tests
/// can play a scan back.
abstract class ObdBleScanner {
  /// Sightings as they arrive, for [duration]. Throws when Bluetooth is off
  /// or not permitted.
  Stream<ObdBleSighting> scan({Duration duration = const Duration(seconds: 12)});
}

/// Why Bluetooth cannot be used right now, in words for the driver.
String? describeBluetoothUnavailable(AvailabilityState state) => switch (state) {
      AvailabilityState.poweredOn => null,
      AvailabilityState.poweredOff => 'Bluetooth is off. Turn it on to use a Bluetooth reader.',
      AvailabilityState.unauthorized =>
        'GET.ride is not allowed to use Bluetooth. Allow it in the phone\'s settings for this app.',
      AvailabilityState.unsupported => 'This device has no Bluetooth LE.',
      _ => 'Bluetooth is not ready yet. Try again in a moment.',
    };

/// Asks for permission and waits for the adapter to be on, or throws with
/// what to tell the driver.
Future<void> _ensureBluetooth() async {
  if (kIsWeb) {
    throw UnsupportedError('A browser cannot connect to a Bluetooth OBD-II reader. Use the phone app.');
  }
  await UniversalBle.requestPermissions();
  var state = await UniversalBle.getBluetoothAvailabilityState();
  if (state == AvailabilityState.unknown || state == AvailabilityState.resetting) {
    // The adapter reports unknown for a moment after the app starts.
    state = await UniversalBle.availabilityStream
        .firstWhere((s) => s != AvailabilityState.unknown && s != AvailabilityState.resetting)
        .timeout(const Duration(seconds: 5), onTimeout: () => state);
  }
  final problem = describeBluetoothUnavailable(state);
  if (problem != null) throw StateError(problem);
}

class UniversalBleScanner implements ObdBleScanner {
  const UniversalBleScanner();

  @override
  Stream<ObdBleSighting> scan({Duration duration = const Duration(seconds: 12)}) async* {
    await _ensureBluetooth();
    final out = StreamController<ObdBleSighting>();
    final sub = UniversalBle.scanStream.listen((d) => out.add((
          deviceId: d.deviceId,
          name: d.name,
          services: d.services,
          rssi: d.rssi,
        )));
    final stop = Timer(duration, out.close);
    try {
      await UniversalBle.startScan();
      yield* out.stream;
    } finally {
      stop.cancel();
      await sub.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }
}

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
    await _ensureBluetooth();
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

  Future<void> _findAgain() async {
    await UniversalBle.startScan();
    try {
      await UniversalBle.scanStream
          .firstWhere((d) => d.deviceId.toLowerCase() == deviceId.toLowerCase())
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw StateError('Could not find the reader. Check it is plugged in and the ignition is on.');
    } finally {
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }

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
