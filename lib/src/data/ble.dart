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

/// Waits for the phone's Bluetooth *peripheral* side (advertising and serving)
/// to be ready, and says why not when it isn't.
///
/// On iPhone the peripheral manager is only created by the first call into
/// it and starts out "unknown"; anything asked of it before it powers on is
/// silently dropped by CoreBluetooth — the advert "starts" and nothing goes
/// on the air. So nothing is advertised or served before this says ready.
Future<String?> ensurePeripheralReady({
  Future<PeripheralReadinessState> Function()? state,
  Duration timeout = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final read = state ?? UniversalBlePeripheral.getAvailabilityState;
  final until = DateTime.now().add(timeout);
  while (true) {
    final s = await read();
    switch (s) {
      case PeripheralReadinessState.ready:
        return null;
      case PeripheralReadinessState.bluetoothOff:
        return 'Bluetooth is off';
      case PeripheralReadinessState.unauthorized:
        // Android asks for its advertise permission inside startAdvertising,
        // so this is the moment to try; a refusal shows up there.
        return null;
      case PeripheralReadinessState.unsupported:
        return 'This phone can\'t be found over Bluetooth';
      case PeripheralReadinessState.unknown:
        if (DateTime.now().isAfter(until)) return 'Bluetooth isn\'t ready';
        await Future<void>.delayed(step);
    }
  }
}

/// Waits for an advert just started to actually be on the air; false when
/// the phone turned it down.
Future<bool> confirmAdvertising({
  Future<PeripheralAdvertisingState> Function()? state,
  Duration timeout = const Duration(seconds: 3),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final read = state ?? UniversalBlePeripheral.getAdvertisingState;
  final until = DateTime.now().add(timeout);
  while (true) {
    final s = await read();
    if (s == PeripheralAdvertisingState.advertising) return true;
    if (s == PeripheralAdvertisingState.error || DateTime.now().isAfter(until)) return false;
    await Future<void>.delayed(step);
  }
}

/// Shares the phone's one Bluetooth scan between everything that needs it.
///
/// A phone runs one scan for the whole app, and the plugin's stopScan ends
/// it for everyone: the OBD-II reader finding itself again after a drop
/// would cut short the printer sheet's scan (or a print job finding its
/// printer), and the other way round, leaving the other side to time out
/// with "not found". So scanning is counted: the scan starts with its first
/// user and stops only when its last one is done.
class BleScanCoordinator {
  /// [_start] / [_stop] start and stop the phone's scan.
  BleScanCoordinator(this._start, this._stop);

  final Future<void> Function() _start;
  final Future<void> Function() _stop;
  int _users = 0;
  Future<void>? _starting;

  /// How many are scanning now.
  int get users => _users;

  /// Joins the scan, starting it if nobody else is scanning.
  Future<void> acquire() async {
    _users++;
    if (_users == 1) {
      final starting = _start();
      _starting = starting;
      try {
        await starting;
      } catch (_) {
        _users--;
        rethrow;
      } finally {
        if (identical(_starting, starting)) _starting = null;
      }
    } else {
      // Someone else's start may still be on its way.
      await _starting;
    }
  }

  /// Leaves the scan, stopping it once nobody is left.
  Future<void> release() async {
    if (_users == 0) return;
    _users--;
    if (_users == 0) {
      try {
        await _stop();
      } catch (_) {}
    }
  }
}

final bleScans = BleScanCoordinator(UniversalBle.startScan, UniversalBle.stopScan);

/// Scans until [deviceId] is seen: a peripheral the phone has not seen since
/// it restarted may need finding again before it can be connected to.
Future<void> findBlePeripheral(String deviceId, {required String notFound}) async {
  // Listening before the scan starts, so nothing seen at once is missed.
  final seen = UniversalBle.scanStream
      .firstWhere((d) => d.deviceId.toLowerCase() == deviceId.toLowerCase())
      .timeout(const Duration(seconds: 10));
  await bleScans.acquire();
  try {
    await seen;
  } on TimeoutException {
    throw StateError(notFound);
  } finally {
    await bleScans.release();
  }
}

class UniversalBleScanner implements BleScanner {
  const UniversalBleScanner();

  @override
  Stream<BleSighting> scan({Duration duration = const Duration(seconds: 12)}) async* {
    await ensureBluetoothReady();
    final out = StreamController<BleSighting>();
    final sub = UniversalBle.scanStream.listen(
      (d) => out.add((deviceId: d.deviceId, name: d.name, services: d.services, rssi: d.rssi)),
    );
    final stop = Timer(duration, out.close);
    var joined = false;
    try {
      await bleScans.acquire();
      joined = true;
      yield* out.stream;
    } finally {
      stop.cancel();
      await sub.cancel();
      if (joined) await bleScans.release();
    }
  }
}
