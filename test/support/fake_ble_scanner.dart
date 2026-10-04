import 'package:get_ride/src/data/ble.dart';

/// Plays a scan back: what a phone in a car park would see.
class FakeBleScanner implements BleScanner {
  FakeBleScanner(this.sightings, {this.error});
  final List<BleSighting> sightings;
  final Object? error;

  @override
  Stream<BleSighting> scan({Duration duration = const Duration(seconds: 12)}) async* {
    if (error != null) throw error!;
    yield* Stream.fromIterable(sightings);
  }
}

/// An OBD-II dongle whose name arrives in a later advertisement, and a pair
/// of earbuds.
const readerSightings = <BleSighting>[
  (deviceId: 'AA:BB:CC:00:00:01', name: null, services: <String>[], rssi: -60),
  (deviceId: 'AA:BB:CC:00:00:01', name: 'OBDII', services: <String>[], rssi: -58),
  (deviceId: '11:22:33:44:55:66', name: 'Pixel Buds', services: <String>[], rssi: -40),
];
