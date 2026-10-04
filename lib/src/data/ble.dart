import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_ble/universal_ble.dart';

/// The Bluetooth LE plumbing the OBD-II reader and the receipt printer share
/// (Expo `getSharedBleManager` and friends).

/// One device seen by a scan.
typedef BleSighting = ({String deviceId, String? name, List<String> services, int? rssi});

/// Finds Bluetooth LE devices for the add-reader and add-printer sheets. A
/// seam so tests can play a scan back.
abstract class BleScanner {
  /// Sightings as they arrive, for [duration]. Throws when Bluetooth is off
  /// or not permitted.
  Stream<BleSighting> scan({Duration duration = const Duration(seconds: 12)});
}

final bleScannerProvider = Provider<BleScanner>((_) => const UniversalBleScanner());

/// Why Bluetooth cannot be used right now, in words for the driver.
String? describeBluetoothUnavailable(AvailabilityState state) => switch (state) {
      AvailabilityState.poweredOn => null,
      AvailabilityState.poweredOff => 'Bluetooth is off. Turn it on to use a Bluetooth device.',
      AvailabilityState.unauthorized =>
        'GET.ride is not allowed to use Bluetooth. Allow it in the phone\'s settings for this app.',
      AvailabilityState.unsupported => 'This device has no Bluetooth LE.',
      _ => 'Bluetooth is not ready yet. Try again in a moment.',
    };

/// Asks for permission and waits for the adapter to be on, or throws with
/// what to tell the driver.
///
/// Also gives every device its own command queue. By default the plugin runs
/// the commands of every device through one queue, so a receipt streaming to
/// the printer would hold up the reader's commands; three of those timing out
/// reads as a lost link mid-hire (the failure Expo hit with a shared manager).
Future<void> ensureBluetoothReady() async {
  if (kIsWeb) {
    throw UnsupportedError('A browser cannot connect to Bluetooth devices. Use the phone app.');
  }
  UniversalBle.queueType = QueueType.perDevice;
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

/// Scans until [deviceId] is seen: a peripheral the phone has not seen since
/// it restarted may need finding again before it can be connected to.
Future<void> findBlePeripheral(String deviceId, {required String notFound}) async {
  await UniversalBle.startScan();
  try {
    await UniversalBle.scanStream
        .firstWhere((d) => d.deviceId.toLowerCase() == deviceId.toLowerCase())
        .timeout(const Duration(seconds: 10));
  } on TimeoutException {
    throw StateError(notFound);
  } finally {
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }
}

class UniversalBleScanner implements BleScanner {
  const UniversalBleScanner();

  @override
  Stream<BleSighting> scan({Duration duration = const Duration(seconds: 12)}) async* {
    await ensureBluetoothReady();
    final out = StreamController<BleSighting>();
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
